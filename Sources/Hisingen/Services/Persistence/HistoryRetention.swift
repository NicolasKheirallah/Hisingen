import Foundation

/// Automatic, time-boxed history pruning.
///
/// `VehicleDatabase.pruneAgedHistory()` is the only thing that bounds growth of
/// `charging_sessions` / `battery_health_history` / `remote_commands_log` (the manual
/// "Prune Old Samples" Settings action does not touch those tables). Running it at most once
/// per week on launch keeps them bounded without user involvement; the tables are low-row-count
/// so the call is cheap enough to make synchronously.
///
/// Extracted from `AppDelegate.pruneDatabaseIfDue`.
enum HistoryRetention {
    static let automaticInterval: TimeInterval = 7 * 86_400
    private static let lastRunKey = "last_automatic_history_prune"

    /// Prunes aged history if at least `automaticInterval` has elapsed since the last automatic
    /// run, then records the run. A no-op otherwise.
    static func pruneIfDue(
        database: VehicleDatabase,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        if let last = defaults.object(forKey: lastRunKey) as? Date,
           now.timeIntervalSince(last) < automaticInterval {
            return
        }
        database.pruneAgedHistory()
        defaults.set(now, forKey: lastRunKey)
    }
}
