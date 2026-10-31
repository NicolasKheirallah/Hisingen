import Foundation

extension VehicleDatabase {
    /// Error-reporting variant used by Settings so success is only shown after the
    /// transaction and compaction both finish.
    func pruneHistoricalSamplesOrThrow(olderThanDays: Int = 90) throws {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays * 86400))
        try db.withTransaction {
            try db.query(sql: "DELETE FROM charging_samples WHERE timestamp < ?;") { stmt in
                try stmt.bindDate(cutoff, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try db.query(sql: "DELETE FROM telemetry_logs WHERE timestamp < ?;") { stmt in
                try stmt.bindDate(cutoff, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        try vacuumOrThrow()
    }

    /// The horizon the storage card states next to the sample-retention picker, so the two
    /// numbers the reader compares come from one place.
    static let sessionRetentionDays = 730

    /// Bounds growth of the tables that previously had no retention path at all (manual or
    /// automatic) – `charging_sessions`, `battery_health_history`, `remote_commands_log`,
    /// and the per-hour `connectivity_history`/`cabin_climate_history` heartbeats. Defaults
    /// are deliberately longer than `pruneHistoricalSamples`'s 90 days: the session/health/
    /// audit rows are low-volume summaries (one per charge, one per command, health is
    /// change-gated), so there's little storage pressure to justify discarding a user's
    /// longer-term charging or health history as aggressively as the high-volume samples.
    /// `sampleRetentionDays` is opt-in: when set, `charging_samples` and `telemetry_logs` are
    /// pruned to that horizon too (the Settings retention picker). The one VACUUM at the end
    /// covers every table in the pass.
    func pruneAgedHistoryOrThrow(
        chargingSessionsOlderThanDays: Int = VehicleDatabase.sessionRetentionDays,
        batteryHealthOlderThanDays: Int = VehicleDatabase.sessionRetentionDays,
        commandAuditsOlderThanDays: Int = 180,
        airQualityOlderThanDays: Int = 365,
        tyrePressureOlderThanDays: Int = 365,
        warningEventsOlderThanDays: Int = 365,
        connectivityOlderThanDays: Int = 180,
        cabinClimateOlderThanDays: Int = 180,
        vehicleImagesOlderThanDays: Int = 120,
        vehicleImagesHardCap: Int = 24,
        sampleRetentionDays: Int? = nil
    ) throws {
        var cutoffs: [(sql: String, column: String, days: Int)] = [
            ("DELETE FROM charging_sessions WHERE started_at < ?;", "started_at", chargingSessionsOlderThanDays),
            ("DELETE FROM battery_health_history WHERE timestamp < ?;", "timestamp", batteryHealthOlderThanDays),
            ("DELETE FROM remote_commands_log WHERE executed_at < ?;", "executed_at", commandAuditsOlderThanDays),
            ("DELETE FROM vehicle_activity WHERE timestamp < ?;", "timestamp", commandAuditsOlderThanDays),
            ("DELETE FROM air_quality_history WHERE timestamp < ?;", "timestamp", airQualityOlderThanDays),
            ("DELETE FROM tyre_pressure_history WHERE timestamp < ?;", "timestamp", tyrePressureOlderThanDays),
            // Only closed episodes age out. An open one is still true of the car, and dropping it
            // would make the next report open a second episode with a later start.
            ("DELETE FROM vehicle_warning_events WHERE cleared_at IS NOT NULL AND cleared_at < ?;",
             "cleared_at", warningEventsOlderThanDays),
            ("DELETE FROM connectivity_history WHERE timestamp < ?;", "timestamp", connectivityOlderThanDays),
            ("DELETE FROM cabin_climate_history WHERE timestamp < ?;", "timestamp", cabinClimateOlderThanDays),
            // The render-image cache stores a full-resolution PNG plus a thumbnail per
            // (vin, angle) and was never pruned – it is the single biggest contributor to a
            // multi-megabyte database on accounts that have tried several render angles.
            ("DELETE FROM vehicle_images WHERE updated_at < ?;", "updated_at", vehicleImagesOlderThanDays)
        ]
        if let sampleRetentionDays {
            cutoffs += [
                ("DELETE FROM charging_samples WHERE timestamp < ?;", "timestamp", sampleRetentionDays),
                ("DELETE FROM telemetry_logs WHERE timestamp < ?;", "timestamp", sampleRetentionDays)
            ]
        }
        try db.withTransaction {
            for (sql, _, days) in cutoffs {
                let cutoff = Date().addingTimeInterval(-Double(days * 86400))
                try db.query(sql: sql) { stmt in
                    try stmt.bindDate(cutoff, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
            // Hard ceiling regardless of age: keep only the most-recently-refreshed rows.
            try db.query(
                sql: "DELETE FROM vehicle_images WHERE rowid NOT IN (SELECT rowid FROM vehicle_images ORDER BY updated_at DESC LIMIT ?);"
            ) { stmt in
                try stmt.bindInt64(Int64(vehicleImagesHardCap), at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        try vacuumOrThrow()
    }
}
