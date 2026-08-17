import Foundation

/// Represents a historical charging session record stored in SQLite.
struct HistoricalChargingSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let vin: String
    let startedAt: Date
    let endedAt: Date?
    let startSoc: Double
    let endSoc: Double?
    let energyDeliveredKwh: Double
    let peakPowerKw: Double
    let averagePowerKw: Double
    let locationName: String?
    let createdAt: Date

    func toDomainSession(database: VehicleDatabase = .shared) -> ChargingSession {
        let dbSamples = database.chargingSamples(for: id)
        let domainSamples = dbSamples.map {
            ChargingSample(
                timestamp: $0.timestamp,
                batteryPercentage: $0.soc,
                powerWatts: $0.powerKw.map { Int($0 * 1000.0) }
            )
        }
        return ChargingSession(
            id: UUID(uuidString: id) ?? UUID(),
            vin: vin,
            startDate: startedAt,
            endDate: endedAt ?? Date(),
            startBatteryPercentage: startSoc,
            endBatteryPercentage: endSoc ?? startSoc,
            kwhDelivered: energyDeliveredKwh,
            peakPowerWatts: peakPowerKw > 0 ? Int(peakPowerKw * 1000.0) : nil,
            cost: nil,
            targetPercentage: nil,
            samples: domainSamples
        )
    }
}

/// Represents a time-series charging sample point.
struct HistoricalChargingSample: Codable, Equatable, Sendable {
    let id: Int64
    let sessionId: String
    let vin: String
    let timestamp: Date
    let soc: Double
    let powerKw: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
}

/// Represents a recorded battery state of health (SoH) milestone over time.
struct BatteryHealthRecord: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let vin: String
    let timestamp: Date
    let odometerKm: Double
    let stateOfHealthPct: Double
    let degradationPct: Double
    let effectiveUsableKwh: Double
}

/// Represents a drive & efficiency telemetry log entry.
struct TelemetryLogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let vin: String
    let timestamp: Date
    let odometerKm: Double?
    let tripManualKm: Double?
    let tripAutoKm: Double?
    let avgConsumption: Double?
    let ambientTempC: Double?
    let latitude: Double?
    let longitude: Double?
}

/// High-level vehicle database repository coordinating SQLite tables and schema migrations.
final class VehicleDatabase: @unchecked Sendable {
    static let shared = VehicleDatabase()

    let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(database: SQLiteDatabase? = nil) {
        if let database {
            self.db = database
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Hisingen", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let dbURL = appSupport.appendingPathComponent("hisingen.sqlite3")
            self.db = (try? SQLiteDatabase(path: dbURL.path)) ?? (try! SQLiteDatabase.inMemory())
        }
        createTables()
    }

