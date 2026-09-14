import Foundation
import Testing
@testable import Hisingen

/// A receipt's whole life, asserted through one interface and one fake clock: accepted,
/// superseded, confirmed by telemetry, suspended across a sleep, timed out, and asked which
/// transport could prove it.
///
/// Before this module existed the only route to any of these transitions was to build a
/// coordinator, a state store, a preferences store, an image cache, a session manager and a
/// streaming provider, then poll a diagnostics snapshot while real timers ran.
@MainActor
struct CommandConfirmationLoopTests {

    private let vin = "CONFIRMATION-LOOP-VIN"
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func anAwaitingReceiptIsVisibleAndNamesItsTransport() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        let receipt = lockReceipt()

        #expect(loop.begin(receipt, vin: vin))
        #expect(loop.visibleReceipts == [receipt])
        #expect(loop.isConfirmationPending)

        // A stream can prove a lock when the user has live updates on...
        #expect(loop.transport(for: lockedState(), realTimeEnabled: true)
            == .stream(.exteriorConfirmation))
        // ...and without them the same receipt asks for a targeted poll instead of going idle.
        guard case .poll(let features, let after) = loop.transport(
            for: lockedState(), realTimeEnabled: false
        ) else {
            Issue.record("expected a targeted poll when live updates are off")
            return
        }
        #expect(features == [RemoteCommand.lock.feature])
        #expect(after == loop.pollInterval)
    }

    @Test
    func anAcknowledgedReceiptSettlesWithoutTelemetry() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.honkHorn.identifier,
            issuedAt: startedAt, command: .honkHorn, status: .acknowledged(at: startedAt))

        // Nothing can prove a horn, so the provider's acknowledgement is already terminal.
        #expect(loop.begin(receipt, vin: vin) == false)
        #expect(loop.visibleReceipts.isEmpty)
        #expect(loop.transport(for: lockedState(), realTimeEnabled: true) == .idle)
    }

    @Test
    func matchingTelemetryConfirmsTheReceipt() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(), vin: vin))

        #expect(loop.observe(lockedState(), vin: vin))
        #expect(loop.isConfirmationPending == false)
        #expect(loop.awaitingCount == 0)
        // A confirmed lock stays on screen: the chip is the durable confirmation.
        #expect(loop.visibleReceipts.count == 1)
    }

    @Test
    func aStateThatDoesNotProveTheCommandConfirmsNothing() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(), vin: vin))

        // Right reading, stale timestamp: a cached frame must not confirm.
        var stale = lockedState()
        stale.freshness.isCached = true
        #expect(loop.observe(stale, vin: vin) == false)
        #expect(loop.isConfirmationPending)
    }

    @Test
    func aNewerCommandSupersedesThePendingOneInItsConflictGroup() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(), vin: vin))
        let unlock = CommandReceipt(
            commandIdentifier: RemoteCommand.unlock.identifier,
            issuedAt: startedAt.addingTimeInterval(5), command: .unlock)

        #expect(loop.begin(unlock, vin: vin))

        #expect(loop.awaitingCount == 1)
        #expect(loop.visibleReceipts.map(\.commandIdentifier) == [RemoteCommand.unlock.identifier])
    }

    @Test
    func theClockDecidesWhenAWindowLapses() {
        var currentTime = startedAt
        let (loop, _, cleanup) = makeLoop(window: 60, now: { currentTime })
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(issuedAt: startedAt), vin: vin))

        currentTime = startedAt.addingTimeInterval(30)
        #expect(loop.expireLapsedWindows(vin: vin) == false)

        currentTime = startedAt.addingTimeInterval(61)
        #expect(loop.expireLapsedWindows(vin: vin))
        // A lapsed window times out exactly once.
        #expect(loop.expireLapsedWindows(vin: vin) == false)
        #expect(loop.diagnosticRecord?.receipt.status
            == .timedOut(at: startedAt.addingTimeInterval(60)))
    }

    @Test
    func suspendingShiftsTheDeadlineByTheTimeSpentSuspended() {
        var currentTime = startedAt
        let (loop, _, cleanup) = makeLoop(window: 100, now: { currentTime })
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(issuedAt: startedAt), vin: vin))

        currentTime = startedAt.addingTimeInterval(10)
        loop.suspend()
        #expect(loop.isSuspended)

        // Asleep for 30 s: that time must not be charged against the confirmation window.
        currentTime = startedAt.addingTimeInterval(40)
        #expect(loop.resume())
        #expect(loop.isSuspended == false)

        currentTime = startedAt.addingTimeInterval(100)
        #expect(loop.expireLapsedWindows(vin: vin) == false)
        currentTime = startedAt.addingTimeInterval(131)
        #expect(loop.expireLapsedWindows(vin: vin))
    }

    @Test
    func anOffTargetReceiptWaitsUnderItsOwnVINAndStaysOutOfTheVisibleSet() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        let otherVIN = "CONFIRMATION-LOOP-OTHER"

        loop.recordOffTarget(lockReceipt(), targetVIN: otherVIN)

        // There is no live loop for a vehicle that is not selected, so it must not appear.
        #expect(loop.isEmpty)
        #expect(loop.visibleReceipts.isEmpty)
        // It is restored, not lost, when that vehicle is selected.
        #expect(loop.restore(forVIN: otherVIN))
        #expect(loop.visibleReceipts.count == 1)
        #expect(loop.isConfirmationPending)
    }

    @Test
    func optimisticFieldsNameExactlyWhatAnAwaitingCommandOwns() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        #expect(loop.begin(lockReceipt(), vin: vin))
        #expect(loop.optimisticFields == [.exterior])

        #expect(loop.begin(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(90).identifier,
            issuedAt: startedAt.addingTimeInterval(1), command: .setChargeTarget(90)), vin: vin))
        // Different conflict groups, so both stay awaiting and both keep their field.
        #expect(loop.optimisticFields == [.exterior, .chargeTarget])
    }

    @Test
    func aScheduledTickNarrowsTheFetchToWhatTheReceiptsNeedAndAManualOneDoesNot() {
        let (loop, _, cleanup) = makeLoop()
        defer { cleanup() }
        #expect(loop.targetedFeatures(isScheduledTick: true) == nil)
        #expect(loop.begin(lockReceipt(), vin: vin))

        #expect(loop.targetedFeatures(isScheduledTick: true)?.enabled == [RemoteCommand.lock.feature])
        #expect(loop.targetedFeatures(isScheduledTick: false) == nil)
    }

    // MARK: - Harness

    private func lockReceipt(issuedAt: Date = Date()) -> CommandReceipt {
        CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: issuedAt, command: .lock, targetVIN: vin)
    }

    /// The exterior reading that proves a lock, reported at the moment the command was issued.
    private func lockedState(reportedAt: Date = Date()) -> VehicleState {
        vehicle(
            vin: vin,
            exteriorStatus: ExteriorSnapshot(
                openings: [], isLocked: true, alarmTriggered: false, reportedAt: reportedAt)
        )
    }

    private func makeLoop(
        window: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) -> (CommandConfirmationLoop, VehicleStateStore, () -> Void) {
        let suite = "CommandConfirmationLoopTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        let loop = CommandConfirmationLoop(store: store, now: now, confirmationWindow: window)
        return (loop, store, { defaults.removePersistentDomain(forName: suite) })
    }
}
