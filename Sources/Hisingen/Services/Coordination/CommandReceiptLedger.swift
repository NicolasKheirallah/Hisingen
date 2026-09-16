import Foundation
import OSLog

/// What the receipt module wants the transport to be doing.
///
/// The module owns the decision; `RefreshCoordinator` owns the stream and poll machinery that
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

/// Where a newly accepted Remote Command's receipt was filed.
struct CommandReceiptFiling: Equatable {
    /// The receipt belongs to the selected vehicle and joined the live collection, so the
    /// caller can publish it and start proving it.
    let isForSelectedVehicle: Bool
    /// The command has an observable effect, so its confirmation window is open.
    let awaitsTelemetry: Bool
}

/// Sole owner of the Command receipt lifecycle: which vehicle a receipt is filed under, the
/// pending records, their confirmation deadlines, suspension across sleep or brand switches,
/// relaunch restore, persistence, the timeout transition, the display fields an awaiting command
/// still owns, and which transport could prove it.
///
/// Awaiting→confirmed is driven by telemetry (`observe(_:vin:)`); awaiting→timed-out only ever
/// happens here. `RefreshCoordinator` supplies the states to observe against and carries out the
/// transport the module asks for. Everything the Command receipt feature knows lives here, so a
/// test can drive a whole receipt from accepted to confirmed or timed out with a fake clock
/// instead of a provider, seven collaborators and real timers.
///
/// Filing is the other half of that ownership: the module compares the receipt's Remote Command
/// target against the selected VIN and decides whether the receipt joins the live collection or
/// waits under the target's VIN. No entry point and no shell holds that rule.
///
/// The module is otherwise VIN-agnostic on purpose: the caller supplies the VIN to persist under,
/// because a receipt for a non-selected target must survive under that target's VIN, not the
/// selection's.
@MainActor
final class CommandReceiptLedger {
    private let store: VehicleStateStore
    private let now: () -> Date
    private let confirmationWindow: TimeInterval
    private let logger = AppLog.logger("command-receipts")

    /// First check after a command is accepted. Bounded by `pollInterval` so a caller that
    /// shortens the poll cadence does not accidentally wait longer for the first read.
    let initialPollDelay: TimeInterval
    /// Cadence of the targeted poll while a receipt still awaits proof.
    let pollInterval: TimeInterval
    private let watchdog = AsyncTimerLoop()

    private var records: [StoredCommandReceipt] = []
    private var dismissedIDs: Set<UUID> = []
    /// When confirmations were suspended (sleep, brand switch, suspend-across-suspension);
    /// `nil` while confirmations run normally.
    private var suspensionStartedAt: Date?

    init(
        store: VehicleStateStore,
        now: @escaping () -> Date = Date.init,
        confirmationWindow: TimeInterval = CommandReceipt.maximumConfirmationDuration,
        initialPollDelay: TimeInterval = 2,
        pollInterval: TimeInterval = 3
    ) {
        self.store = store
        self.now = now
        self.confirmationWindow = confirmationWindow
        self.initialPollDelay = initialPollDelay
        self.pollInterval = pollInterval
    }

    // MARK: - Filing

    /// Files a newly accepted command against the selected vehicle.
    ///
    /// A receipt whose Remote Command target is not the selected vehicle is persisted under the
    /// target's VIN instead: it never enters the live collection, because no live confirmation
    /// loop can prove it here, and it is restored when that vehicle is selected. A receipt with
    /// no recorded target belongs to whatever is selected. Returns where it went, so the caller
    /// knows whether there is anything to publish or prove.
    @discardableResult
    func begin(_ receipt: CommandReceipt, selectedVIN: String?) -> CommandReceiptFiling {
        if let targetVIN = receipt.targetVIN,
           selectedVIN?.caseInsensitiveCompare(targetVIN) != .orderedSame {
            recordOffTarget(receipt, targetVIN: targetVIN)
            return CommandReceiptFiling(isForSelectedVehicle: false, awaitsTelemetry: false)
        }
        if let conflictGroup = receipt.confirmationConflictKey {
            records.removeAll { $0.receipt.confirmationConflictKey == conflictGroup }
        }
        records.append(StoredCommandReceipt(
            receipt: receipt,
            confirmationDeadline: receipt.status.isAwaiting
                ? now().addingTimeInterval(confirmationWindow)
                : nil
        ))
        trim()
        suspensionStartedAt = nil
        persist(vin: selectedVIN)
        logger.info(
            "Command confirmation started for \(receipt.commandIdentifier, privacy: .public); telemetry observable: \(receipt.supportsTelemetryConfirmation, privacy: .public)"
        )
        return CommandReceiptFiling(
            isForSelectedVehicle: true, awaitsTelemetry: receipt.status.isAwaiting)
    }