    /// Convenience for in-memory database instance for testing.
    static func inMemory() -> VehicleDatabase {
        let memoryDB = try! SQLiteDatabase.inMemory()
        return VehicleDatabase(database: memoryDB)
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS vehicle_snapshots (
            vin TEXT PRIMARY KEY NOT NULL,
            brand TEXT NOT NULL,
            model_name TEXT,
            fetched_at REAL NOT NULL,
            vehicle_reported_at REAL,
            is_cached_snapshot INTEGER NOT NULL DEFAULT 1,
            payload BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS charging_sessions (
            id TEXT PRIMARY KEY NOT NULL,
            vin TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            start_soc REAL NOT NULL,
            end_soc REAL,
            energy_delivered_kwh REAL DEFAULT 0.0,
            peak_power_kw REAL DEFAULT 0.0,
            average_power_kw REAL DEFAULT 0.0,
            location_name TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_charging_sessions_vin ON charging_sessions(vin, started_at DESC);

        CREATE TABLE IF NOT EXISTS charging_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            soc REAL NOT NULL,
            power_kw REAL,
            voltage_volts REAL,
            current_amps REAL
        );
        CREATE INDEX IF NOT EXISTS idx_charging_samples_session ON charging_samples(session_id, timestamp ASC);

        CREATE TABLE IF NOT EXISTS battery_health_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            odometer_km REAL NOT NULL,
            state_of_health_pct REAL NOT NULL,
            degradation_pct REAL NOT NULL,
            effective_usable_kwh REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_battery_health_vin ON battery_health_history(vin, timestamp DESC);

        CREATE TABLE IF NOT EXISTS telemetry_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            odometer_km REAL,
            trip_manual_km REAL,
            trip_auto_km REAL,
            avg_consumption REAL,
            ambient_temp_c REAL,
            latitude REAL,
            longitude REAL
        );
        CREATE INDEX IF NOT EXISTS idx_telemetry_vin ON telemetry_logs(vin, timestamp DESC);

        CREATE TABLE IF NOT EXISTS remote_commands_log (
            id TEXT PRIMARY KEY NOT NULL,
            vin TEXT NOT NULL,
            command_name TEXT NOT NULL,
            status TEXT NOT NULL,
            executed_at REAL NOT NULL,
            duration_ms INTEGER,
            error_message TEXT
        );
        """
        try? db.execute(sql: sql)
    }

    // MARK: - Vehicle Snapshots

    func saveSnapshot(_ state: VehicleState) {
        guard let data = try? encoder.encode(state.cacheableCopy) else { return }
        let brandName = state.isVolvo ? "volvo" : "polestar"
        let sql = """
        INSERT INTO vehicle_snapshots (vin, brand, model_name, fetched_at, vehicle_reported_at, is_cached_snapshot, payload)
        VALUES (?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(vin) DO UPDATE SET
            brand=excluded.brand,
            model_name=excluded.model_name,
            fetched_at=excluded.fetched_at,
            vehicle_reported_at=excluded.vehicle_reported_at,
            is_cached_snapshot=1,
            payload=excluded.payload;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(state.vin, at: 1)
            try stmt.bindText(brandName, at: 2)
            try stmt.bindText(state.modelName, at: 3)
            try stmt.bindDate(state.fetchedAt, at: 4)
            try stmt.bindDate(state.vehicleReportedAt, at: 5)
            try stmt.bindBlob(data, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func loadSnapshot(for vin: String) -> VehicleState? {
        let sql = "SELECT payload, fetched_at FROM vehicle_snapshots WHERE vin = ? LIMIT 1;"
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> VehicleState? in
            guard stmt.step(), let blob = stmt.columnBlob(at: 0) else { return nil }
            guard var state = try? decoder.decode(VehicleState.self, from: blob) else { return nil }
            if let fetchedAt = stmt.columnDate(at: 1) {
                // Drop expired snapshots older than 7 days
                if Date().timeIntervalSince(fetchedAt) > 7 * 24 * 60 * 60 {
                    deleteSnapshot(for: vin)
                    return nil
                }
            }
            state.isCachedSnapshot = true
            return state
        }
    }

    func deleteSnapshot(for vin: String) {
        let sql = "DELETE FROM vehicle_snapshots WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    // MARK: - Charging Sessions & Samples

    @discardableResult
    func startChargingSession(id: String = UUID().uuidString, vin: String, startSoc: Double, location: String? = nil) -> String {
        let now = Date()
        let sql = """
        INSERT INTO charging_sessions (id, vin, started_at, start_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0.0, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(now, at: 3)
            try stmt.bindDouble(startSoc, at: 4)
            try stmt.bindText(location, at: 5)
            try stmt.bindDate(now, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
        return id
    }

    func recordChargingSample(sessionId: String, vin: String, soc: Double,
                              powerKw: Double?, voltage: Double?, current: Double?) {
        let sql = """
        INSERT INTO charging_samples (session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(sessionId, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(Date(), at: 3)
            try stmt.bindDouble(soc, at: 4)
            try stmt.bindDouble(powerKw, at: 5)
            try stmt.bindDouble(voltage, at: 6)
            try stmt.bindDouble(current, at: 7)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func completeChargingSession(id: String, endSoc: Double, energyDeliveredKwh: Double,
                                 peakPowerKw: Double, averagePowerKw: Double) {
        let sql = """
        UPDATE charging_sessions SET
            ended_at = ?,
            end_soc = ?,
            energy_delivered_kwh = ?,
            peak_power_kw = ?,
            average_power_kw = ?
        WHERE id = ?;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindDate(Date(), at: 1)
            try stmt.bindDouble(endSoc, at: 2)
            try stmt.bindDouble(energyDeliveredKwh, at: 3)
            try stmt.bindDouble(peakPowerKw, at: 4)
            try stmt.bindDouble(averagePowerKw, at: 5)
            try stmt.bindText(id, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func activeChargingSession(for vin: String) -> HistoricalChargingSession? {
        let sql = """
        SELECT id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at
        FROM charging_sessions WHERE vin = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> HistoricalChargingSession? in
            guard stmt.step(),
                  let id = stmt.columnText(at: 0),
                  let vin = stmt.columnText(at: 1),
                  let startedAt = stmt.columnDate(at: 2),
                  let startSoc = stmt.columnDouble(at: 4),
                  let createdAt = stmt.columnDate(at: 10) else { return nil }
            return HistoricalChargingSession(
                id: id, vin: vin, startedAt: startedAt, endedAt: nil,
                startSoc: startSoc, endSoc: stmt.columnDouble(at: 5),
                energyDeliveredKwh: stmt.columnDouble(at: 6) ?? 0.0,
                peakPowerKw: stmt.columnDouble(at: 7) ?? 0.0,
                averagePowerKw: stmt.columnDouble(at: 8) ?? 0.0,
                locationName: stmt.columnText(at: 9),
                createdAt: createdAt
            )
        }) ?? nil
    }

    func chargingSamples(for sessionId: String) -> [HistoricalChargingSample] {
        let sql = """
        SELECT id, session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps
        FROM charging_samples WHERE session_id = ? ORDER BY timestamp ASC;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(sessionId, at: 1)
        } process: { stmt -> [HistoricalChargingSample] in
            var list: [HistoricalChargingSample] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let sess = stmt.columnText(at: 1),
                      let vin = stmt.columnText(at: 2),
                      let ts = stmt.columnDate(at: 3),
                      let soc = stmt.columnDouble(at: 4) else { continue }
                list.append(HistoricalChargingSample(
                    id: id, sessionId: sess, vin: vin, timestamp: ts, soc: soc,
                    powerKw: stmt.columnDouble(at: 5),
                    voltageVolts: stmt.columnDouble(at: 6),
                    currentAmps: stmt.columnDouble(at: 7)
                ))
            }
            return list
        }) ?? []
    }

    func recentChargingSessions(for vin: String, limit: Int = 20) -> [HistoricalChargingSession] {
        let sql = """
        SELECT id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at
        FROM charging_sessions WHERE vin = ? ORDER BY started_at DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [HistoricalChargingSession] in
            var list: [HistoricalChargingSession] = []
            while stmt.step() {
                guard let id = stmt.columnText(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let startedAt = stmt.columnDate(at: 2),
                      let startSoc = stmt.columnDouble(at: 4),
                      let createdAt = stmt.columnDate(at: 10) else { continue }
                let endedAt = stmt.columnDate(at: 3)
                let endSoc = stmt.columnDouble(at: 5)
                let energy = stmt.columnDouble(at: 6) ?? 0.0
                let peak = stmt.columnDouble(at: 7) ?? 0.0
                let avg = stmt.columnDouble(at: 8) ?? 0.0
                let loc = stmt.columnText(at: 9)
                list.append(HistoricalChargingSession(
                    id: id, vin: vin, startedAt: startedAt, endedAt: endedAt,
                    startSoc: startSoc, endSoc: endSoc, energyDeliveredKwh: energy,
                    peakPowerKw: peak, averagePowerKw: avg, locationName: loc, createdAt: createdAt
                ))
            }
            return list
        }) ?? []
    }

    // MARK: - Battery Health History

    func recordBatteryHealthMilestone(vin: String, odometerKm: Double,
                                      sohPct: Double, degPct: Double, usableKwh: Double) {
        let sql = """
        INSERT INTO battery_health_history (vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindDouble(odometerKm, at: 3)
            try stmt.bindDouble(sohPct, at: 4)
            try stmt.bindDouble(degPct, at: 5)
            try stmt.bindDouble(usableKwh, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func batteryHealthHistory(for vin: String, limit: Int = 50) -> [BatteryHealthRecord] {
        let sql = """
        SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh
        FROM battery_health_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [BatteryHealthRecord] in
            var records: [BatteryHealthRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2),
                      let odo = stmt.columnDouble(at: 3),
                      let soh = stmt.columnDouble(at: 4),
                      let deg = stmt.columnDouble(at: 5),
                      let usable = stmt.columnDouble(at: 6) else { continue }
                records.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable
                ))
            }
            return records
        }) ?? []
    }

    // MARK: - Telemetry Logging

    func recordTelemetry(vin: String, odometerKm: Double?, tripManualKm: Double?,
                         tripAutoKm: Double?, avgConsumption: Double?, ambientTempC: Double?,
                         latitude: Double?, longitude: Double?) {
        let sql = """
        INSERT INTO telemetry_logs (vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindDouble(odometerKm, at: 3)
            try stmt.bindDouble(tripManualKm, at: 4)
            try stmt.bindDouble(tripAutoKm, at: 5)
            try stmt.bindDouble(avgConsumption, at: 6)
            try stmt.bindDouble(ambientTempC, at: 7)
            try stmt.bindDouble(latitude, at: 8)
            try stmt.bindDouble(longitude, at: 9)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    // MARK: - Remote Commands Audit

    func recordCommandAudit(id: String = UUID().uuidString, vin: String,
                            command: String, status: String, durationMs: Int? = nil, error: String? = nil) {
        let sql = """
        INSERT INTO remote_commands_log (id, vin, command_name, status, executed_at, duration_ms, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindText(command, at: 3)
            try stmt.bindText(status, at: 4)
            try stmt.bindDate(Date(), at: 5)
            try stmt.bindInt64(durationMs.map(Int64.init), at: 6)
            try stmt.bindText(error, at: 7)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    // MARK: - Database Diagnostics & Maintenance

    var databaseSizeBytes: Int64 {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hisingen", isDirectory: true)
        let main = appSupport.appendingPathComponent("hisingen.sqlite3")
        let wal = appSupport.appendingPathComponent("hisingen.sqlite3-wal")
        let shm = appSupport.appendingPathComponent("hisingen.sqlite3-shm")
        let files = [main, wal, shm]
        return files.reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    func recordCounts() -> (snapshots: Int, chargingSessions: Int, chargingSamples: Int, batteryHealth: Int, telemetry: Int, commands: Int) {
        func count(table: String) -> Int {
            let sql = "SELECT COUNT(*) FROM \(table);"
            let c = try? db.query(sql: sql) { _ in } process: { stmt -> Int in
                stmt.step() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
            }
            return c ?? 0
        }
        return (
            snapshots: count(table: "vehicle_snapshots"),
            chargingSessions: count(table: "charging_sessions"),
            chargingSamples: count(table: "charging_samples"),
            batteryHealth: count(table: "battery_health_history"),
            telemetry: count(table: "telemetry_logs"),
            commands: count(table: "remote_commands_log")
        )
    }

    func vacuum() {
        try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        try? db.execute(sql: "VACUUM;")
    }

    func pruneHistoricalSamples(olderThanDays: Int = 90) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays * 86400))
        try? db.query(sql: "DELETE FROM charging_samples WHERE timestamp < ?;") { stmt in
            try stmt.bindDate(cutoff, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
        try? db.query(sql: "DELETE FROM telemetry_logs WHERE timestamp < ?;") { stmt in
            try stmt.bindDate(cutoff, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
        vacuum()
    }

    // MARK: - CSV Exporters

    func exportChargingSessionsCSV(for vin: String? = nil) -> String {
        let sessions: [HistoricalChargingSession]
        if let vin {
            sessions = recentChargingSessions(for: vin, limit: 1000)
        } else {
            let sql = """
            SELECT id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at
            FROM charging_sessions ORDER BY started_at DESC LIMIT 1000;
            """
            sessions = (try? db.query(sql: sql) { _ in } process: { stmt -> [HistoricalChargingSession] in
                var list: [HistoricalChargingSession] = []
                while stmt.step() {
                    guard let id = stmt.columnText(at: 0),
                          let vin = stmt.columnText(at: 1),
                          let startedAt = stmt.columnDate(at: 2),
                          let startSoc = stmt.columnDouble(at: 4),
                          let createdAt = stmt.columnDate(at: 10) else { continue }
                    list.append(HistoricalChargingSession(
                        id: id, vin: vin, startedAt: startedAt,
                        endedAt: stmt.columnDate(at: 3),
                        startSoc: startSoc,
                        endSoc: stmt.columnDouble(at: 5),
                        energyDeliveredKwh: stmt.columnDouble(at: 6) ?? 0.0,
                        peakPowerKw: stmt.columnDouble(at: 7) ?? 0.0,
                        averagePowerKw: stmt.columnDouble(at: 8) ?? 0.0,
                        locationName: stmt.columnText(at: 9),
                        createdAt: createdAt
                    ))
                }
                return list
            }) ?? []
        }

        var csv = "Session ID,VIN,Started At,Ended At,Start SoC (%),End SoC (%),Energy Delivered (kWh),Peak Power (kW),Avg Power (kW),Location\n"
        let df = ISO8601DateFormatter()
        for s in sessions {
            let start = df.string(from: s.startedAt)
            let end = s.endedAt.map { df.string(from: $0) } ?? ""
            let endSoc = s.endSoc.map { String(format: "%.1f", $0) } ?? ""
            let loc = (s.locationName ?? "").replacingOccurrences(of: ",", with: " ")
            csv += "\(s.id),\(s.vin),\(start),\(end),\(String(format: "%.1f", s.startSoc)),\(endSoc),\(String(format: "%.2f", s.energyDeliveredKwh)),\(String(format: "%.1f", s.peakPowerKw)),\(String(format: "%.1f", s.averagePowerKw)),\(loc)\n"
        }
        return csv
    }

    func exportBatteryHealthCSV(for vin: String? = nil) -> String {
        let sql = vin != nil
            ? "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh FROM battery_health_history WHERE vin = ? ORDER BY timestamp DESC;"
            : "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh FROM battery_health_history ORDER BY timestamp DESC;"

        let records = (try? db.query(sql: sql) { stmt in
            if let vin { try stmt.bindText(vin, at: 1) }
        } process: { stmt -> [BatteryHealthRecord] in
            var list: [BatteryHealthRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2),
                      let odo = stmt.columnDouble(at: 3),
                      let soh = stmt.columnDouble(at: 4),
                      let deg = stmt.columnDouble(at: 5),
                      let usable = stmt.columnDouble(at: 6) else { continue }
                list.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable
                ))
            }
            return list
        }) ?? []

        var csv = "Record ID,VIN,Date,Odometer (km),State of Health (%),Degradation (%),Effective Usable (kWh)\n"
        let df = ISO8601DateFormatter()
        for r in records {
            let date = df.string(from: r.timestamp)
            csv += "\(r.id),\(r.vin),\(date),\(String(format: "%.1f", r.odometerKm)),\(String(format: "%.2f", r.stateOfHealthPct)),\(String(format: "%.2f", r.degradationPct)),\(String(format: "%.2f", r.effectiveUsableKwh))\n"
        }
        return csv
    }

    // MARK: - Wipe / Purge

    func wipeAll(for vin: String? = nil) {
        if let vin {
            try? db.query(sql: "DELETE FROM vehicle_snapshots WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try? db.query(sql: "DELETE FROM charging_sessions WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try? db.query(sql: "DELETE FROM battery_health_history WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try? db.query(sql: "DELETE FROM telemetry_logs WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        } else {
            try? db.execute(sql: "DELETE FROM vehicle_snapshots;")
            try? db.execute(sql: "DELETE FROM charging_sessions;")
            try? db.execute(sql: "DELETE FROM charging_samples;")
            try? db.execute(sql: "DELETE FROM battery_health_history;")
            try? db.execute(sql: "DELETE FROM telemetry_logs;")
            try? db.execute(sql: "DELETE FROM remote_commands_log;")
            try? db.execute(sql: "VACUUM;")
        }
    }
}
