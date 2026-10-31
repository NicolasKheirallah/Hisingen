import Foundation

extension VehicleDatabase {
    func clearStoredLocationsOrThrow(for vin: String) throws {
        try db.withTransaction {
            try db.query(sql: "UPDATE telemetry_logs SET latitude = NULL, longitude = NULL WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try db.query(sql: "UPDATE charging_sessions SET location_name = NULL WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        try vacuumOrThrow()
    }

    /// The fleet-wide counterpart of `clearStoredLocationsOrThrow(for:)`, named so that
    /// clearing every vehicle's coordinates is always a deliberate call.
    func clearAllStoredLocationsOrThrow() throws {
        try db.withTransaction {
            try db.execute(sql: "UPDATE telemetry_logs SET latitude = NULL, longitude = NULL;")
            try db.execute(sql: "UPDATE charging_sessions SET location_name = NULL;")
        }
        try vacuumOrThrow()
    }

    // MARK: - Wipe / Purge

    func wipeVehicleOrThrow(for vin: String) throws {
        // One transaction: a crash mid-wipe previously left partially cleared history, which
        // matters most for the sign-out path where the user expects the data to be *gone*.
        let statements = [
            "DELETE FROM vehicle_snapshots WHERE vin = ?;",
            "DELETE FROM charging_baselines WHERE vin = ?;",
            "DELETE FROM command_receipts WHERE vin = ?;",
            "DELETE FROM provider_backoff WHERE vin = ?;",
            "DELETE FROM vehicle_activity WHERE vin = ?;",
            "DELETE FROM charging_sessions WHERE vin = ?;",
            "DELETE FROM battery_health_history WHERE vin = ?;",
            "DELETE FROM telemetry_logs WHERE vin = ?;",
            "DELETE FROM trip_tags WHERE vin = ?;",
            "DELETE FROM charging_samples WHERE vin = ?;",
            "DELETE FROM remote_commands_log WHERE vin = ?;",
            "DELETE FROM connectivity_history WHERE vin = ?;",
            "DELETE FROM cabin_climate_history WHERE vin = ?;",
            "DELETE FROM air_quality_history WHERE vin = ?;",
            "DELETE FROM tyre_pressure_history WHERE vin = ?;",
            "DELETE FROM vehicle_warning_events WHERE vin = ?;",
            "DELETE FROM fuel_entries WHERE vin = ?;",
            "DELETE FROM vehicle_images WHERE vin = ?;"
        ]
        try db.withTransaction {
            for sql in statements {
                try db.query(sql: sql) { stmt in
                    try stmt.bindText(vin, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        }
        try vacuumOrThrow()
    }

    /// The fleet-wide counterpart of `wipeVehicleOrThrow(for:)`. Spelled out as its own member
    /// because "every vehicle" must never be what a missing argument means.
    func wipeFleetOrThrow() throws {
        try db.withTransaction {
            try db.execute(sql: """
            DELETE FROM vehicle_snapshots;
            DELETE FROM charging_baselines;
            DELETE FROM command_receipts;
            DELETE FROM provider_backoff;
            DELETE FROM vehicle_activity;
            DELETE FROM charging_sessions;
            DELETE FROM charging_samples;
            DELETE FROM battery_health_history;
            DELETE FROM telemetry_logs;
            DELETE FROM trip_tags;
            DELETE FROM remote_commands_log;
            DELETE FROM air_quality_history;
            DELETE FROM tyre_pressure_history;
            DELETE FROM vehicle_warning_events;
            DELETE FROM connectivity_history;
            DELETE FROM cabin_climate_history;
            DELETE FROM fuel_entries;
            DELETE FROM vehicle_images;
            """)
        }
        try vacuumOrThrow()
    }
}
