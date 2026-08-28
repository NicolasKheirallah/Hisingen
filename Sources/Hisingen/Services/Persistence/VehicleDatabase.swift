import Foundation
import OSLog

/// High-level vehicle database repository coordinating SQLite tables and schema migrations.
final class VehicleDatabase: @unchecked Sendable {
    static let shared = VehicleDatabase()

    let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// ISO-8601 rendering shared by every backup/exporter path (previously one
    /// `ISO8601DateFormatter` per exporter function).
    private let isoFormatter = ISO8601DateFormatter()

    var storageAvailable: Bool { db.isOpen }

    init(database: SQLiteDatabase? = nil) {
        if let database {
            self.db = database
        } else {
            let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let appSupport = baseDirectory
                .appendingPathComponent("Hisingen", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            } catch {
                logger.error("Could not create database directory: \(error, privacy: .public)")
            }
            let dbURL = appSupport.appendingPathComponent("hisingen.sqlite3")
            do {
                self.db = try SQLiteDatabase(path: dbURL.path)
            } catch {
                // .fault: the app keeps running against an unavailable database, so every
                // history/telemetry write silently degrades — this must stand out in Console.
                logger.fault("Could not open database at \(dbURL.path, privacy: .private): \(error, privacy: .public)")
                self.db = .unavailable(path: dbURL.path)
            }
        }
        createTables()
    }

    /// Convenience for in-memory database instance for testing.
    static func inMemory() -> VehicleDatabase {
        do {
            return VehicleDatabase(database: try SQLiteDatabase.inMemory())
        } catch {
            assertionFailure("In-memory database initialization failed: \(error)")
            return VehicleDatabase(database: .unavailable(path: ":memory:"))
        }
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
            current_amps REAL,
            charging_type TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_charging_samples_session ON charging_samples(session_id, timestamp ASC);

        CREATE TABLE IF NOT EXISTS battery_health_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            odometer_km REAL NOT NULL,
            state_of_health_pct REAL NOT NULL,
            degradation_pct REAL NOT NULL,
            effective_usable_kwh REAL NOT NULL,
            measurement_source TEXT NOT NULL DEFAULT 'legacy'
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
            avg_consumption_unit TEXT,
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
        CREATE INDEX IF NOT EXISTS idx_remote_commands_vin ON remote_commands_log(vin, executed_at DESC);

        CREATE TABLE IF NOT EXISTS connectivity_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            network_type TEXT,
            signal_bars INTEGER,
            wake_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_connectivity_vin ON connectivity_history(vin, timestamp DESC);

        CREATE TABLE IF NOT EXISTS cabin_climate_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            interior_c REAL,
            requested_c REAL
        );
        CREATE INDEX IF NOT EXISTS idx_cabin_climate_vin ON cabin_climate_history(vin, timestamp DESC);

