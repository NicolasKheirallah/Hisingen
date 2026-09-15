import Foundation
import OSLog

/// Sole owner of the Command receipt lifecycle: the pending receipt records, their
/// confirmation deadlines, suspension across sleep or brand switches, relaunch restore,
/// persistence, and the timeout transition. Awaiting→confirmed is driven by telemetry
/// (`reconcile(against:)`); awaiting→timed-out only ever happens here.
///
/// The ledger is VIN-agnostic on purpose: the caller supplies the VIN to persist under,
/// because a receipt for a non-selected Remote Command target must survive under that
/// target's VIN, not the selection's.
@MainActor
final class CommandConfirmationLedger {
    private let store: VehicleStateStore
    private let now: () -> Date
    private let confirmationWindow: TimeInterval
    private let logger = AppLog.logger("command-receipts")

    private(set) var records: [StoredCommandReceipt] = []
    private(set) var dismissedIDs: Set<UUID> = []
    /// When confirmations were suspended (sleep, brand switch, suspend-across-suspension);
    /// `nil` while confirmations run normally.
    private(set) var suspensionStartedAt: Date?

    init(store: VehicleStateStore,
         now: @escaping () -> Date = Date.init,
         confirmationWindow: TimeInterval = CommandReceipt.maximumConfirmationDuration) {
        self.store = store
        self.now = now
        self.confirmationWindow = confirmationWindow
    }

    // MARK: - Transitions

    /// Records a newly accepted command for the selected vehicle, superseding any pending
    /// receipt in the same conflict group.
    func begin(_ receipt: CommandReceipt) {
        if let conflictGroup = receipt.confirmationConflictKey {
            records.removeAll { $0.receipt.confirmationConflictKey == conflictGroup }
        }
        records.append(StoredCommandReceipt(
            receipt: receipt,
            confirmationDeadline: receipt.status.isAwaiting ? now().addingTimeInterval(confirmationWindow) : nil
        ))
        trim()
        suspensionStartedAt = nil
    }

    /// Persists a receipt for a vehicle that is not the currently selected one. There is no
    /// live confirmation loop for it; the record survives relaunch under the target VIN and
    /// is restored when the user selects that vehicle again.
    func recordOffTarget(_ receipt: CommandReceipt, targetVIN: String) {
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

    @discardableResult
    func dismiss(id: UUID, vin: String?) -> Bool {
        guard let index = records.firstIndex(where: { $0.receipt.id == id }) else { return false }
        let identifier = records[index].receipt.commandIdentifier
        dismissedIDs.insert(id)
        persist(vin: vin)
        logger.info("Command receipt dismissed for \(identifier, privacy: .public)")
        return true
    }

    func dismiss(issuedAt: Date, vin: String?) -> Bool {
        guard let id = records.first(where: { $0.receipt.issuedAt == issuedAt })?.receipt.id else { return false }
        return dismiss(id: id, vin: vin)
    }

    /// Moves awaiting receipts to confirmed when fresh telemetry shows the command's effect,
    /// first closing out any window that lapsed. Persists under `vin` when the ledger
    /// changed. Returns which receipts confirmed during this pass.
    @discardableResult
    func reconcile(against state: VehicleState, vin: String?, currentDate: Date? = nil) -> [CommandReceipt] {
        if timeOutExpired() { persist(vin: vin) }
        var confirmed: [CommandReceipt] = []
        for index in records.indices where records[index].receipt.status.isAwaiting {
            let previous = records[index].receipt
            let updated = previous.updatingConfirmation(from: state, now: currentDate ?? now())
            records[index].receipt = updated
            if previous.status.isAwaiting, updated.status.isConfirmed {
                records[index].confirmationDeadline = nil
                confirmed.append(updated)
                if let auditID = updated.auditID {
                    store.database.updateCommandAudit(id: auditID, status: "confirmed")
                }
                logger.info(
                    "Command confirmation matched fresh telemetry for \(updated.commandIdentifier, privacy: .public)"
                )
            }
        }
        if !confirmed.isEmpty { persist(vin: vin) }
        return confirmed
    }

    /// The only awaiting→timed-out transition. Returns whether anything timed out.
    @discardableResult
    func timeOutExpired() -> Bool {
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

    /// Drops the suspension marker without shifting deadlines (the window already lapsed).
    func clearSuspension() {
        suspensionStartedAt = nil
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
    func trim() {
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

    /// Awaiting receipts whose confirmation window is still open.
    var activeRecords: [StoredCommandReceipt] {
        let currentDate = now()
        return records.filter {
            $0.receipt.status.isAwaiting && $0.confirmationDeadline.map { $0 > currentDate } == true
        }
    }

    var isConfirmationPending: Bool {
        activeRecords.contains { $0.receipt.supportsTelemetryConfirmation }
    }

    var nextDeadline: Date? {
        records.compactMap { $0.receipt.status.isAwaiting ? $0.confirmationDeadline : nil }.min()
    }
}
