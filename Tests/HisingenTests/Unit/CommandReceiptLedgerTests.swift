import Foundation
import Testing
@testable import Hisingen

/// A receipt's whole life, asserted through one interface and one fake clock: filed against the
/// right vehicle, accepted, superseded, confirmed by telemetry, suspended across a sleep, timed
/// out, and asked which transport could prove it.
///
/// Before this module existed the only route to any of these transitions was to build a
/// coordinator, a state store, a preferences store, an image cache, a session manager and a
/// streaming provider, then poll a diagnostics snapshot while real timers ran. The Remote Command
/// target comparison was shell code no test could reach.
@MainActor
struct CommandReceiptLedgerTests {

    private let vin = "CONFIRMATION-LEDGER-VIN"
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func anAwaitingReceiptIsVisibleAndNamesItsTransport() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        let receipt = lockReceipt()

        #expect(ledger.begin(receipt, selectedVIN: vin).awaitsTelemetry)
        #expect(ledger.visibleReceipts == [receipt])
        #expect(ledger.isConfirmationPending)

        // A stream can prove a lock when the user has live updates on...
        #expect(ledger.transport(for: lockedState(), realTimeEnabled: true)
            == .stream(.exteriorConfirmation))
        // ...and without them the same receipt asks for a targeted poll instead of going idle.
        guard case .poll(let features, let after) = ledger.transport(
            for: lockedState(), realTimeEnabled: false
        ) else {
            Issue.record("expected a targeted poll when live updates are off")
            return
        }
        #expect(features == [RemoteCommand.lock.feature])
        #expect(after == ledger.pollInterval)
    }

    @Test
    func anAcknowledgedReceiptSettlesWithoutTelemetry() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.honkHorn.identifier,
            issuedAt: startedAt, command: .honkHorn, status: .acknowledged(at: startedAt))

        // Nothing can prove a horn, so the provider's acknowledgement is already terminal.
        let filing = ledger.begin(receipt, selectedVIN: vin)
        #expect(filing.isForSelectedVehicle)
        #expect(filing.awaitsTelemetry == false)
        #expect(ledger.visibleReceipts.isEmpty)
        #expect(ledger.transport(for: lockedState(), realTimeEnabled: true) == .idle)
    }

    @Test
    func matchingTelemetryConfirmsTheReceipt() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(), selectedVIN: vin).awaitsTelemetry)

        #expect(ledger.observe(lockedState(), vin: vin))
        #expect(ledger.isConfirmationPending == false)
        #expect(ledger.awaitingCount == 0)
        // A confirmed lock stays on screen: the chip is the durable confirmation.
        #expect(ledger.visibleReceipts.count == 1)
    }

    @Test
    func aStateThatDoesNotProveTheCommandConfirmsNothing() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(), selectedVIN: vin).awaitsTelemetry)

        // Right reading, stale timestamp: a cached frame must not confirm.
        var stale = lockedState()
        stale.freshness.isCached = true
        #expect(ledger.observe(stale, vin: vin) == false)
        #expect(ledger.isConfirmationPending)
    }

    @Test
    func aNewerCommandSupersedesThePendingOneInItsConflictGroup() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(), selectedVIN: vin).awaitsTelemetry)
        let unlock = CommandReceipt(
            commandIdentifier: RemoteCommand.unlock.identifier,
            issuedAt: startedAt.addingTimeInterval(5), command: .unlock, targetVIN: vin)

        #expect(ledger.begin(unlock, selectedVIN: vin).awaitsTelemetry)

        #expect(ledger.awaitingCount == 1)
        #expect(ledger.visibleReceipts.map(\.commandIdentifier) == [RemoteCommand.unlock.identifier])
    }

    @Test
    func theClockDecidesWhenAWindowLapses() {
        var currentTime = startedAt
        let (ledger, _, cleanup) = makeLedger(window: 60, now: { currentTime })
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(issuedAt: startedAt), selectedVIN: vin).awaitsTelemetry)

        currentTime = startedAt.addingTimeInterval(30)
        #expect(ledger.expireLapsedWindows(vin: vin) == false)

        currentTime = startedAt.addingTimeInterval(61)
        #expect(ledger.expireLapsedWindows(vin: vin))
        // A lapsed window times out exactly once.
        #expect(ledger.expireLapsedWindows(vin: vin) == false)
        #expect(ledger.diagnosticRecord?.receipt.status
            == .timedOut(at: startedAt.addingTimeInterval(60)))
    }

    @Test
    func suspendingShiftsTheDeadlineByTheTimeSpentSuspended() {
        var currentTime = startedAt
        let (ledger, _, cleanup) = makeLedger(window: 100, now: { currentTime })
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(issuedAt: startedAt), selectedVIN: vin).awaitsTelemetry)

        currentTime = startedAt.addingTimeInterval(10)
        ledger.suspend()
        #expect(ledger.isSuspended)

        // Asleep for 30 s: that time must not be charged against the confirmation window.
        currentTime = startedAt.addingTimeInterval(40)
        #expect(ledger.resume())
        #expect(ledger.isSuspended == false)

        currentTime = startedAt.addingTimeInterval(100)
        #expect(ledger.expireLapsedWindows(vin: vin) == false)
        currentTime = startedAt.addingTimeInterval(131)
        #expect(ledger.expireLapsedWindows(vin: vin))
    }

    // MARK: - Filing against the selected vehicle

    @Test
    func aReceiptForTheSelectedVehicleJoinsTheLiveCollection() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }

        // The target comparison is case-insensitive, like every other VIN comparison.
        let filing = ledger.begin(lockReceipt(targetVIN: vin.lowercased()), selectedVIN: vin)

        #expect(filing.isForSelectedVehicle)
        #expect(filing.awaitsTelemetry)
        #expect(ledger.visibleReceipts.count == 1)
    }

    @Test
    func aReceiptWithNoRecordedTargetBelongsToTheSelectedVehicle() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }

        let filing = ledger.begin(lockReceipt(targetVIN: nil), selectedVIN: vin)

        #expect(filing.isForSelectedVehicle)
        #expect(ledger.visibleReceipts.count == 1)
    }

    @Test
    func anOffTargetReceiptWaitsUnderItsOwnVINAndStaysOutOfTheVisibleSet() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        let otherVIN = "CONFIRMATION-LEDGER-OTHER"

        let filing = ledger.begin(lockReceipt(targetVIN: otherVIN), selectedVIN: vin)

        // There is no live loop for a vehicle that is not selected, so it must not appear.
        #expect(filing.isForSelectedVehicle == false)
        #expect(filing.awaitsTelemetry == false)
        #expect(ledger.isEmpty)
        #expect(ledger.visibleReceipts.isEmpty)
        // It is restored, not lost, when that vehicle is selected.
        #expect(ledger.restore(forVIN: otherVIN))
        #expect(ledger.visibleReceipts.count == 1)
        #expect(ledger.isConfirmationPending)
    }

    @Test
    func withNoSelectedVehicleATargetedReceiptIsFiledOffTarget() {
        // Preserved from the shell branch this rule came from: with nothing selected, a receipt
        // that names a target cannot belong to the live collection.
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }

        let filing = ledger.begin(lockReceipt(targetVIN: vin), selectedVIN: nil)

        #expect(filing.isForSelectedVehicle == false)
        #expect(ledger.isEmpty)
        #expect(ledger.restore(forVIN: vin))
    }

    @Test
    func optimisticFieldsNameExactlyWhatAnAwaitingCommandOwns() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        #expect(ledger.begin(lockReceipt(), selectedVIN: vin).awaitsTelemetry)
        #expect(ledger.optimisticFields == [.exterior])

        #expect(ledger.begin(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(90).identifier,
            issuedAt: startedAt.addingTimeInterval(1), command: .setChargeTarget(90),
            targetVIN: vin), selectedVIN: vin).awaitsTelemetry)
        // Different conflict groups, so both stay awaiting and both keep their field.
        #expect(ledger.optimisticFields == [.exterior, .chargeTarget])
    }

    @Test
    func aScheduledTickNarrowsTheFetchToWhatTheReceiptsNeedAndAManualOneDoesNot() {
        let (ledger, _, cleanup) = makeLedger()
        defer { cleanup() }
        #expect(ledger.targetedFeatures(isScheduledTick: true) == nil)
        #expect(ledger.begin(lockReceipt(), selectedVIN: vin).awaitsTelemetry)

        #expect(ledger.targetedFeatures(isScheduledTick: true)?.enabled == [RemoteCommand.lock.feature])
        #expect(ledger.targetedFeatures(isScheduledTick: false) == nil)
    }

    // MARK: - Harness

    private func lockReceipt(issuedAt: Date = Date()) -> CommandReceipt {
        lockReceipt(issuedAt: issuedAt, targetVIN: vin)
    }

    private func lockReceipt(issuedAt: Date = Date(), targetVIN: String?) -> CommandReceipt {
        CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: issuedAt, command: .lock, targetVIN: targetVIN)
    }

    /// The exterior reading that proves a lock, reported at the moment the command was issued.
    private func lockedState(reportedAt: Date = Date()) -> VehicleState {
        vehicle(
            vin: vin,
            exteriorStatus: ExteriorSnapshot(
                openings: [], isLocked: true, alarmTriggered: false, reportedAt: reportedAt)
        )
    }

    private func makeLedger(
        window: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) -> (CommandReceiptLedger, VehicleStateStore, () -> Void) {
        let suite = "CommandReceiptLedgerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        let ledger = CommandReceiptLedger(store: store, now: now, confirmationWindow: window)
        return (ledger, store, { defaults.removePersistentDomain(forName: suite) })
    }
}
