import Foundation
import OSLog

/// What the confirmation loop wants the transport to be doing.
///
/// The loop owns the decision; `RefreshCoordinator` owns the stream and poll machinery that
/// carries it out. That inversion is what makes the rules testable without a provider.
enum CommandConfirmationTransport: Equatable {
    /// A live stream with this purpose could prove an awaiting receipt.
    case stream(VehicleLiveStreamPurpose)
    /// No stream carries this proof, so the union of these features must be polled after the
    /// given delay.
    case poll(features: [AppFeature], after: TimeInterval)
    /// Nothing is awaiting confirmation.
    case idle
}

/// Owns the Command receipt lifecycle end to end: the records, their deadlines, the watchdog,
/// the display fields an awaiting command still owns, and which transport could prove it.
///
/// `RefreshCoordinator` supplies the states to reconcile against and carries out the transport
/// the loop asks for. Everything the command-receipt feature knows lives here, so a test can
/// drive a whole receipt from accepted to confirmed or timed out with a fake clock instead of a
/// provider, seven collaborators and real timers.
@MainActor
final class CommandConfirmationLoop {
    private let logger = AppLog.logger("command-receipts")
    /// The record store. An internal seam: its transitions are reachable through this type.
    private let ledger: CommandConfirmationLedger
    private let now: () -> Date
    /// First check after a command is accepted. Bounded by `pollInterval` so a caller that
    /// shortens the poll cadence does not accidentally wait longer for the first read.
    let initialPollDelay: TimeInterval
    /// Cadence of the targeted poll while a receipt still awaits proof.
    let pollInterval: TimeInterval
    private let watchdog = AsyncTimerLoop()

    init(
        store: VehicleStateStore,
        now: @escaping () -> Date = Date.init,
        confirmationWindow: TimeInterval = CommandReceipt.maximumConfirmationDuration,
        initialPollDelay: TimeInterval = 2,
        pollInterval: TimeInterval = 3
    ) {
        self.ledger = CommandConfirmationLedger(
            store: store, now: now, confirmationWindow: confirmationWindow)
        self.now = now
        self.initialPollDelay = initialPollDelay
        self.pollInterval = pollInterval
    }

    // MARK: - Observation

    var isEmpty: Bool { ledger.isEmpty }
    var visibleReceipts: [CommandReceipt] { ledger.visibleReceipts }
    var isConfirmationPending: Bool { ledger.isConfirmationPending }
    var isSuspended: Bool { ledger.suspensionStartedAt != nil }
    var awaitingCount: Int { ledger.activeRecords.count }
    /// The receipt the diagnostics snapshot describes: the newest awaiting one, else the newest
    /// settled one.
    var diagnosticRecord: StoredCommandReceipt? { ledger.activeRecords.last ?? ledger.records.last }
    var records: [StoredCommandReceipt] { ledger.records }

    /// Display-only fields an awaiting command still owns. The caller keeps its optimistic value
    /// for exactly these and accepts the authoritative read for every other field.
    var optimisticFields: Set<CommandDisplayField> {
        Set(ledger.activeRecords.compactMap { $0.receipt.command?.descriptor.displayField })
    }

    // MARK: - Transitions

    /// Records an accepted command, superseding any pending one in its conflict group. Returns
    /// whether it still awaits telemetry; a receipt with no observable proof settles on the
    /// provider's acknowledgement.
    @discardableResult
    func begin(_ receipt: CommandReceipt, vin: String?) -> Bool {
        ledger.begin(receipt)
        ledger.persist(vin: vin)
        logger.info(
            "Command confirmation started for \(receipt.commandIdentifier, privacy: .public); telemetry observable: \(receipt.supportsTelemetryConfirmation, privacy: .public)"
        )
        return receipt.status.isAwaiting
    }

    /// Records a receipt for a vehicle that is not the selected one. It never enters the
    /// in-memory collection, so it cannot be dismissed from here: it waits under the target's
    /// VIN and is restored when that vehicle is selected.
    func recordOffTarget(_ receipt: CommandReceipt, targetVIN: String) {
        ledger.recordOffTarget(receipt, targetVIN: targetVIN)
    }

    @discardableResult
    func dismiss(id: UUID, vin: String?) -> Bool { ledger.dismiss(id: id, vin: vin) }

