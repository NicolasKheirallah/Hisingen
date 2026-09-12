import Foundation
import OSLog

/// High-level vehicle database repository coordinating SQLite tables and schema migrations.
final class VehicleDatabase: @unchecked Sendable {
    static let shared = VehicleDatabase()

    let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    // JSON coders and date formatters are created per operation rather than shared: this type
    // is `@unchecked Sendable` and its methods run on many threads, and `saveSnapshot` encodes
    // outside the SQLite lock, so a shared `JSONEncoder`/`ISO8601DateFormatter` was an
    // unsynchronised mutable instance (the backup path even reconfigured a shared encoder).
    // Allocation cost is negligible next to the SQLite round trips these sit beside.

    var storageAvailable: Bool { db.isOpen }

    /// The highest `PRAGMA user_version` this build knows how to migrate to. Bump it in
    /// lockstep with a new block in `runMigrations(from:)`.
    static let latestSchemaVersion = 5

    /// The Charging Session ledger owns all domain reads and writes over the
    /// `charging_sessions` and `charging_samples` tables; this repository keeps only their
    /// schema, migrations, and cross-table operations (wipe, prune, backup, counts).
    let charging: ChargingSessionLedger

    /// The Vehicle History ledger owns all domain reads and CSV exports over the remaining
    /// history tables (battery health, air quality, telemetry, trips, audits, connectivity,
    /// cabin climate, fuel).
    let history: VehicleHistoryLedger

    /// SQLite persistence for the Charging Planner's fetched spot-price series. Market
    /// data, not user history: excluded from wipes, prunes, and backups because a fresh
    /// fetch replaces it wholesale.
    let electricityPrices: ElectricityPriceStore

    /// Whether the database file already existed when this process opened it. Gates the
    /// one-shot pre-migration backup and the corruption quarantine — neither is meaningful
    /// for a database this launch just created.
    private let databaseFilePreexisted: Bool

    init(database: SQLiteDatabase? = nil) {
        var handle: SQLiteDatabase
        var filePreexisted = false
        if let database {
            handle = database
        } else {
            (handle, filePreexisted) = Self.openDatabase(logger: logger)
        }
        self.db = handle
        self.databaseFilePreexisted = filePreexisted
        let chargingLedger = ChargingSessionLedger(sql: handle)
        self.charging = chargingLedger
        self.history = VehicleHistoryLedger(sql: handle, charging: chargingLedger)
        self.electricityPrices = ElectricityPriceStore(sql: handle)
        createTables()
    }

    /// Opens the default database location, creating the directory if needed. Returns the
    /// handle and whether the database file already existed when this process opened it
    /// (gates the one-shot pre-migration backup and the corruption quarantine — neither is
    /// meaningful for a database this launch just created).
    private static func openDatabase(logger: Logger) -> (SQLiteDatabase, Bool) {
        guard let baseDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // No writable Application Support means no durable storage. Use a closed handle —
            // every write degrades and is logged — rather than a temporary directory macOS
            // purges, which previously made "my history vanished" indistinguishable from an
            // OS housekeeping sweep.
            logger.fault("Application Support is unavailable; persistent storage is disabled for this launch")
            return (.unavailable(path: ":unavailable:"), false)
        }