        CREATE TABLE IF NOT EXISTS fuel_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            date REAL NOT NULL,
            liters REAL NOT NULL,
            price_per_liter REAL NOT NULL,
            odometer_km REAL
        );
        CREATE INDEX IF NOT EXISTS idx_fuel_vin ON fuel_entries(vin, date DESC);

        CREATE TABLE IF NOT EXISTS air_quality_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            air_quality_index REAL,
            particulate_matter_25 REAL,
            particulate_matter_10 REAL,
            filter_remaining_percent REAL
        );
        CREATE INDEX IF NOT EXISTS idx_air_quality_vin ON air_quality_history(vin, timestamp DESC);

        CREATE TABLE IF NOT EXISTS vehicle_images (
            vin TEXT NOT NULL,
            angle INTEGER NOT NULL,
            image_data BLOB NOT NULL,
            thumbnail_data BLOB,
            pixel_budget INTEGER,
            updated_at REAL NOT NULL,
            PRIMARY KEY (vin, angle)
        );
        CREATE INDEX IF NOT EXISTS idx_vehicle_images_vin ON vehicle_images(vin);
        """
        do {
            try db.execute(sql: sql)
            runMigrations()
            try? db.execute(sql: "PRAGMA user_version = 1;")
        } catch {
            // .fault: without a schema every persistence path degrades silently.
            logger.fault("Could not initialize database schema: \(error, privacy: .public)")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        let columns = (try? db.query(sql: sql) { _ in } process: { stmt -> Set<String> in
            var names = Set<String>()
            while stmt.step() {
                if let name = stmt.columnText(at: 1) { names.insert(name.lowercased()) }
            }
            return names
        }) ?? []
        return columns.contains(column.lowercased())
    }

    /// Ordered, version-gated schema migrations tracked by `PRAGMA user_version`.
    ///
    /// The baseline DDL above stays idempotent and runs on every launch; anything that
    /// rewrites data or must run exactly once belongs here instead of being re-executed with
    /// `try?` every start-up (which made a failed migration indistinguishable from success).
    /// Version 1 reproduces the pre-`user_version` ad-hoc ALTERs for existing installs.
    private func runMigrations() {
        let currentVersion = (try? db.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            stmt.step() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }) ?? 0

        // v1: quarantine legacy battery-health rows + add the disambiguation columns the
        // baseline now creates for new installs. Idempotent per table.
        if currentVersion < 1 {
            if !columnExists(table: "battery_health_history", column: "measurement_source") {
                try? db.execute(sql: "ALTER TABLE battery_health_history ADD COLUMN measurement_source TEXT NOT NULL DEFAULT 'legacy';")
            }
            if !columnExists(table: "telemetry_logs", column: "avg_consumption_unit") {
                try? db.execute(sql: "ALTER TABLE telemetry_logs ADD COLUMN avg_consumption_unit TEXT;")
            }
            if !columnExists(table: "charging_samples", column: "charging_type") {
                try? db.execute(sql: "ALTER TABLE charging_samples ADD COLUMN charging_type TEXT;")
            }
            // Existing installations contain rows produced by the old inferred/Volvo-capacity
            // implementation. Keep them quarantined rather than presenting them as measurements.
            try? db.execute(sql: "UPDATE battery_health_history SET measurement_source = 'legacy-estimate' WHERE measurement_source = 'measured';")
            try? db.execute(sql: "PRAGMA user_version = 1;")
        }
    }

    // MARK: - Vehicle Artwork & Images

    func saveVehicleImage(vin: String, angle: Int, data: Data, thumbnailData: Data? = nil, pixelBudget: Int? = nil) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty, !data.isEmpty else { return }
        let sql = """
        INSERT INTO vehicle_images (vin, angle, image_data, thumbnail_data, pixel_budget, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(vin, angle) DO UPDATE SET
            image_data=excluded.image_data,
            thumbnail_data=excluded.thumbnail_data,
            pixel_budget=excluded.pixel_budget,
            updated_at=excluded.updated_at;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(cleanVIN, at: 1)
            try stmt.bindInt64(Int64(angle), at: 2)
            try stmt.bindBlob(data, at: 3)
            try stmt.bindBlob(thumbnailData, at: 4)
            try stmt.bindInt64(pixelBudget.map(Int64.init), at: 5)
            try stmt.bindDate(Date(), at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func loadVehicleImage(for vin: String, angle: Int) -> (data: Data, thumbnailData: Data?)? {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return nil }
        let sql = "SELECT image_data, thumbnail_data FROM vehicle_images WHERE vin = ? AND angle = ? LIMIT 1;"
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(cleanVIN, at: 1)
            try stmt.bindInt64(Int64(angle), at: 2)
        } process: { stmt -> (data: Data, thumbnailData: Data?)? in
            guard stmt.step(), let data = stmt.columnBlob(at: 0) else { return nil }
            let thumb = stmt.columnBlob(at: 1)
            return (data: data, thumbnailData: thumb)
        }
    }

    func cachedImageAngles(for vin: String) -> [Int] {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return [] }
        let sql = "SELECT angle FROM vehicle_images WHERE vin = ?;"
        let result = try? db.query(sql: sql) { stmt in
            try stmt.bindText(cleanVIN, at: 1)
        } process: { stmt -> [Int] in
            var angles: [Int] = []
            while stmt.step() {
                if let angle = stmt.columnInt64(at: 0).map(Int.init) {
                    angles.append(angle)
                }
            }
            return angles
        }
        return result ?? []
    }

    // MARK: - Vehicle Snapshots

    func saveSnapshot(_ state: VehicleState) {
        let data: Data
        do {
            data = try encoder.encode(state.cacheableCopy)
        } catch {
            logger.error("Could not encode vehicle snapshot for persistence: \(error, privacy: .public)")
            return
        }
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
        // `query` runs `process` while holding the database's recursive lock; nothing in the
        // closure may call back into the repository. Record that the row expired and delete
        // it after the query returns, once the lock is released.
        var snapshotExpired = false
        let state = try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> VehicleState? in
            guard stmt.step(), let blob = stmt.columnBlob(at: 0) else { return nil }
            guard var state = try? decoder.decode(VehicleState.self, from: blob) else { return nil }
            if let fetchedAt = stmt.columnDate(at: 1) {
                // Drop expired snapshots older than 7 days
                if Date().timeIntervalSince(fetchedAt) > 7 * 24 * 60 * 60 {
                    snapshotExpired = true
                    return nil
                }
            }
            state.isCachedSnapshot = true
            return state
        }
        if snapshotExpired {
            deleteSnapshot(for: vin)
            return nil
        }
        return state
    }

    func deleteSnapshot(for vin: String) {
        let sql = "DELETE FROM vehicle_snapshots WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    // MARK: - Charging Sessions & Samples

    /// Shared column mapping for the `charging_sessions` SELECT shape used by every session
    /// query (previously duplicated in four readers with drift risk).
    private func sessionRow(from stmt: SQLiteStatement,
                            endedAt: Date?, endSoc: Double?, energy: Double?,
                            peak: Double?, average: Double?, location: String?) -> HistoricalChargingSession? {
        guard let id = stmt.columnText(at: 0),
              let vin = stmt.columnText(at: 1),
              let startedAt = stmt.columnDate(at: 2),
              let startSoc = stmt.columnDouble(at: 4),
              let createdAt = stmt.columnDate(at: 10) else { return nil }
        return HistoricalChargingSession(
            id: id, vin: vin, startedAt: startedAt, endedAt: endedAt,
            startSoc: startSoc, endSoc: endSoc ?? stmt.columnDouble(at: 5),
            energyDeliveredKwh: energy ?? (stmt.columnDouble(at: 6) ?? 0.0),
            peakPowerKw: peak ?? (stmt.columnDouble(at: 7) ?? 0.0),
            averagePowerKw: average ?? (stmt.columnDouble(at: 8) ?? 0.0),
            locationName: location ?? stmt.columnText(at: 9),
            createdAt: createdAt
        )
    }

    @discardableResult
    func startChargingSession(id: String = UUID().uuidString, vin: String, startSoc: Double,
                              location: String? = nil, startedAt: Date = Date()) -> String {
        let sql = """
        INSERT INTO charging_sessions (id, vin, started_at, start_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0.0, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(startedAt, at: 3)
            try stmt.bindDouble(startSoc, at: 4)
            try stmt.bindText(location, at: 5)
            try stmt.bindDate(startedAt, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
        return id
    }

    func recordChargingSample(sessionId: String, vin: String, soc: Double,
                              powerKw: Double?, voltage: Double?, current: Double?,
                              chargingType: String? = nil, timestamp: Date = Date()) {
        let sql = """
        INSERT INTO charging_samples (session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(sessionId, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(timestamp, at: 3)
            try stmt.bindDouble(soc, at: 4)
            try stmt.bindDouble(powerKw, at: 5)
            try stmt.bindDouble(voltage, at: 6)
            try stmt.bindDouble(current, at: 7)
            try stmt.bindText(chargingType, at: 8)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func completeChargingSession(id: String, endSoc: Double, energyDeliveredKwh: Double,
                                 peakPowerKw: Double, averagePowerKw: Double,
                                 endedAt: Date = Date()) {
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
            try stmt.bindDate(endedAt, at: 1)
            try stmt.bindDouble(endSoc, at: 2)
            try stmt.bindDouble(energyDeliveredKwh, at: 3)
            try stmt.bindDouble(peakPowerKw, at: 4)
            try stmt.bindDouble(averagePowerKw, at: 5)
            try stmt.bindText(id, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    /// Removes an unfinished observation that never produced a measurable SoC gain. Keeping
    /// these rows made an interrupted poll look like a completed 0 kWh / 0 cost charge.
    func discardChargingSession(id: String) {
        try? db.withTransaction {
            try db.query(sql: "DELETE FROM charging_samples WHERE session_id = ?;") { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try db.query(sql: "DELETE FROM charging_sessions WHERE id = ? AND ended_at IS NULL;") { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    func activeChargingSession(for vin: String) -> HistoricalChargingSession? {
        let sql = """
        SELECT id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at
        FROM charging_sessions WHERE vin = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { [weak self] stmt -> HistoricalChargingSession? in
            guard stmt.step() else { return nil }
            return self?.sessionRow(from: stmt, endedAt: nil, endSoc: nil, energy: nil,
                                    peak: nil, average: nil, location: nil)
        }) ?? nil
    }

    func chargingSamples(for sessionId: String) -> [HistoricalChargingSample] {
        let sql = """
        SELECT id, session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type
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
                    currentAmps: stmt.columnDouble(at: 7),
                    chargingType: stmt.columnText(at: 8)
                ))
            }
            return list
        }) ?? []
    }

    func recentChargingSessions(for vin: String, limit: Int = 20) -> [HistoricalChargingSession] {
        let sql = """
        SELECT id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name, created_at
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NOT NULL
          AND (
            end_soc > start_soc OR energy_delivered_kwh > 0 OR EXISTS (
              SELECT 1 FROM charging_samples
              WHERE charging_samples.session_id = charging_sessions.id
                AND charging_samples.soc > charging_sessions.start_soc
            )
          )
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { [weak self] stmt -> [HistoricalChargingSession] in
            var list: [HistoricalChargingSession] = []
            while stmt.step() {
                guard let session = self?.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                     endSoc: stmt.columnDouble(at: 5),
                                                     energy: stmt.columnDouble(at: 6),
                                                     peak: stmt.columnDouble(at: 7),
                                                     average: stmt.columnDouble(at: 8),
                                                     location: stmt.columnText(at: 9)) else { continue }
                list.append(session)
            }
            return list
        }) ?? []
    }

    /// Repairs completed rows written by older builds with a stale/zero final summary. The
    /// operation is idempotent and only touches rows whose retained samples prove a real gain.
    func repairLegacyChargingSessions(for vin: String, usableCapacityKwh: Double) {
        guard usableCapacityKwh > 0 else { return }
        let candidates = recentChargingSessions(for: vin, limit: 1_000).filter {
            $0.energyDeliveredKwh <= 0 || ($0.endSoc ?? $0.startSoc) <= $0.startSoc
        }
        for candidate in candidates {
            let repaired = candidate.reconciled(
                database: self, usableCapacityKwh: usableCapacityKwh
            )
            guard repaired.energyDeliveredKwh > 0,
                  let endSoc = repaired.endSoc, endSoc > repaired.startSoc else { continue }
            try? db.query(sql: """
                UPDATE charging_sessions SET
                    end_soc = ?, energy_delivered_kwh = ?,
                    peak_power_kw = ?, average_power_kw = ?
                WHERE id = ? AND ended_at IS NOT NULL;
                """) { stmt in
                try stmt.bindDouble(endSoc, at: 1)
                try stmt.bindDouble(repaired.energyDeliveredKwh, at: 2)
                try stmt.bindDouble(repaired.peakPowerKw, at: 3)
                try stmt.bindDouble(repaired.averagePowerKw, at: 4)
                try stmt.bindText(repaired.id, at: 5)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    // MARK: - Battery Health History

    /// What makes a battery-health row a *milestone* rather than a duplicate.
    ///
    /// `VehicleStateStore.save(_:)` runs on every refresh — minutes apart — but state of
    /// health moves over months. Recording unconditionally produced ~15 rows/hour that
    /// shared 3 distinct SoH values, and nothing prunes this table, so it grew without
    /// bound. A row is now written only when it carries new information.
    enum BatteryHealthMilestone {
        /// Heartbeat, so a stationary vehicle still leaves a periodic trend point.
        static let minimumInterval: TimeInterval = 7 * 24 * 60 * 60
        /// Real SoH movement. Below this is measurement noise, not degradation.
        static let sohDeltaPct: Double = 0.5
        /// Degradation tracks mileage, so meaningful distance also earns a row.
        static let odometerDeltaKm: Double = 500
    }

    /// Whether these readings differ enough from the last stored row to be worth keeping.
    /// `nil` previous row means this VIN has no history yet, which always qualifies.
    func isBatteryHealthMilestone(sohPct: Double, odometerKm: Double,
                                  since previous: BatteryHealthRecord?,
                                  now: Date = Date()) -> Bool {
        guard let previous else { return true }
        if now.timeIntervalSince(previous.timestamp) >= BatteryHealthMilestone.minimumInterval { return true }
        if abs(sohPct - previous.stateOfHealthPct) >= BatteryHealthMilestone.sohDeltaPct { return true }
        if odometerKm - previous.odometerKm >= BatteryHealthMilestone.odometerDeltaKm { return true }
        return false
    }

    /// Records a battery-health milestone, skipping rows that duplicate the last one.
    /// Returns whether a row was actually written.
    @discardableResult
    func recordBatteryHealthMilestone(vin: String, odometerKm: Double,
                                      sohPct: Double, degPct: Double, usableKwh: Double,
                                      measurementSource: String = "calculated-v2") -> Bool {
        let previous = batteryHealthHistory(for: vin, limit: 1).first
        guard isBatteryHealthMilestone(sohPct: sohPct, odometerKm: odometerKm, since: previous) else {
            return false
        }
        let sql = """
        INSERT INTO battery_health_history (vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindDouble(odometerKm, at: 3)
            try stmt.bindDouble(sohPct, at: 4)
            try stmt.bindDouble(degPct, at: 5)
            try stmt.bindDouble(usableKwh, at: 6)
            try stmt.bindText(measurementSource, at: 7)
            try stmt.executeUpdate()
        } process: { _ in }
        return true
    }

    func batteryHealthHistory(for vin: String, limit: Int = 50) -> [BatteryHealthRecord] {
        let sql = """
        SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source
        FROM battery_health_history WHERE vin = ? AND measurement_source IN ('calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC LIMIT ?;
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
                      let usable = stmt.columnDouble(at: 6),
                      let source = stmt.columnText(at: 7) else { continue }
                records.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable,
                    measurementSource: source
                ))
            }
            return records
        }) ?? []
    }

    // MARK: - Cabin Air Quality History

    /// Minimum spacing between recorded samples, mirroring the battery-health-milestone
    /// approach: a sample is only worth keeping if enough time has passed or the reading moved
    /// meaningfully, not on every refresh cycle.
    private static let airQualityHeartbeat: TimeInterval = 60 * 60
    private static let airQualityIndexDelta: Double = 5.0
    private static let airQualityPM25Delta: Double = 5.0

    private func lastAirQualitySample(for vin: String) -> (timestamp: Date, aqi: Double?, pm25: Double?)? {
        let sql = """
        SELECT timestamp, air_quality_index, particulate_matter_25
        FROM air_quality_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> (Date, Double?, Double?)? in
            guard stmt.step(), let ts = stmt.columnDate(at: 0) else { return nil }
            return (ts, stmt.columnDouble(at: 1), stmt.columnDouble(at: 2))
        } ?? nil
    }

    /// Records a cabin air-quality sample, skipping ones that would just duplicate the last
    /// recorded reading. Returns whether a row was actually written.
    @discardableResult
    func recordAirQuality(vin: String, airQualityIndex: Double?, particulateMatter25: Double?,
                          particulateMatter10: Double?, filterRemainingPercent: Double?) -> Bool {
        guard airQualityIndex != nil || particulateMatter25 != nil else { return false }
        if let last = lastAirQualitySample(for: vin),
           Date().timeIntervalSince(last.timestamp) < Self.airQualityHeartbeat,
           abs((airQualityIndex ?? 0) - (last.aqi ?? 0)) < Self.airQualityIndexDelta,
           abs((particulateMatter25 ?? 0) - (last.pm25 ?? 0)) < Self.airQualityPM25Delta {
            return false
        }
        let sql = """
        INSERT INTO air_quality_history (vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10, filter_remaining_percent)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindDouble(airQualityIndex, at: 3)
            try stmt.bindDouble(particulateMatter25, at: 4)
            try stmt.bindDouble(particulateMatter10, at: 5)
            try stmt.bindDouble(filterRemainingPercent, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
        return true
    }

    func recentAirQuality(for vin: String, limit: Int = 200) -> [AirQualityRecord] {
        let sql = """
        SELECT id, vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10, filter_remaining_percent
        FROM air_quality_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [AirQualityRecord] in
            var records: [AirQualityRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                records.append(AirQualityRecord(
                    id: id, vin: vin, timestamp: ts,
                    airQualityIndex: stmt.columnDouble(at: 3),
                    particulateMatter25: stmt.columnDouble(at: 4),
                    particulateMatter10: stmt.columnDouble(at: 5),
                    filterRemainingPercent: stmt.columnDouble(at: 6)
                ))
            }
            return records
        }) ?? []
    }

    func exportAirQualityCSV(for vin: String) -> String {
        let records = recentAirQuality(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Record ID,VIN,Date,Air Quality Index,PM2.5,PM10,Filter Remaining (%)\n"
        for r in records {
            func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
            csv += "\(r.id),\(r.vin),\(formatter.string(from: r.timestamp)),\(number(r.airQualityIndex)),\(number(r.particulateMatter25)),\(number(r.particulateMatter10)),\(number(r.filterRemainingPercent))\n"
        }
        return csv
    }

    // MARK: - Telemetry Logging

    /// Heartbeat for a vehicle that hasn't moved. Drive telemetry is only interesting when
    /// the odometer or a trip meter changes; a parked car re-reported the same figures every
    /// refresh, which is what filled this table.
    static let telemetryHeartbeat: TimeInterval = 24 * 60 * 60

    /// The odometer/trip readings of the most recent row, used to detect movement.
    private func lastTelemetryReadings(
        for vin: String
    ) -> (timestamp: Date, odometerKm: Double?, tripManualKm: Double?, tripAutoKm: Double?)? {
        let sql = """
        SELECT timestamp, odometer_km, trip_manual_km, trip_auto_km
        FROM telemetry_logs WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> (Date, Double?, Double?, Double?)? in
            guard stmt.step(), let ts = stmt.columnDate(at: 0) else { return nil }
            return (ts, stmt.columnDouble(at: 1), stmt.columnDouble(at: 2), stmt.columnDouble(at: 3))
        } ?? nil
    }

    /// Records drive telemetry, skipping refreshes where the vehicle hasn't moved.
    /// One duplicate immediately after movement is retained as a parked boundary so
    /// short journeys can be split without storing every stationary poll.
    /// Returns whether a row was actually written.
    @discardableResult
    func recordTelemetry(vin: String, odometerKm: Double?, tripManualKm: Double?,
                         tripAutoKm: Double?, avgConsumption: Double?,
                         consumptionUnit: String? = nil, ambientTempC: Double?,
                         latitude: Double?, longitude: Double?) -> Bool {
        if let last = lastTelemetryReadings(for: vin),
           Date().timeIntervalSince(last.timestamp) < Self.telemetryHeartbeat,
           last.odometerKm == odometerKm,
           last.tripManualKm == tripManualKm,
           last.tripAutoKm == tripAutoKm {
            let previous = recentTelemetry(for: vin, limit: 2).dropFirst().first
            let lastRowFollowedMovement = previous.map {
                $0.odometerKm != last.odometerKm
                    || $0.tripManualKm != last.tripManualKm
                    || $0.tripAutomaticKm != last.tripAutoKm
            } ?? false
            if !lastRowFollowedMovement { return false }
        }
        let sql = """
        INSERT INTO telemetry_logs (vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            try stmt.bindText(consumptionUnit, at: 10)
            try stmt.executeUpdate()
        } process: { _ in }
        return true
    }

    func recentTelemetry(for vin: String, limit: Int = 50, since: Date? = nil) -> [HistoricalTelemetryRecord] {
        let sql = since != nil
            ? """
            SELECT id, vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit
            FROM telemetry_logs WHERE vin = ? AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?;
            """
            : """
            SELECT id, vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit
            FROM telemetry_logs WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
            """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            if let since { try stmt.bindDate(since, at: 2) }
            try stmt.bindInt64(Int64(max(1, limit)), at: since != nil ? 3 : 2)
        } process: { stmt -> [HistoricalTelemetryRecord] in
            var records: [HistoricalTelemetryRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let rowVIN = stmt.columnText(at: 1),
                      let timestamp = stmt.columnDate(at: 2) else { continue }
                records.append(HistoricalTelemetryRecord(
                    id: id, vin: rowVIN, timestamp: timestamp,
                    odometerKm: stmt.columnDouble(at: 3),
                    tripManualKm: stmt.columnDouble(at: 4),
                    tripAutomaticKm: stmt.columnDouble(at: 5),
                    averageConsumption: stmt.columnDouble(at: 6),
                    averageConsumptionUnit: stmt.columnText(at: 10),
                    ambientTemperatureCelsius: stmt.columnDouble(at: 7),
                    latitude: stmt.columnDouble(at: 8),
                    longitude: stmt.columnDouble(at: 9)
                ))
            }
            return records
        }) ?? []
    }

    /// Derives trips from telemetry rows. `since` pushes the lower time bound into SQL so a
    /// Shortcuts query for "last 7 days" no longer decodes the entire table first.
    func derivedTrips(for vin: String, limit: Int = 100, since: Date? = nil) -> [TripHistoryEntry] {
        let records = Array(recentTelemetry(for: vin, limit: max(2_000, limit * 20), since: since).reversed())
        var trips: [TripHistoryEntry] = []
        var segmentStart: HistoricalTelemetryRecord?
        var segmentEnd: HistoricalTelemetryRecord?
        var segmentDistance = 0.0
        var consumptionTotal = 0.0
        var consumptionCount = 0
        var temperatureTotal = 0.0
        var temperatureCount = 0

        func appendSegment() {
            guard let start = segmentStart, let end = segmentEnd, segmentDistance >= 0.05 else { return }
            trips.append(TripHistoryEntry(
                id: "\(start.id)-\(end.id)", vin: vin,
                startedAt: start.timestamp, endedAt: end.timestamp,
                distanceKm: segmentDistance,
                averageConsumption: consumptionCount > 0 ? consumptionTotal / Double(consumptionCount) : nil,
                ambientTemperatureCelsius: temperatureCount > 0 ? temperatureTotal / Double(temperatureCount) : nil,
                startLatitude: start.latitude, startLongitude: start.longitude,
                endLatitude: end.latitude, endLongitude: end.longitude
            ))
        }

        func clearSegment() {
            segmentStart = nil
            segmentEnd = nil
            segmentDistance = 0
            consumptionTotal = 0
            consumptionCount = 0
            temperatureTotal = 0
            temperatureCount = 0
        }

        for pair in zip(records, records.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let odometerDelta: Double? = {
                guard let current = start.odometerKm, let next = end.odometerKm else { return nil }
                return next - current
            }()
            let automaticDelta: Double? = {
                guard let current = start.tripAutomaticKm, let next = end.tripAutomaticKm else { return nil }
                return next >= current ? next - current : next
            }()
            let manualDelta: Double? = {
                guard let current = start.tripManualKm, let next = end.tripManualKm else { return nil }
                return next >= current ? next - current : next
            }()
            let distance = [odometerDelta, automaticDelta, manualDelta]
                .compactMap { $0 }.first(where: { $0 >= 0.05 && $0 < 2_000 })
            let gap = end.timestamp.timeIntervalSince(start.timestamp)
            guard let distance, gap > 0, gap <= 45 * 60 else {
                appendSegment()
                clearSegment()
                continue
            }
            if segmentStart == nil { segmentStart = start }
            segmentEnd = end
            segmentDistance += distance
            if let value = end.averageConsumption ?? start.averageConsumption {
                consumptionTotal += value
                consumptionCount += 1
            }
            if let value = end.ambientTemperatureCelsius ?? start.ambientTemperatureCelsius {
                temperatureTotal += value
                temperatureCount += 1
            }
        }
        appendSegment()
        return Array(trips.suffix(limit).reversed())
    }

    func exportTripsCSV(for vin: String, limit: Int = 5_000) -> String {
        let trips = derivedTrips(for: vin, limit: limit)
        let formatter = ISO8601DateFormatter()
        var csv = "Trip ID,VIN,Started At,Ended At,Duration (min),Distance (km),Average Consumption,Ambient Temperature (C),Start Latitude,Start Longitude,End Latitude,End Longitude\n"
        for trip in trips {
            let values = [
                trip.id, trip.vin, formatter.string(from: trip.startedAt), formatter.string(from: trip.endedAt),
                String(format: "%.1f", trip.duration / 60), String(format: "%.2f", trip.distanceKm),
                trip.averageConsumption.map { String(format: "%.2f", $0) } ?? "",
                trip.ambientTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "",
                trip.startLatitude.map { String($0) } ?? "", trip.startLongitude.map { String($0) } ?? "",
                trip.endLatitude.map { String($0) } ?? "", trip.endLongitude.map { String($0) } ?? ""
            ]
            csv += values.joined(separator: ",") + "\n"
        }
        return csv
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

    func recentCommandAudits(for vin: String?, limit: Int = 20) -> [RemoteCommandAuditRecord] {
        let filterClause = vin != nil ? "WHERE vin = ? " : ""
        let sql = """
        SELECT id, vin, command_name, status, executed_at, duration_ms, error_message
        FROM remote_commands_log \(filterClause)ORDER BY executed_at DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            var bindIndex: Int32 = 1
            if let vin { try stmt.bindText(vin, at: bindIndex); bindIndex += 1 }
            try stmt.bindInt64(Int64(max(1, limit)), at: bindIndex)
        } process: { stmt -> [RemoteCommandAuditRecord] in
            var records: [RemoteCommandAuditRecord] = []
            while stmt.step() {
                guard let id = stmt.columnText(at: 0),
                      let rowVIN = stmt.columnText(at: 1),
                      let command = stmt.columnText(at: 2),
                      let status = stmt.columnText(at: 3),
                      let executedAt = stmt.columnDate(at: 4) else { continue }
                records.append(RemoteCommandAuditRecord(
                    id: id, vin: rowVIN, command: command, status: status,
                    executedAt: executedAt,
                    durationMs: stmt.columnInt64(at: 5).map(Int.init),
                    errorMessage: stmt.columnText(at: 6)
                ))
            }
            return records
        }) ?? []
    }

    // MARK: - Database Diagnostics & Maintenance

    var databaseSizeBytes: Int64 {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appSupport = baseDirectory
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
            batteryHealth: count(table: "battery_health_history WHERE measurement_source IN ('calculated-v2', 'legacy-estimate')"),
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
        try? db.withTransaction {
            try db.query(sql: "DELETE FROM charging_samples WHERE timestamp < ?;") { stmt in
                try stmt.bindDate(cutoff, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try db.query(sql: "DELETE FROM telemetry_logs WHERE timestamp < ?;") { stmt in
                try stmt.bindDate(cutoff, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        vacuum()
    }

    /// Bounds growth of the tables that previously had no retention path at all (manual or
    /// automatic) — `charging_sessions`, `battery_health_history`, `remote_commands_log`,
    /// and the per-hour `connectivity_history`/`cabin_climate_history` heartbeats. Defaults
    /// are deliberately longer than `pruneHistoricalSamples`'s 90 days: the session/health/
    /// audit rows are low-volume summaries (one per charge, one per command, health is
    /// change-gated), so there's little storage pressure to justify discarding a user's
    /// longer-term charging or health history as aggressively as the high-volume samples.
    func pruneAgedHistory(
        chargingSessionsOlderThanDays: Int = 730,
        batteryHealthOlderThanDays: Int = 730,
        commandAuditsOlderThanDays: Int = 180,
        airQualityOlderThanDays: Int = 365,
        connectivityOlderThanDays: Int = 180,
        cabinClimateOlderThanDays: Int = 180
    ) {
        let cutoffs: [(sql: String, column: String, days: Int)] = [
            ("DELETE FROM charging_sessions WHERE started_at < ?;", "started_at", chargingSessionsOlderThanDays),
            ("DELETE FROM battery_health_history WHERE timestamp < ?;", "timestamp", batteryHealthOlderThanDays),
            ("DELETE FROM remote_commands_log WHERE executed_at < ?;", "executed_at", commandAuditsOlderThanDays),
            ("DELETE FROM air_quality_history WHERE timestamp < ?;", "timestamp", airQualityOlderThanDays),
            ("DELETE FROM connectivity_history WHERE timestamp < ?;", "timestamp", connectivityOlderThanDays),
            ("DELETE FROM cabin_climate_history WHERE timestamp < ?;", "timestamp", cabinClimateOlderThanDays)
        ]
        try? db.withTransaction {
            for (sql, _, days) in cutoffs {
                let cutoff = Date().addingTimeInterval(-Double(days * 86400))
                try db.query(sql: sql) { stmt in
                    try stmt.bindDate(cutoff, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        }
        vacuum()
    }

    func clearStoredLocations(for vin: String? = nil) {
        if let vin {
            try? db.query(sql: "UPDATE telemetry_logs SET latitude = NULL, longitude = NULL WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try? db.query(sql: "UPDATE charging_sessions SET location_name = NULL WHERE vin = ?;") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        } else {
            try? db.execute(sql: "UPDATE telemetry_logs SET latitude = NULL, longitude = NULL;")
            try? db.execute(sql: "UPDATE charging_sessions SET location_name = NULL;")
        }
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
            sessions = (try? db.query(sql: sql) { _ in } process: { [weak self] stmt -> [HistoricalChargingSession] in
                var list: [HistoricalChargingSession] = []
                while stmt.step() {
                    guard let session = self?.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                         endSoc: stmt.columnDouble(at: 5),
                                                         energy: stmt.columnDouble(at: 6),
                                                         peak: stmt.columnDouble(at: 7),
                                                         average: stmt.columnDouble(at: 8),
                                                         location: stmt.columnText(at: 9)) else { continue }
                    list.append(session)
                }
                return list
            }) ?? []
        }

        var csv = "Session ID,VIN,Started At,Ended At,Start SoC (%),End SoC (%),Estimated Energy Added (kWh),Observed Peak Power (kW),Sample Average Power (kW),Location\n"
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
            ? "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source FROM battery_health_history WHERE vin = ? AND measurement_source IN ('calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC;"
            : "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source FROM battery_health_history WHERE measurement_source IN ('calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC;"

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
                      let usable = stmt.columnDouble(at: 6),
                      let source = stmt.columnText(at: 7) else { continue }
                list.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable,
                    measurementSource: source
                ))
            }
            return list
        }) ?? []

        var csv = "Record ID,VIN,Date,Odometer (km),Calculated State of Health (%),Calculated Degradation (%),Estimated Usable (kWh),Method\n"
        let df = ISO8601DateFormatter()
        for r in records {
            let date = df.string(from: r.timestamp)
            csv += "\(r.id),\(r.vin),\(date),\(String(format: "%.1f", r.odometerKm)),\(String(format: "%.2f", r.stateOfHealthPct)),\(String(format: "%.2f", r.degradationPct)),\(String(format: "%.2f", r.effectiveUsableKwh)),\(r.measurementSource)\n"
        }
        return csv
    }

    /// Raw per-sample export for one charging session — the curve data exactly as recorded,
    /// for third-party analysis or debugging a misshapen curve.
    func exportChargingSamplesCSV(sessionID: String) -> String {
        let samples = chargingSamples(for: sessionID)
        let formatter = ISO8601DateFormatter()
        var csv = "Timestamp,SOC (%),Power (kW),Voltage (V),Current (A)\n"
        for sample in samples {
            func cell(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(formatter.string(from: sample.timestamp)),\(String(format: "%.1f", sample.soc)),\(cell(sample.powerKw)),\(cell(sample.voltageVolts)),\(cell(sample.currentAmps))\n"
        }
        return csv
    }

    func exportTelemetryCSV(for vin: String) -> String {
        let records = recentTelemetry(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Record ID,VIN,Date,Odometer (km),Trip Manual (km),Trip Automatic (km),Average Consumption,Ambient Temperature (C)\n"
        for record in records {
            func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(record.id),\(record.vin),\(formatter.string(from: record.timestamp)),\(number(record.odometerKm)),\(number(record.tripManualKm)),\(number(record.tripAutomaticKm)),\(number(record.averageConsumption)),\(number(record.ambientTemperatureCelsius))\n"
        }
        return csv
    }

    func exportCommandAuditsCSV(for vin: String) -> String {
        let records = recentCommandAudits(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String {
            "\"\(value.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " "))\""
        }
        var csv = "Command ID,VIN,Command,Status,Executed At,Duration (ms),Error\n"
        for record in records {
            csv += "\(cell(record.id)),\(record.vin),\(record.command),\(record.status),\(formatter.string(from: record.executedAt)),\(record.durationMs.map(String.init) ?? ""),\(cell(record.errorMessage ?? ""))\n"
        }
        return csv
    }

    // MARK: - Wipe / Purge

    func wipeAll(for vin: String? = nil) {
        // One transaction: a crash mid-wipe previously left partially cleared history, which
        // matters most for the sign-out path where the user expects the data to be *gone*.
        if let vin {
            let statements = [
                "DELETE FROM vehicle_snapshots WHERE vin = ?;",
                "DELETE FROM charging_sessions WHERE vin = ?;",
                "DELETE FROM battery_health_history WHERE vin = ?;",
                "DELETE FROM telemetry_logs WHERE vin = ?;",
                "DELETE FROM charging_samples WHERE vin = ?;",
                "DELETE FROM remote_commands_log WHERE vin = ?;",
                "DELETE FROM connectivity_history WHERE vin = ?;",
                "DELETE FROM cabin_climate_history WHERE vin = ?;",
                "DELETE FROM air_quality_history WHERE vin = ?;"
            ]
            try? db.withTransaction {
                for sql in statements {
                    try db.query(sql: sql) { stmt in
                        try stmt.bindText(vin, at: 1)
                        try stmt.executeUpdate()
                    } process: { _ in }
                }
            }
        } else {
            try? db.withTransaction {
                try db.execute(sql: """
                DELETE FROM vehicle_snapshots;
                DELETE FROM charging_sessions;
                DELETE FROM charging_samples;
                DELETE FROM battery_health_history;
                DELETE FROM telemetry_logs;
                DELETE FROM remote_commands_log;
                DELETE FROM air_quality_history;
                DELETE FROM connectivity_history;
                DELETE FROM cabin_climate_history;
                DELETE FROM fuel_entries;
                """)
            }
            vacuum()
        }
    }
}

extension VehicleDatabase {
    /// Complete local-history export as one JSON document — every table for every vehicle.
    /// Intended for backup/migration between Macs. Coordinates are included only when the
    /// caller explicitly opts in, mirroring the location-history preference elsewhere.
    /// Note: this is a snapshot for humans/backup tooling; there is deliberately no import,
    /// to keep a tampered file from injecting fake telemetry.
    func exportBackupJSON(includeCoordinates: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let vins = Set(
            recentChargingSessionsAllVINs() + batteryHealthAllVINs()
                + telemetryAllVINs() + airQualityAllVINs() + commandAuditAllVINs()
        )

        var payload: [String: Any] = [
            "schema": "hisingen-backup-v1",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "includesCoordinates": includeCoordinates,
        ]

        if includeCoordinates {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: true)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(vins: vins, includeCoordinates: true)))
        } else {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: false)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(vins: vins, includeCoordinates: false)))
        }
        payload["batteryHealth"] = try JSONSerialization.jsonObject(
            with: encoder.encode(batteryHealthHistoryAll()))
        payload["airQuality"] = try JSONSerialization.jsonObject(
            with: encoder.encode(airQualityAll()))
        payload["remoteCommands"] = try JSONSerialization.jsonObject(
            with: encoder.encode(commandAuditsAll()))
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Backup internals

    private func recentChargingSessionsAllVINs() -> [String] {
        allVINs(in: "charging_sessions")
    }
    private func batteryHealthAllVINs() -> [String] { allVINs(in: "battery_health_history") }
    private func telemetryAllVINs() -> [String] { allVINs(in: "telemetry_logs") }
    private func airQualityAllVINs() -> [String] { allVINs(in: "air_quality_history") }
    private func commandAuditAllVINs() -> [String] { allVINs(in: "remote_commands_log") }

    private func allVINs(in table: String) -> [String] {
        (try? db.query(sql: "SELECT DISTINCT vin FROM \(table);") { _ in } process: { stmt -> [String] in
            var out: [String] = []
            while stmt.step(), let vin = stmt.columnText(at: 0) { out.append(vin) }
            return out
        }) ?? []
    }

    private struct BackupSession: Encodable {
        let vin: String
        let startedAt: String
        let endedAt: String?
        let startSoc: Double
        let endSoc: Double?
        let energyKwh: Double
        let peakKw: Double
        let averageKw: Double
        let locationName: String?
    }

    private func backupChargingSessions(includeCoordinates: Bool) -> [BackupSession] {
        let sql = """
        SELECT vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw, average_power_kw, location_name
        FROM charging_sessions ORDER BY started_at DESC;
        """
        let df = ISO8601DateFormatter()
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BackupSession] in
            var out: [BackupSession] = []
            while stmt.step() {
                guard let vin = stmt.columnText(at: 0), let startedAt = stmt.columnDate(at: 1),
                      let startSoc = stmt.columnDouble(at: 3) else { continue }
                out.append(BackupSession(
                    vin: vin,
                    startedAt: df.string(from: startedAt),
                    endedAt: stmt.columnDate(at: 2).map { df.string(from: $0) },
                    startSoc: startSoc,
                    endSoc: stmt.columnDouble(at: 4),
                    energyKwh: stmt.columnDouble(at: 5) ?? 0,
                    peakKw: stmt.columnDouble(at: 6) ?? 0,
                    averageKw: stmt.columnDouble(at: 7) ?? 0,
                    locationName: includeCoordinates ? stmt.columnText(at: 8) : nil
                ))
            }
            return out
        }) ?? []
    }

    private struct BackupTelemetry: Encodable {
        let vin: String
        let timestamp: String
        let odometerKm: Double?
        let averageConsumption: Double?
        let unit: String?
        let ambientTempC: Double?
        let latitude: Double?
        let longitude: Double?
    }

    private func backupTelemetry(vins: Set<String>, includeCoordinates: Bool) -> [BackupTelemetry] {
        let sql = """
        SELECT vin, timestamp, odometer_km, avg_consumption, avg_consumption_unit, ambient_temp_c, latitude, longitude
        FROM telemetry_logs ORDER BY timestamp DESC;
        """
        let df = ISO8601DateFormatter()
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BackupTelemetry] in
            var out: [BackupTelemetry] = []
            while stmt.step() {
                guard let vin = stmt.columnText(at: 0), let ts = stmt.columnDate(at: 1) else { continue }
                out.append(BackupTelemetry(
                    vin: vin, timestamp: df.string(from: ts),
                    odometerKm: stmt.columnDouble(at: 2),
                    averageConsumption: stmt.columnDouble(at: 3),
                    unit: stmt.columnText(at: 4),
                    ambientTempC: stmt.columnDouble(at: 5),
                    latitude: includeCoordinates ? stmt.columnDouble(at: 6) : nil,
                    longitude: includeCoordinates ? stmt.columnDouble(at: 7) : nil
                ))
            }
            return out
        }) ?? []
    }

    private struct BackupBatteryHealth: Encodable {
        let vin: String
        let timestamp: String
        let odometerKm: Double
        let stateOfHealthPct: Double
        let degradationPct: Double
        let effectiveUsableKwh: Double
        let measurementSource: String
    }

    private func batteryHealthHistoryAll() -> [BackupBatteryHealth] {
        batteryHealthHistoryAllRows().map { row in
            BackupBatteryHealth(
                vin: row.vin, timestamp: Format.iso8601.string(from: row.timestamp),
                odometerKm: row.odometerKm, stateOfHealthPct: row.stateOfHealthPct,
                degradationPct: row.degradationPct, effectiveUsableKwh: row.effectiveUsableKwh,
                measurementSource: row.measurementSource)
        }
    }

    private func batteryHealthHistoryAllRows() -> [BatteryHealthRecord] {
        let sql = """
        SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source
        FROM battery_health_history WHERE measurement_source IN ('calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BatteryHealthRecord] in
            var list: [BatteryHealthRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2),
                      let odo = stmt.columnDouble(at: 3),
                      let soh = stmt.columnDouble(at: 4),
                      let deg = stmt.columnDouble(at: 5),
                      let usable = stmt.columnDouble(at: 6),
                      let source = stmt.columnText(at: 7) else { continue }
                list.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable,
                    measurementSource: source
                ))
            }
            return list
        }) ?? []
    }

    private struct BackupAirQuality: Encodable {
        let vin: String
        let timestamp: String
        let aqi: Double?
        let pm25: Double?
        let pm10: Double?
        let filterPercent: Double?
    }

    private func airQualityAll() -> [BackupAirQuality] {
        let sql = """
        SELECT vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10, filter_remaining_percent
        FROM air_quality_history ORDER BY timestamp DESC;
        """
        let df = ISO8601DateFormatter()
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BackupAirQuality] in
            var out: [BackupAirQuality] = []
            while stmt.step() {
                guard let vin = stmt.columnText(at: 0), let ts = stmt.columnDate(at: 1) else { continue }
                out.append(BackupAirQuality(
                    vin: vin, timestamp: df.string(from: ts),
                    aqi: stmt.columnDouble(at: 2), pm25: stmt.columnDouble(at: 3),
                    pm10: stmt.columnDouble(at: 4), filterPercent: stmt.columnDouble(at: 5)))
            }
            return out
        }) ?? []
    }

    private struct BackupCommandAudit: Encodable {
        let vin: String
        let command: String
        let status: String
        let executedAt: String
        let durationMs: Int?
        let errorMessage: String?
    }

    private func commandAuditsAll() -> [BackupCommandAudit] {
        let sql = """
        SELECT vin, command_name, status, executed_at, duration_ms, error_message
        FROM remote_commands_log ORDER BY executed_at DESC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BackupCommandAudit] in
            var list: [BackupCommandAudit] = []
            while stmt.step() {
                guard let vin = stmt.columnText(at: 0),
                      let command = stmt.columnText(at: 1),
                      let status = stmt.columnText(at: 2),
                      let executedAt = stmt.columnDate(at: 3) else { continue }
                list.append(BackupCommandAudit(
                    vin: vin, command: command, status: status,
                    executedAt: isoFormatter.string(from: executedAt),
                    durationMs: stmt.columnInt64(at: 4).map(Int.init),
                    errorMessage: stmt.columnText(at: 5)))
            }
            return list
        }) ?? []
    }
}

// MARK: - Connectivity & Cabin Climate History

extension VehicleDatabase {

    struct ConnectivityRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let timestamp: Date
        let networkType: String?
        let signalBars: Int?
        let wakeReason: String?
    }

    struct CabinClimateRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let timestamp: Date
        let interiorCelsius: Double?
        let requestedCelsius: Double?
    }

    /// Records a connectivity sample only when something observable changed (network type,
    /// signal level, or wake reason) or the hourly heartbeat elapsed — parked-and-sleeping
    /// cars would otherwise duplicate one row per poll.
    @discardableResult
    func recordConnectivity(vin: String, networkType: String?, signalBars: Int?,
                            wakeReason: String?) -> Bool {
        let sql = """
        SELECT timestamp, network_type, signal_bars, wake_reason
        FROM connectivity_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        var last: (Date, String?, Int?, String?)?
        try? db.query(sql: sql) { stmt in try stmt.bindText(vin, at: 1) } process: { stmt in
            if stmt.step(), let ts = stmt.columnDate(at: 0) {
                last = (ts, stmt.columnText(at: 1), stmt.columnInt64(at: 2).map(Int.init),
                        stmt.columnText(at: 3))
            }
        }
        if let last {
            let unchanged = last.1 == networkType && last.2 == signalBars && last.3 == wakeReason
            if unchanged, Date().timeIntervalSince(last.0) < 60 * 60 { return false }
        }
        return executeInsert(
            "INSERT INTO connectivity_history (vin, timestamp, network_type, signal_bars, wake_reason) VALUES (?,?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindText(networkType, at: 3)
            try stmt.bindInt64(signalBars.map(Int64.init), at: 4)
            try stmt.bindText(wakeReason, at: 5)
        }
    }

    @discardableResult
    func recordCabinClimate(vin: String, interiorCelsius: Double?, requestedCelsius: Double?) -> Bool {
        guard interiorCelsius != nil || requestedCelsius != nil else { return false }
        let sql = "SELECT timestamp FROM cabin_climate_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;"
        var last: Date?
        try? db.query(sql: sql) { stmt in try stmt.bindText(vin, at: 1) } process: { stmt in
            if stmt.step() { last = stmt.columnDate(at: 0) }
        }
        // One row per hour is plenty for a temperature trend.
        if let last, Date().timeIntervalSince(last) < 60 * 60 { return false }
        return executeInsert(
            "INSERT INTO cabin_climate_history (vin, timestamp, interior_c, requested_c) VALUES (?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(Date(), at: 2)
            try stmt.bindDouble(interiorCelsius, at: 3)
            try stmt.bindDouble(requestedCelsius, at: 4)
        }
    }

    private func executeInsert(_ sql: String, bind: (SQLiteStatement) throws -> Void) -> Bool {
        do {
            try db.query(sql: sql, bindings: bind) { _ in }
            return true
        } catch {
            logger.error("History insert failed: \(error, privacy: .public)")
            return false
        }
    }

    func recentConnectivity(for vin: String, limit: Int = 200) -> [ConnectivityRecord] {
        let sql = """
        SELECT id, vin, timestamp, network_type, signal_bars, wake_reason
        FROM connectivity_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [ConnectivityRecord] in
            var out: [ConnectivityRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                out.append(ConnectivityRecord(
                    id: id, vin: vin, timestamp: ts,
                    networkType: stmt.columnText(at: 3),
                    signalBars: stmt.columnInt64(at: 4).map(Int.init),
                    wakeReason: stmt.columnText(at: 5)))
            }
            return out
        }) ?? []
    }

    func recentCabinClimate(for vin: String, limit: Int = 200) -> [CabinClimateRecord] {
        let sql = """
        SELECT id, vin, timestamp, interior_c, requested_c
        FROM cabin_climate_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [CabinClimateRecord] in
            var out: [CabinClimateRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                out.append(CabinClimateRecord(
                    id: id, vin: vin, timestamp: ts,
                    interiorCelsius: stmt.columnDouble(at: 3),
                    requestedCelsius: stmt.columnDouble(at: 4)))
            }
            return out
        }) ?? []
    }

    /// Lifetime charging energy for a VIN across all stored sessions (kWh).
    func lifetimeChargingEnergyKwh(for vin: String) -> Double {
        var total = 0.0
        try? db.query(sql: "SELECT COALESCE(SUM(energy_delivered_kwh),0) FROM charging_sessions WHERE vin = ?;", bindings: { stmt in
            try stmt.bindText(vin, at: 1)
        }, process: { stmt in
            if stmt.step() { total = stmt.columnDouble(at: 0) ?? 0 }
        })
        return total
    }

    /// First→last odometer span across stored telemetry, when both ends exist (km).
    func lifetimeOdometerSpanKm(for vin: String) -> Double? {
        let points = HistoryInsights.odometerTrend(from: recentTelemetry(for: vin, limit: 10_000))
        return HistoryInsights.distanceCovered(from: points)
    }
}