    @discardableResult
    func dismiss(issuedAt: Date, vin: String?) -> Bool { ledger.dismiss(issuedAt: issuedAt, vin: vin) }

    @discardableResult
    func restore(forVIN vin: String) -> Bool { ledger.restore(forVIN: vin) }

    func clear() { ledger.clear() }

    func persist(vin: String?) { ledger.persist(vin: vin) }

    /// Marks the suspension point so deadlines can shift by the suspension length on resume.
    func suspend() { ledger.suspend() }

    /// Extends every awaiting deadline by the suspension length. Returns whether anything moved.
    @discardableResult
    func resume() -> Bool { ledger.resume() }

    /// Moves awaiting receipts to confirmed when this state shows the command's effect. Returns
    /// whether anything confirmed.
    @discardableResult
    func observe(_ state: VehicleState, vin: String?) -> Bool {
        guard !ledger.isEmpty else { return false }
        return !ledger.reconcile(against: state, vin: vin).isEmpty
    }

    /// Times out any window that lapsed. The only awaiting-to-timed-out transition.
    @discardableResult
    func expireLapsedWindows(vin: String?) -> Bool {
        guard ledger.nextDeadline.map({ $0 <= now() }) == true else { return false }
        guard ledger.timeOutExpired() else { return false }
        ledger.clearSuspension()
        ledger.persist(vin: vin)
        return true
    }

    // MARK: - Transport

    /// Which transport could prove the awaiting receipts, if any.
    ///
    /// The purpose is not derived from `CommandDescriptor.displayField`: that field is a superset
    /// (`.stopChargingOverride` shares `.chargingState` with the override that streams, and the
    /// interior commands share `.exterior`), so deriving it would start streams for commands the
    /// available endpoints cannot prove.
    func transport(for state: VehicleState, realTimeEnabled: Bool) -> CommandConfirmationTransport {
        if realTimeEnabled,
           let purpose = ledger.activeRecords.reversed().lazy.compactMap({
               Self.streamPurpose(for: $0.receipt)
           }).first {
            return .stream(purpose)
        }
        let features = Array(pollFeatures).sorted { $0.rawValue < $1.rawValue }
        guard !features.isEmpty else { return .idle }
        return .poll(features: features, after: pollInterval)
    }

    /// Features a targeted poll must request to cover every awaiting receipt. `nil` when nothing
    /// awaits telemetry, which leaves an ordinary refresh to fetch the user's full selection.
    func targetedFeatures(isScheduledTick: Bool) -> FeatureSelection? {
        guard isScheduledTick, ledger.isConfirmationPending else { return nil }
        let enabled = pollFeatures
        return enabled.isEmpty ? nil : FeatureSelection(enabled: enabled)
    }

    private var pollFeatures: Set<AppFeature> {
        Set(ledger.activeRecords.compactMap { $0.receipt.confirmationFeatures }.flatMap(\.enabled))
    }

    private static func streamPurpose(for receipt: CommandReceipt) -> VehicleLiveStreamPurpose? {
        switch receipt.command {
        case .startChargingOverride:
            return .charging
        case .lock, .unlock,
             .openTailgate, .closeTailgate, .openWindows, .closeWindows:
            return .exteriorConfirmation
        default:
            return nil
        }
    }

    // MARK: - Watchdog

    /// Arms the watchdog for the earliest deadline. A held-open exterior stream only
    /// re-evaluates its purpose on the next frame or reconnect, so on a quiet car nothing would
    /// notice the window closing. `isValid` is the caller's generation guard; `onExpiry` runs
    /// once the records were checked, and reports whether any window actually lapsed.
    func armWatchdog(
        vin: String,
        isValid: @escaping @MainActor () -> Bool,
        onExpiry: @escaping @MainActor (Bool) -> Void
    ) {
        watchdog.cancel()
        guard let until = ledger.nextDeadline else { return }
        watchdog.scheduleOnce(after: max(0.05, until.timeIntervalSince(now()))) { [weak self] in
            guard let self, isValid() else { return }
            onExpiry(self.expireLapsedWindows(vin: vin))
        }
    }

    func cancelWatchdog() { watchdog.cancel() }
}
