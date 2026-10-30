import Foundation
import OSLog

/// Automatic, time-boxed history pruning.
///
/// `LocalDataEraser.erase(.aged)` is the only thing that bounds growth of
/// `charging_sessions` / `battery_health_history` / `remote_commands_log` (the manual
/// "Prune Old Samples" Settings action does not touch those tables). Running it at most once
/// per week on launch keeps them bounded without user involvement. The pass also trims
/// `charging_samples` and `telemetry_logs` to the Settings sample retention, deletes across
/// those tables, and then VACUUMs once (a full-file rewrite on a multi-megabyte database), so
/// it runs off the main actor.
///
/// Extracted from `AppDelegate.pruneDatabaseIfDue`.
enum HistoryRetention {
    static let automaticInterval: TimeInterval = 7 * 86_400
    private static let lastRunKey = "last_automatic_history_prune"
    /// Same key and allowed values as `PreferencesStore.historySampleRetentionDays`, which is
    /// main-actor isolated and so cannot be read from the detached prune.
    private static let sampleRetentionKey = "history_sample_retention_days"
    private static let allowedSampleRetentionDays = [30, 90, 180, 365]
    private static let defaultSampleRetentionDays = 90

    // UserDefaults synchronizes access internally. Keep the injected suite together with
    // the write that crosses the detached task boundary.
    private struct PruneStamp: @unchecked Sendable {
        let defaults: UserDefaults

        func record(_ date: Date) {
            defaults.set(date, forKey: lastRunKey)
        }
    }

    /// The sample retention the Settings picker saved, falling back to the default for unset
    /// or out-of-range values exactly as the preference does.
    static func sampleRetentionDays(defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: sampleRetentionKey)
        return allowedSampleRetentionDays.contains(value) ? value : defaultSampleRetentionDays
    }

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
        let stamp = PruneStamp(defaults: defaults)
        let sampleDays = sampleRetentionDays(defaults: defaults)
        Task.detached(priority: .utility) {
            do {
                try database.pruneAgedHistoryOrThrow(sampleRetentionDays: sampleDays)
                stamp.record(now)
            } catch {
                AppLog.logger("history-retention").error(
                    "Automatic history prune failed; it will retry next launch: \(error, privacy: .public)")
            }
        }
    }
}