extension VehicleDatabase {
    /// Peak power history for prior sessions at the same named location (newest excluded by
    /// the caller passing its id), oldest-first — the baseline for anomaly detection.
    func priorSessionPeaks(vin: String, locationName: String,
                           excludingSessionID: String, limit: Int = 10) -> [Double] {
        guard !locationName.isEmpty else { return [] }
        let sql = """
        SELECT peak_power_kw FROM charging_sessions
        WHERE vin = ? AND location_name = ? AND id != ? AND peak_power_kw > 0
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindText(locationName, at: 2)
            try stmt.bindText(excludingSessionID, at: 3)
            try stmt.bindInt64(Int64(limit), at: 4)
        } process: { stmt -> [Double] in
            var out: [Double] = []
            while stmt.step(), let v = stmt.columnDouble(at: 0) { out.append(v) }
            return out
        }) ?? []
    }
}

// MARK: - Manual Fuel Entries (PHEV/ICE economics)

extension VehicleDatabase {
    struct FuelEntry: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let date: Date
        let liters: Double
        let pricePerLiter: Double
        let odometerKm: Double?
    }

    @discardableResult
    func addFuelEntry(vin: String, date: Date, liters: Double,
                      pricePerLiter: Double, odometerKm: Double?) -> Bool {
        guard liters > 0, pricePerLiter >= 0 else { return false }
        return executeInsert(
            "INSERT INTO fuel_entries (vin, date, liters, price_per_liter, odometer_km) VALUES (?,?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(date, at: 2)
            try stmt.bindDouble(liters, at: 3)
            try stmt.bindDouble(pricePerLiter, at: 4)
            try stmt.bindDouble(odometerKm, at: 5)
        }
    }

    func deleteFuelEntry(id: Int64) {
        try? db.query(sql: "DELETE FROM fuel_entries WHERE id = ?;") { stmt in
            try stmt.bindInt64(id, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func recentFuelEntries(for vin: String, limit: Int = 100) -> [FuelEntry] {
        let sql = """
        SELECT id, vin, date, liters, price_per_liter, odometer_km
        FROM fuel_entries WHERE vin = ? ORDER BY date DESC LIMIT ?;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [FuelEntry] in
            var out: [FuelEntry] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let date = stmt.columnDate(at: 2), let liters = stmt.columnDouble(at: 3),
                      let price = stmt.columnDouble(at: 4) else { continue }
                out.append(FuelEntry(id: id, vin: vin, date: date, liters: liters,
                                     pricePerLiter: price,
                                     odometerKm: stmt.columnDouble(at: 5)))
            }
            return out
        }) ?? []
    }

    /// Total spend on fuel across stored entries — the combustion half of lifetime cost.
    func lifetimeFuelCost(for vin: String) -> Double {
        var total = 0.0
        try? db.query(sql: "SELECT COALESCE(SUM(liters * price_per_liter),0) FROM fuel_entries WHERE vin = ?;", bindings: { stmt in
            try stmt.bindText(vin, at: 1)
        }, process: { stmt in
            if stmt.step() { total = stmt.columnDouble(at: 0) ?? 0 }
        })
        return total
    }
}