    /// Persists a receipt for a vehicle that is not the currently selected one. There is no
    /// live confirmation loop for it; the record survives relaunch under the target VIN and
    /// is restored when the user selects that vehicle again.
    private func recordOffTarget(_ receipt: CommandReceipt, targetVIN: String) {
        var stored = store.commandReceipts(for: targetVIN)
        if let conflictGroup = receipt.confirmationConflictKey {
            stored.removeAll { $0.receipt.confirmationConflictKey == conflictGroup }
        }
        stored.append(StoredCommandReceipt(
            receipt: receipt,
            confirmationDeadline: receipt.status.isAwaiting
                ? receipt.issuedAt.addingTimeInterval(confirmationWindow)
                : nil
        ))
        store.saveCommandReceipts(stored, for: targetVIN)
    }

    // MARK: - Transitions

    @discardableResult
    func dismiss(id: UUID, vin: String?) -> Bool {
        guard let index = records.firstIndex(where: { $0.receipt.id == id }) else { return false }
        let identifier = records[index].receipt.commandIdentifier
        dismissedIDs.insert(id)
        persist(vin: vin)
        logger.info("Command receipt dismissed for \(identifier, privacy: .public)")
        return true
    }

    @discardableResult
    func dismiss(issuedAt: Date, vin: String?) -> Bool {
        guard let id = records.first(where: { $0.receipt.issuedAt == issuedAt })?.receipt.id else {
            return false
        }
        return dismiss(id: id, vin: vin)
    }

    /// Moves awaiting receipts to confirmed when this state shows the command's effect, first
    /// closing out any window that lapsed. Persists under `vin` when anything changed. Returns
    /// whether any receipt confirmed during this pass.
    @discardableResult
    func observe(_ state: VehicleState, vin: String?) -> Bool {
        guard !records.isEmpty else { return false }
        if timeOutExpired() { persist(vin: vin) }
        var confirmed = false
        for index in records.indices where records[index].receipt.status.isAwaiting {
            let previous = records[index].receipt
            let updated = previous.updatingConfirmation(from: state, now: now())
            records[index].receipt = updated
            if previous.status.isAwaiting, updated.status.isConfirmed {
                records[index].confirmationDeadline = nil
                confirmed = true
                if let auditID = updated.auditID {
                    store.database.updateCommandAudit(id: auditID, status: "confirmed")
                }
                logger.info(
                    "Command confirmation matched fresh telemetry for \(updated.commandIdentifier, privacy: .public)"
                )
            }
        }
        if confirmed { persist(vin: vin) }
        return confirmed
    }

    /// Times out any window that lapsed. The only awaiting-to-timed-out transition.
    @discardableResult
    func expireLapsedWindows(vin: String?) -> Bool {
        guard nextDeadline.map({ $0 <= now() }) == true else { return false }
        guard timeOutExpired() else { return false }
        suspensionStartedAt = nil
        persist(vin: vin)
        return true
    }

    /// The only awaiting→timed-out transition. Returns whether anything timed out.
    private func timeOutExpired() -> Bool {
        let currentDate = now()
        var changed = false
        for index in records.indices {
            guard records[index].receipt.status.isAwaiting,
                  let deadline = records[index].confirmationDeadline,
                  deadline <= currentDate else { continue }
            records[index].receipt.status = .timedOut(at: deadline)
            records[index].confirmationDeadline = nil
            if let auditID = records[index].receipt.auditID {
                store.database.updateCommandAudit(id: auditID, status: "confirmation_timed_out")
            }
            changed = true
            logger.info(
                "Command confirmation timed out for \(self.records[index].receipt.commandIdentifier, privacy: .public)"
            )
        }
        guard changed else { return false }
        trim()
        return true
    }

    /// Marks the suspension point so deadlines can shift by the suspension length on resume.
    func suspend() {
        guard suspensionStartedAt == nil, !records.isEmpty else { return }
        suspensionStartedAt = now()
        logger.info("Command confirmations suspended: \(self.activeRecords.count, privacy: .public)")
    }

    /// Resumes confirmations, extending every awaiting deadline by the suspension length so
    /// time spent asleep or switching brands does not consume the confirmation window.
    /// Returns whether any awaiting receipt was adjusted.
    @discardableResult
    func resume() -> Bool {
        guard let suspendedAt = suspensionStartedAt else { return false }
        suspensionStartedAt = nil
        let suspensionDuration = max(0, now().timeIntervalSince(suspendedAt))
        guard records.contains(where: { $0.receipt.status.isAwaiting }) else { return false }
        for index in records.indices where records[index].receipt.status.isAwaiting {
            records[index].confirmationDeadline = records[index].confirmationDeadline?
                .addingTimeInterval(suspensionDuration)
        }
        logger.info("Command confirmations resumed: \(self.activeRecords.count, privacy: .public)")
        return true
    }

    /// Drops everything without persisting a farewell – used when the vehicle or brand
    /// changed and the pending receipts belong to the previous target.
    func clear() {
        records = []
        dismissedIDs = []
        suspensionStartedAt = nil
    }

