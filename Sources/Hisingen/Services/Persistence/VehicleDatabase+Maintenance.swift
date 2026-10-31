import Foundation

extension VehicleDatabase {
    // MARK: - Database Diagnostics & Maintenance

    /// Size of the database file and its WAL/SHM siblings. Uses the handle's own path, so an
    /// in-memory or unavailable handle reports 0 instead of the on-disk file's size.
    var databaseSizeBytes: Int64 {
        [db.path, db.path + "-wal", db.path + "-shm"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    func recordCounts() -> (snapshots: Int, chargingSessions: Int, chargingSamples: Int, batteryHealth: Int, telemetry: Int, commands: Int) {
        func count(table: String) -> Int {
            let sql = "SELECT COUNT(*) FROM \(table);"
            let c = try? db.query(sql: sql) { _ in } process: { stmt -> Int in
                try stmt.stepOrThrow() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
            }
            return c ?? 0
        }
        return (
            snapshots: count(table: "vehicle_snapshots"),
            chargingSessions: count(table: "charging_sessions"),
            chargingSamples: count(table: "charging_samples"),
            batteryHealth: count(table: "battery_health_history WHERE \(BatteryHealthRecord.measurementSourceFilter)"),
            telemetry: count(table: "telemetry_logs"),
            commands: count(table: "remote_commands_log")
        )
    }

    /// Maintenance entry point for interactive callers. Throws so a caller that shows success
    /// only reports it after the work finished; callers that want best effort write `try?` at
    /// the call site rather than choosing it here.
    func vacuumOrThrow() throws {
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        try db.execute(sql: "VACUUM;")
    }
}
