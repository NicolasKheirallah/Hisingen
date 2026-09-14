import Foundation
import OSLog

/// Automatic, time-boxed history pruning.
///
/// `VehicleDatabase.pruneAgedHistory()` is the only thing that bounds growth of
/// `charging_sessions` / `battery_health_history` / `remote_commands_log` (the manual
/// "Prune Old Samples" Settings action does not touch those tables). Running it at most once
/// per week on launch keeps them bounded without user involvement; the pass deletes across
/// eight tables and then VACUUMs (a full-file rewrite on a multi-megabyte database), so it
/// runs off the main actor.
///
/// Extracted from `AppDelegate.pruneDatabaseIfDue`.
enum HistoryRetention {
    static let automaticInterval: TimeInterval = 7 * 86_400
    private static let lastRunKey = "last_automatic_history_prune"

    /// Prunes aged history if at least `automaticInterval` has elapsed since the last automatic
    /// run. The database work happens in a detached task and the run is stamped only after the
    /// prune succeeded, so a failed pass retries on the next launch instead of skipping
    /// retention for another week. A no-op when not due.
    static func pruneIfDue(
        database: VehicleDatabase,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        if let last = defaults.object(forKey: lastRunKey) as? Date,
           now.timeIntervalSince(last) < automaticInterval {
            return
        }
        // UserDefaults is thread-safe but not statically Sendable, and the stamp must go
        // through the caller-injected instance after the async prune. Rebind so the
        // detached boundary accepts the hand-off (same pattern as the calendar EventStore).
        nonisolated(unsafe) let defaults = defaults
        Task.detached(priority: .utility) {
            do {
                try database.pruneAgedHistoryOrThrow()
                defaults.set(now, forKey: lastRunKey)
            } catch {
                AppLog.logger("history-retention").error(
                    "Automatic history prune failed; it will retry next launch: \(error, privacy: .public)")
            }
        }
    }
}