    /// Loads a vehicle's persisted receipts after relaunch or reselect, superseding stale
    /// conflict groups, timing out windows that lapsed while the app was closed, and
    /// persisting the settled set back. Returns whether anything was restored.
    @discardableResult
    func restore(forVIN vin: String) -> Bool {
        var stored = store.commandReceipts(for: vin)
        guard !stored.isEmpty else { return false }
        let currentDate = now()
        dismissedIDs = []
        suspensionStartedAt = nil
        for index in stored.indices where stored[index].receipt.status.isAwaiting {
            let deadline = stored[index].confirmationDeadline
                ?? stored[index].receipt.issuedAt.addingTimeInterval(confirmationWindow)
            if deadline <= currentDate {
                stored[index].receipt.status = .timedOut(at: deadline)
                stored[index].confirmationDeadline = nil
            } else {
                stored[index].confirmationDeadline = deadline
            }
        }
        let newestReceiptByConflict = Dictionary(
            grouping: stored.filter { $0.receipt.confirmationConflictKey != nil },
            by: { $0.receipt.confirmationConflictKey! }
        ).compactMapValues { group in group.max { $0.receipt.issuedAt < $1.receipt.issuedAt }?.receipt.id }
        stored.removeAll { record in
            guard let key = record.receipt.confirmationConflictKey else { return false }
            return newestReceiptByConflict[key] != record.receipt.id
        }
        records = stored
        trim()
        store.saveCommandReceipts(records, for: vin)
        logger.info("Command receipts restored after relaunch: \(self.records.count, privacy: .public)")
        return true
    }

    /// Writes the non-dismissed records under `vin`, clearing the stored set when empty.
    func persist(vin: String?) {
        guard let vin else { return }
        let surviving = records.filter { !dismissedIDs.contains($0.receipt.id) }
        if surviving.isEmpty {
            store.clearCommandReceipts(for: vin)
        } else {
            store.saveCommandReceipts(surviving, for: vin)
        }
    }

    /// Keeps at most `maximumRetainedTerminalCount` settled receipts around for display.
    private func trim() {
        while records.lazy.filter({ $0.receipt.status.isTerminal }).count
                > CommandReceipt.maximumRetainedTerminalCount,
              let removable = records.firstIndex(where: { $0.receipt.status.isTerminal }) {
            dismissedIDs.remove(records[removable].receipt.id)
            records.remove(at: removable)
        }
    }

    // MARK: - Observation

    var isEmpty: Bool { records.isEmpty }

    /// Receipts a vehicle card should show: not dismissed, not silently acknowledged, and
    /// climate confirmations disappear once confirmed (the dashboard shows the result).
    var visibleReceipts: [CommandReceipt] {
        records.map(\.receipt).filter {
            !dismissedIDs.contains($0.id)
                && !$0.status.isAcknowledged
                && !($0.isClimateCommand && $0.status.isConfirmed)
        }
    }

    /// The overlay to publish: the receipts this ledger is showing, paired here so that no caller
    /// assembles a `CommandPresentationState` of its own.
    var overlay: CommandPresentationState {
        CommandPresentationState(receipts: visibleReceipts)
    }

    /// Awaiting receipts whose confirmation window is still open.
    private var activeRecords: [StoredCommandReceipt] {
        let currentDate = now()
        return records.filter {
            $0.receipt.status.isAwaiting && $0.confirmationDeadline.map { $0 > currentDate } == true
        }
    }

    var isConfirmationPending: Bool {
        activeRecords.contains { $0.receipt.supportsTelemetryConfirmation }
    }

    var isSuspended: Bool { suspensionStartedAt != nil }

    var awaitingCount: Int { activeRecords.count }

    /// The receipt the diagnostics snapshot describes: the newest awaiting one, else the newest
    /// settled one.
    var diagnosticRecord: StoredCommandReceipt? { activeRecords.last ?? records.last }

    /// Display-only fields an awaiting command still owns. The caller keeps its optimistic value
    /// for exactly these and accepts the authoritative read for every other field.
    var optimisticFields: Set<CommandDisplayField> {
        Set(activeRecords.compactMap { $0.receipt.command?.descriptor.displayField })
    }

    private var nextDeadline: Date? {
        records.compactMap { $0.receipt.status.isAwaiting ? $0.confirmationDeadline : nil }.min()
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
           let purpose = activeRecords.reversed().lazy.compactMap({
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
        guard isScheduledTick, isConfirmationPending else { return nil }
        let enabled = pollFeatures
        return enabled.isEmpty ? nil : FeatureSelection(enabled: enabled)
    }

    private var pollFeatures: Set<AppFeature> {
        Set(activeRecords.compactMap { $0.receipt.confirmationFeatures }.flatMap(\.enabled))
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
        guard let until = nextDeadline else { return }
        watchdog.scheduleOnce(after: max(0.05, until.timeIntervalSince(now()))) { [weak self] in
            guard let self, isValid() else { return }
            onExpiry(self.expireLapsedWindows(vin: vin))
        }
    }

    func cancelWatchdog() { watchdog.cancel() }
}