        let appSupport = baseDirectory.appendingPathComponent("Hisingen", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create database directory: \(error, privacy: .public)")
        }
        let dbURL = appSupport.appendingPathComponent("hisingen.sqlite3")
        let filePreexisted = FileManager.default.fileExists(atPath: dbURL.path)
        let handle = Self.openQuarantiningCorruption(
            at: dbURL, preexisting: filePreexisted, logger: logger)
        return (handle, filePreexisted)
    }

    /// Opens the database, and if a pre-existing file fails `PRAGMA quick_check`, moves it
    /// (with its `-wal`/`-shm` siblings) aside to `hisingen.sqlite3.corrupt-<timestamp>` and
    /// starts from a clean file. The data stays recoverable by hand instead of the schema
    /// layer silently recreating an empty database over a corrupt one.
    private static func openQuarantiningCorruption(
        at dbURL: URL, preexisting: Bool, logger: Logger
    ) -> SQLiteDatabase {
        func openHandle() -> SQLiteDatabase? {
            do { return try SQLiteDatabase(path: dbURL.path) }
            catch {
                logger.fault("Could not open database at \(dbURL.path, privacy: .private): \(error, privacy: .public)")
                return nil
            }
        }
        guard let handle = openHandle() else { return .unavailable(path: dbURL.path) }
        guard preexisting, !handle.passesQuickCheck() else { return handle }

        logger.fault("Database failed PRAGMA quick_check; quarantining \(dbURL.lastPathComponent, privacy: .public) and starting fresh")
        handle.close()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: dbURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: dbURL.path + ".corrupt-\(stamp)" + suffix)
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                logger.error("Could not quarantine \(source.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        return openHandle() ?? .unavailable(path: dbURL.path)
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
            created_at REAL NOT NULL,
            lifecycle_state TEXT NOT NULL DEFAULT 'active',
            completion_reason TEXT,
            energy_source TEXT NOT NULL DEFAULT 'soc_capacity_estimate',
            confidence TEXT NOT NULL DEFAULT 'low',
            sample_coverage REAL,
            usable_capacity_kwh REAL,
            tariff_price_per_kwh REAL,
            night_tariff_enabled INTEGER NOT NULL DEFAULT 0,
            night_tariff_price_per_kwh REAL,
            night_tariff_start_hour INTEGER,
            night_tariff_end_hour INTEGER,
            currency_symbol TEXT,
            target_soc REAL,
            last_observed_at REAL,
            summary_version INTEGER NOT NULL DEFAULT 2,
            pending_stop_count INTEGER NOT NULL DEFAULT 0,
            estimated_cost REAL
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

        CREATE TABLE IF NOT EXISTS trip_tags (
            trip_id TEXT NOT NULL,
            vin TEXT NOT NULL,
            purpose TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (trip_id, vin)
        );
        CREATE INDEX IF NOT EXISTS idx_trip_tags_vin ON trip_tags(vin, updated_at DESC);

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

        CREATE TABLE IF NOT EXISTS electricity_prices (
            zone TEXT NOT NULL,
            start_at REAL NOT NULL,
            end_at REAL NOT NULL,
            sek_per_kwh REAL NOT NULL,
            PRIMARY KEY (zone, start_at)
        );
        CREATE INDEX IF NOT EXISTS idx_electricity_prices_zone ON electricity_prices(zone, start_at ASC);

        -- One row per zone: when that zone's series was last fetched from the API.
        CREATE TABLE IF NOT EXISTS electricity_price_fetches (
            zone TEXT PRIMARY KEY NOT NULL,
            fetched_at REAL NOT NULL
        );
        """
        do {
            try db.execute(sql: sql)
            let currentVersion = schemaVersion()
            backupBeforeMigration(from: currentVersion)
            runMigrations(from: currentVersion)
            pruneMigrationBackups()
        } catch {
            // .fault: without a schema every persistence path degrades silently.
            logger.fault("Could not initialize database schema: \(error, privacy: .public)")
        }
    }

    /// Removes old `*.pre-vN.bak` snapshots once the schema has fully reached the latest version,
    /// while retaining the backup created for the current schema migration.
    /// `backupBeforeMigration` writes one (a full-size `VACUUM INTO` copy) before each schema
    /// bump and nothing ever deleted them, so a few version bumps left several ~20 MB copies
    /// beside the live database. A failed migration leaves `user_version` below target, so the
    /// backup is only eligible for rotation after the migration it guards has actually landed.
    /// Keeping the newest one matters: a migration can complete successfully yet still reveal
    /// a semantic data problem later, and deleting its just-created backup made that unrecoverable.
    private func pruneMigrationBackups() {
        guard schemaVersion() >= Self.latestSchemaVersion,
              db.path != ":memory:", db.path != ":unavailable:", !db.path.isEmpty else { return }
        let directory = (db.path as NSString).deletingLastPathComponent
        let prefix = (db.path as NSString).lastPathComponent + ".pre-v"
        let retainedName = "\(prefix)\(Self.latestSchemaVersion).bak"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".bak")
            && entry != retainedName {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(entry))
        }
    }

    private func schemaVersion() -> Int {
        (try? db.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            stmt.step() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }) ?? 0
    }

    /// One-shot copy of the database taken immediately before a schema migration, so a bad
    /// migration or a mid-upgrade crash leaves a recoverable "before" file. Skipped for fresh
    /// installs (nothing to lose) and in-memory databases; never overwrites an existing
    /// backup for the same target version.
    private func backupBeforeMigration(from currentVersion: Int) {
        guard databaseFilePreexisted,
              currentVersion < Self.latestSchemaVersion,
              db.path != ":memory:", db.path != ":unavailable:", !db.path.isEmpty else { return }
        let backupPath = db.path + ".pre-v\(Self.latestSchemaVersion).bak"
        guard !FileManager.default.fileExists(atPath: backupPath) else { return }
        let escaped = backupPath.replacingOccurrences(of: "'", with: "''")
        do {
            try db.execute(sql: "VACUUM INTO '\(escaped)';")
            logger.notice("Wrote pre-migration database backup to \(backupPath, privacy: .public)")
        } catch {
            logger.error("Pre-migration database backup failed: \(error, privacy: .public)")
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
    ///
    /// Additive only: `ALTER TABLE ADD COLUMN`, `CREATE TABLE/INDEX IF NOT EXISTS`, and
    /// in-place `UPDATE`s. A migration must never `DROP` or recreate a table that can hold
    /// user history — `VehicleDatabaseMigrationTests` guards that rows survive an upgrade.
    private func runMigrations(from currentVersion: Int) {
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
            let v1ColumnsReady = columnExists(table: "battery_health_history", column: "measurement_source")
                && columnExists(table: "telemetry_logs", column: "avg_consumption_unit")
                && columnExists(table: "charging_samples", column: "charging_type")
            if v1ColumnsReady {
                // Quarantine rows from the old inferred/Volvo-capacity implementation, then
                // record the version — in one statement group so a failed UPDATE (`sqlite3_exec`
                // stops at the first error) never lets `user_version` advance past the
                // quarantine. Previously the bump ran unconditionally and a transient failure
                // skipped the quarantine forever. Mirrors the v2 block below.
                try? db.execute(sql: """
                    UPDATE battery_health_history SET measurement_source = 'legacy-estimate' WHERE measurement_source = 'measured';
                    PRAGMA user_version = 1;
                    """)
            } else {
                logger.error("Battery-health schema migration remains incomplete; it will retry next launch")
            }
        }

        // v2: explicit charging-session lifecycle and versioned summary provenance.
        if currentVersion < 2 {
            let additions: [(String, String)] = [
                ("lifecycle_state", "TEXT NOT NULL DEFAULT 'active'"),
                ("completion_reason", "TEXT"),
                ("energy_source", "TEXT NOT NULL DEFAULT 'soc_capacity_estimate'"),
                ("confidence", "TEXT NOT NULL DEFAULT 'low'"),
                ("sample_coverage", "REAL"),
                ("usable_capacity_kwh", "REAL"),
                ("tariff_price_per_kwh", "REAL"),
                ("night_tariff_enabled", "INTEGER NOT NULL DEFAULT 0"),
                ("night_tariff_price_per_kwh", "REAL"),
                ("night_tariff_start_hour", "INTEGER"),
                ("night_tariff_end_hour", "INTEGER"),
                ("currency_symbol", "TEXT"),
                ("target_soc", "REAL"),
                ("last_observed_at", "REAL"),
                ("summary_version", "INTEGER NOT NULL DEFAULT 2"),
                ("pending_stop_count", "INTEGER NOT NULL DEFAULT 0"),
                ("estimated_cost", "REAL")
            ]
            for (column, declaration) in additions where !columnExists(table: "charging_sessions", column: column) {
                try? db.execute(sql: "ALTER TABLE charging_sessions ADD COLUMN \(column) \(declaration);")
            }
            if additions.allSatisfy({ columnExists(table: "charging_sessions", column: $0.0) }) {
                try? db.execute(sql: """
                    UPDATE charging_sessions SET
                        lifecycle_state = CASE WHEN ended_at IS NULL THEN 'active' ELSE 'completed' END,
                        completion_reason = CASE WHEN ended_at IS NULL THEN NULL ELSE 'legacy' END,
                        energy_source = 'legacy_estimate', confidence = 'low', summary_version = 1,
                        last_observed_at = COALESCE(ended_at, started_at);
                    CREATE INDEX IF NOT EXISTS idx_charging_sessions_active
                        ON charging_sessions(vin, lifecycle_state, ended_at);
                    PRAGMA user_version = 2;
                    """)
            } else {
                logger.error("Charging-session schema migration remains incomplete; it will retry next launch")
            }
        }

        // v3: durable business/private classification for locally-derived trips.
        if currentVersion < 3 {
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS trip_tags (
                        trip_id TEXT NOT NULL,
                        vin TEXT NOT NULL,
                        purpose TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (trip_id, vin)
                    );
                    CREATE INDEX IF NOT EXISTS idx_trip_tags_vin
                        ON trip_tags(vin, updated_at DESC);
                    PRAGMA user_version = 3;
                    """)
            } catch {
                logger.error("Trip-classification schema migration remains incomplete: \(error, privacy: .public)")
            }
        }
        if schemaVersion() == 3 {
            do {
                try db.withTransaction {
                    try db.execute(sql: """
                        CREATE TABLE IF NOT EXISTS vehicle_activity (
                            id TEXT PRIMARY KEY, vin TEXT NOT NULL,
                            timestamp REAL NOT NULL, payload BLOB NOT NULL
                        );
                        CREATE INDEX IF NOT EXISTS idx_vehicle_activity_vin
                            ON vehicle_activity(vin, timestamp DESC);
                        PRAGMA user_version = 4;
                        """)
                }
            } catch {
                logger.error("Vehicle activity migration remains incomplete: \(error, privacy: .public)")
            }
        }

        // v5: market-price charging cost per session, backfilled from recorded samples.
        if currentVersion < 5 {
            do {
                try db.execute(sql: """
                    ALTER TABLE charging_sessions ADD COLUMN spot_estimated_cost REAL;
                    PRAGMA user_version = 5;
                    """)
            } catch {
                logger.error("Spot-cost schema migration remains incomplete: \(error, privacy: .public)")
            }
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

    // MARK: - Vehicle Snapshots

    func saveSnapshot(_ state: VehicleState) {
        let data: Data
        do {
            data = try JSONEncoder().encode(state.cacheableCopy)
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
            try stmt.bindText(state.identity.vin, at: 1)
            try stmt.bindText(brandName, at: 2)
            try stmt.bindText(state.identity.modelName, at: 3)
            try stmt.bindDate(state.freshness.fetchedAt, at: 4)
            try stmt.bindDate(state.freshness.vehicleReportedAt, at: 5)
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
            guard var state = try? JSONDecoder().decode(VehicleState.self, from: blob) else { return nil }
            if let fetchedAt = stmt.columnDate(at: 1) {
                // Drop expired snapshots older than 7 days
                if Date().timeIntervalSince(fetchedAt) > 7 * 24 * 60 * 60 {
                    snapshotExpired = true
                    return nil
                }
            }
            state.freshness.isCached = true
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

    /// Drops every cached snapshot without touching durable history. Used by the sign-out
    /// path when the user has chosen to keep local history: the snapshot holds live-ish
    /// fields (location, owner name) that should not linger after sign-out, but charging
    /// sessions, telemetry and the rest are kept.
    func deleteAllSnapshots() {
        try? db.execute(sql: "DELETE FROM vehicle_snapshots;")
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
        let previous = history.batteryHealthHistory(for: vin, limit: 50)
            .first { $0.measurementSource == measurementSource }
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
            let previous = history.recentTelemetry(for: vin, limit: 2).dropFirst().first
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




    // MARK: - Trip classification and monthly mileage

    func setTripPurpose(_ purpose: TripPurpose?, tripID: String, vin: String) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tripID.isEmpty, !cleanVIN.isEmpty else { return }
        if let purpose {
            let sql = """
            INSERT INTO trip_tags (trip_id, vin, purpose, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(trip_id, vin) DO UPDATE SET
                purpose=excluded.purpose, updated_at=excluded.updated_at;
            """
            try? db.query(sql: sql) { stmt in
                try stmt.bindText(tripID, at: 1)
                try stmt.bindText(cleanVIN, at: 2)
                try stmt.bindText(purpose.rawValue, at: 3)
                try stmt.bindDate(Date(), at: 4)
                try stmt.executeUpdate()
            } process: { _ in }
        } else {
            try? db.query(sql: "DELETE FROM trip_tags WHERE trip_id = ? AND vin = ?;") { stmt in
                try stmt.bindText(tripID, at: 1)
                try stmt.bindText(cleanVIN, at: 2)
                try stmt.executeUpdate()
            } process: { _ in }
        }
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

    func updateCommandAudit(id: String, status: String, error: String? = nil) {
        let sql = """
        UPDATE remote_commands_log
        SET status = ?, error_message = COALESCE(?, error_message)
        WHERE id = ?;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(status, at: 1)
            try stmt.bindText(error, at: 2)
            try stmt.bindText(id, at: 3)
            try stmt.executeUpdate()
        } process: { _ in }
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
            batteryHealth: count(table: "battery_health_history WHERE measurement_source IN ('full-charge-range-v1', 'calculated-v2', 'legacy-estimate')"),
            telemetry: count(table: "telemetry_logs"),
            commands: count(table: "remote_commands_log")
        )
    }

    func vacuum() {
        try? vacuumOrThrow()
    }

    /// Error-reporting maintenance entry point for interactive callers.
    func vacuumOrThrow() throws {
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        try db.execute(sql: "VACUUM;")
    }

    func pruneHistoricalSamples(olderThanDays: Int = 90) {
        try? pruneHistoricalSamplesOrThrow(olderThanDays: olderThanDays)
    }

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
        cabinClimateOlderThanDays: Int = 180,
        vehicleImagesOlderThanDays: Int = 120,
        vehicleImagesHardCap: Int = 24
    ) {
        let cutoffs: [(sql: String, column: String, days: Int)] = [
            ("DELETE FROM charging_sessions WHERE started_at < ?;", "started_at", chargingSessionsOlderThanDays),
            ("DELETE FROM battery_health_history WHERE timestamp < ?;", "timestamp", batteryHealthOlderThanDays),
            ("DELETE FROM remote_commands_log WHERE executed_at < ?;", "executed_at", commandAuditsOlderThanDays),
            ("DELETE FROM vehicle_activity WHERE timestamp < ?;", "timestamp", commandAuditsOlderThanDays),
            ("DELETE FROM air_quality_history WHERE timestamp < ?;", "timestamp", airQualityOlderThanDays),
            ("DELETE FROM connectivity_history WHERE timestamp < ?;", "timestamp", connectivityOlderThanDays),
            ("DELETE FROM cabin_climate_history WHERE timestamp < ?;", "timestamp", cabinClimateOlderThanDays),
            // The render-image cache stores a full-resolution PNG plus a thumbnail per
            // (vin, angle) and was never pruned — it is the single biggest contributor to a
            // multi-megabyte database on accounts that have tried several render angles.
            ("DELETE FROM vehicle_images WHERE updated_at < ?;", "updated_at", vehicleImagesOlderThanDays)
        ]
        try? db.withTransaction {
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
        vacuum()
    }

    func clearStoredLocations(for vin: String? = nil) {
        try? clearStoredLocationsOrThrow(for: vin)
    }

    /// Privacy-sensitive, error-reporting variant used by Settings. The compaction is part
    /// of the operation so deleted coordinates are not left behind in free SQLite pages.
    func clearStoredLocationsOrThrow(for vin: String? = nil) throws {
        if let vin {
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
        } else {
            try db.withTransaction {
                try db.execute(sql: "UPDATE telemetry_logs SET latitude = NULL, longitude = NULL;")
                try db.execute(sql: "UPDATE charging_sessions SET location_name = NULL;")
            }
        }
        try vacuumOrThrow()
    }

    // MARK: - CSV Exporters






    // MARK: - Wipe / Purge

    func wipeAll(for vin: String? = nil) {
        try? wipeAllOrThrow(for: vin)
    }

    func wipeAllOrThrow(for vin: String? = nil) throws {
        // One transaction: a crash mid-wipe previously left partially cleared history, which
        // matters most for the sign-out path where the user expects the data to be *gone*.
        if let vin {
            let statements = [
                "DELETE FROM vehicle_snapshots WHERE vin = ?;",
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
        } else {
            try db.withTransaction {
                try db.execute(sql: """
                DELETE FROM vehicle_snapshots;
                DELETE FROM vehicle_activity;
                DELETE FROM charging_sessions;
                DELETE FROM charging_samples;
                DELETE FROM battery_health_history;
                DELETE FROM telemetry_logs;
                DELETE FROM trip_tags;
                DELETE FROM remote_commands_log;
                DELETE FROM air_quality_history;
                DELETE FROM connectivity_history;
                DELETE FROM cabin_climate_history;
                DELETE FROM fuel_entries;
                DELETE FROM vehicle_images;
                """)
            }
        }
        try vacuumOrThrow()
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

        var payload: [String: Any] = [
            "schema": "hisingen-backup-v1",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "includesCoordinates": includeCoordinates,
        ]

        if includeCoordinates {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: true)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(includeCoordinates: true)))
        } else {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: false)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(includeCoordinates: false)))
        }
        payload["chargingSamples"] = try JSONSerialization.jsonObject(
            with: encoder.encode(chargingSamplesAll()))
        payload["batteryHealth"] = try JSONSerialization.jsonObject(
            with: encoder.encode(batteryHealthHistoryAll()))
        payload["airQuality"] = try JSONSerialization.jsonObject(
            with: encoder.encode(airQualityAll()))
        payload["remoteCommands"] = try JSONSerialization.jsonObject(
            with: encoder.encode(commandAuditsAll()))
        payload["connectivity"] = try JSONSerialization.jsonObject(
            with: encoder.encode(connectivityAll()))
        payload["cabinClimate"] = try JSONSerialization.jsonObject(
            with: encoder.encode(cabinClimateAll()))
        payload["fuelEntries"] = try JSONSerialization.jsonObject(
            with: encoder.encode(fuelEntriesAll()))
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Backup internals

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
        let lifecycle: String
        let completionReason: String?
        let energySource: String
        let confidence: String
        let sampleCoverage: Double?
        let usableCapacityKwh: Double?
        let tariffPricePerKwh: Double?
        let nightTariffEnabled: Bool
        let nightTariffPricePerKwh: Double?
        let nightTariffStartHour: Int?
        let nightTariffEndHour: Int?
        let estimatedCost: Double?
        let currency: String?
        let targetSoc: Double?
        let summaryVersion: Int
    }

    private func backupChargingSessions(includeCoordinates: Bool) -> [BackupSession] {
        let sql = """
        SELECT vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
               peak_power_kw, average_power_kw, location_name, lifecycle_state,
               completion_reason, energy_source, confidence, sample_coverage,
               usable_capacity_kwh, tariff_price_per_kwh, night_tariff_enabled,
               night_tariff_price_per_kwh, night_tariff_start_hour,
               night_tariff_end_hour, estimated_cost, currency_symbol, target_soc,
               summary_version
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
                    locationName: includeCoordinates ? stmt.columnText(at: 8) : nil,
                    lifecycle: stmt.columnText(at: 9) ?? "legacy",
                    completionReason: stmt.columnText(at: 10),
                    energySource: stmt.columnText(at: 11) ?? "legacy_estimate",
                    confidence: stmt.columnText(at: 12) ?? "low",
                    sampleCoverage: stmt.columnDouble(at: 13),
                    usableCapacityKwh: stmt.columnDouble(at: 14),
                    tariffPricePerKwh: stmt.columnDouble(at: 15),
                    nightTariffEnabled: (stmt.columnInt64(at: 16) ?? 0) != 0,
                    nightTariffPricePerKwh: stmt.columnDouble(at: 17),
                    nightTariffStartHour: stmt.columnInt64(at: 18).map(Int.init),
                    nightTariffEndHour: stmt.columnInt64(at: 19).map(Int.init),
                    estimatedCost: stmt.columnDouble(at: 20),
                    currency: stmt.columnText(at: 21),
                    targetSoc: stmt.columnDouble(at: 22),
                    summaryVersion: Int(stmt.columnInt64(at: 23) ?? 1)
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

    private func backupTelemetry(includeCoordinates: Bool) -> [BackupTelemetry] {
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

    private func chargingSamplesAll() -> [HistoricalChargingSample] {
        let sql = """
        SELECT id, session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type
        FROM charging_samples ORDER BY timestamp ASC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [HistoricalChargingSample] in
            var list: [HistoricalChargingSample] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let sessionID = stmt.columnText(at: 1),
                      let vin = stmt.columnText(at: 2),
                      let timestamp = stmt.columnDate(at: 3),
                      let soc = stmt.columnDouble(at: 4) else { continue }
                list.append(HistoricalChargingSample(
                    id: id, sessionId: sessionID, vin: vin, timestamp: timestamp, soc: soc,
                    powerKw: stmt.columnDouble(at: 5), voltageVolts: stmt.columnDouble(at: 6),
                    currentAmps: stmt.columnDouble(at: 7), chargingType: stmt.columnText(at: 8)))
            }
            return list
        }) ?? []
    }

    private func connectivityAll() -> [ConnectivityRecord] {
        let sql = """
        SELECT id, vin, timestamp, network_type, signal_bars, wake_reason
        FROM connectivity_history ORDER BY timestamp DESC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [ConnectivityRecord] in
            var list: [ConnectivityRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let timestamp = stmt.columnDate(at: 2) else { continue }
                list.append(ConnectivityRecord(
                    id: id, vin: vin, timestamp: timestamp, networkType: stmt.columnText(at: 3),
                    signalBars: stmt.columnInt64(at: 4).map(Int.init), wakeReason: stmt.columnText(at: 5)))
            }
            return list
        }) ?? []
    }

    private func cabinClimateAll() -> [CabinClimateRecord] {
        let sql = """
        SELECT id, vin, timestamp, interior_c, requested_c
        FROM cabin_climate_history ORDER BY timestamp DESC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [CabinClimateRecord] in
            var list: [CabinClimateRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let timestamp = stmt.columnDate(at: 2) else { continue }
                list.append(CabinClimateRecord(
                    id: id, vin: vin, timestamp: timestamp,
                    interiorCelsius: stmt.columnDouble(at: 3), requestedCelsius: stmt.columnDouble(at: 4)))
            }
            return list
        }) ?? []
    }

    private func fuelEntriesAll() -> [FuelEntry] {
        let sql = """
        SELECT id, vin, date, liters, price_per_liter, odometer_km
        FROM fuel_entries ORDER BY date DESC;
        """
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [FuelEntry] in
            var list: [FuelEntry] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let date = stmt.columnDate(at: 2), let liters = stmt.columnDouble(at: 3),
                      let price = stmt.columnDouble(at: 4) else { continue }
                list.append(FuelEntry(
                    id: id, vin: vin, date: date, liters: liters, pricePerLiter: price,
                    odometerKm: stmt.columnDouble(at: 5)))
            }
            return list
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
        FROM battery_health_history
        WHERE measurement_source IN ('full-charge-range-v1', 'calculated-v2', 'legacy-estimate')
        ORDER BY timestamp DESC;
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
        let iso = ISO8601DateFormatter()
        return (try? db.query(sql: sql) { _ in } process: { stmt -> [BackupCommandAudit] in
            var list: [BackupCommandAudit] = []
            while stmt.step() {
                guard let vin = stmt.columnText(at: 0),
                      let command = stmt.columnText(at: 1),
                      let status = stmt.columnText(at: 2),
                      let executedAt = stmt.columnDate(at: 3) else { continue }
                list.append(BackupCommandAudit(
                    vin: vin, command: command, status: status,
                    executedAt: iso.string(from: executedAt),
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
            try db.query(sql: sql, bindings: { stmt in
                try bind(stmt)
                try stmt.executeUpdate()
            }) { _ in }
            return true
        } catch {
            logger.error("History insert failed: \(error, privacy: .public)")
            return false
        }
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


}
