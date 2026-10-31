import Foundation
import OSLog

/// High-level vehicle database repository coordinating SQLite tables and schema migrations.
final class VehicleDatabase: @unchecked Sendable {
    static let shared = VehicleDatabase()

    let db: SQLiteDatabase
    struct HistoryToken: Equatable, Sendable {
        let vin: String
        let fleetGeneration: UInt64
        let vehicleGeneration: UInt64
    }
    private let historyBarrier = NSRecursiveLock()
    private let historyAdmission = NSLock()
    private var fleetHistoryGeneration: UInt64 = 0
    private var vehicleHistoryGenerations: [String: UInt64] = [:]
    private var fleetEraseCount = 0
    private var vehicleEraseCounts: [String: Int] = [:]

    private func historyKey(_ vin: String) -> String {
        vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func historyToken(for vin: String) -> HistoryToken? {
        historyAdmission.lock()
        defer { historyAdmission.unlock() }
        let key = historyKey(vin)
        guard fleetEraseCount == 0, vehicleEraseCounts[key, default: 0] == 0 else { return nil }
        return HistoryToken(vin: key, fleetGeneration: fleetHistoryGeneration,
                            vehicleGeneration: vehicleHistoryGenerations[key, default: 0])
    }

    @discardableResult
    func recordHistory(ifCurrent token: HistoryToken, _ work: () -> Void) -> Bool {
        historyBarrier.lock()
        defer { historyBarrier.unlock() }
        historyAdmission.lock()
        let admitted = fleetEraseCount == 0 && vehicleEraseCounts[token.vin, default: 0] == 0
            && token.fleetGeneration == fleetHistoryGeneration
            && token.vehicleGeneration == vehicleHistoryGenerations[token.vin, default: 0]
        historyAdmission.unlock()
        guard admitted else { return false }
        work()
        return true
    }

    func beginHistoryErase(scope: LocalDataEraser.Scope) -> VehicleScope? {
        let vehicles: VehicleScope
        switch scope {
        case .everything(let target), .locations(let target), .session(let target): vehicles = target
        case .samples, .aged, .compact: return nil
        }
        historyAdmission.lock()
        defer { historyAdmission.unlock() }
        switch vehicles {
        case .all:
            fleetEraseCount += 1
            fleetHistoryGeneration &+= 1
        case .vehicle(let vin):
            let key = historyKey(vin)
            vehicleEraseCounts[key, default: 0] += 1
            vehicleHistoryGenerations[key, default: 0] &+= 1
        }
        return vehicles
    }

    func endHistoryErase(_ vehicles: VehicleScope?) {
        guard let vehicles else { return }
        historyAdmission.lock()
        defer { historyAdmission.unlock() }
        switch vehicles {
        case .all: fleetEraseCount -= 1
        case .vehicle(let vin):
            let key = historyKey(vin)
            let remaining = vehicleEraseCounts[key, default: 0] - 1
            if remaining == 0 { vehicleEraseCounts.removeValue(forKey: key) }
            else { vehicleEraseCounts[key] = remaining }
        }
    }

    func eraseWithHistoryBarrier<T>(_ work: () throws -> T) rethrows -> T {
        historyBarrier.lock()
        defer { historyBarrier.unlock() }
        return try work()
    }
    let logger = AppLog.logger("database")
    // JSON coders and date formatters are created per operation rather than shared: this type
    // is `@unchecked Sendable` and its methods run on many threads, and `saveSnapshot` encodes
    // outside the SQLite lock, so a shared `JSONEncoder`/`ISO8601DateFormatter` was an
    // unsynchronised mutable instance (the backup path even reconfigured a shared encoder).
    // Allocation cost is negligible next to the SQLite round trips these sit beside.

    var storageAvailable: Bool { db.isOpen }

    /// The highest `PRAGMA user_version` this build knows how to migrate to. Bump it in
    /// lockstep with a new block in `runMigrations(from:)`.
    static let latestSchemaVersion = 6

    /// The Charging Session ledger owns all domain reads and writes over the
    /// `charging_sessions` and `charging_samples` tables; this repository keeps only their
    /// schema, migrations, and cross-table operations (wipe, prune, backup, counts).
    let charging: ChargingSessionLedger

    /// The Vehicle History ledger owns all domain reads, writes, and CSV exports over the
    /// remaining history tables (battery health, air quality, telemetry, trips, audits,
    /// connectivity, cabin climate, fuel, activities).
    let history: VehicleHistoryLedger
    let snapshots: VehicleSnapshotLedger
    let baselines: ChargingBaselineLedger
    let images: VehicleImageLedger
    let commandReceipts: CommandReceiptStore
    let providerBackoffs: ProviderBackoffLedger

    /// SQLite persistence for the Charging Planner's fetched spot-price series. Market
    /// data, not user history: excluded from wipes, prunes, and backups because a fresh
    /// fetch replaces it wholesale.
    let electricityPrices: ElectricityPriceStore

    /// Whether the database file already existed when this process opened it. Gates the
    /// one-shot pre-migration backup and the corruption quarantine – neither is meaningful
    /// for a database this launch just created.
    let databaseFilePreexisted: Bool

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
        self.snapshots = VehicleSnapshotLedger(sql: handle)
        self.baselines = ChargingBaselineLedger(sql: handle)
        self.images = VehicleImageLedger(sql: handle)
        self.commandReceipts = CommandReceiptStore(sql: handle)
        self.providerBackoffs = ProviderBackoffLedger(sql: handle)
        createTables()
    }

    /// Opens the default database location, creating the directory if needed. Returns the
    /// handle and whether the database file already existed when this process opened it
    /// (gates the one-shot pre-migration backup and the corruption quarantine – neither is
    /// meaningful for a database this launch just created).
    private static func openDatabase(logger: Logger) -> (SQLiteDatabase, Bool) {
        guard let baseDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // No writable Application Support means no durable storage. Use a closed handle –
            // every write degrades and is logged – rather than a temporary directory macOS
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
        Self.applyRestrictivePermissions(at: dbURL)
        return (handle, filePreexisted)
    }

    private static func applyRestrictivePermissions(at dbURL: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = dbURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
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
        let baseStamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueSuffix: String = {
            let ms = Int(Date().timeIntervalSince1970 * 1000) % 1000
            return String(format: "%03d-%08X", ms, UInt32.random(in: 0...UInt32.max))
        }()
        let stamp = "\(baseStamp)-\(uniqueSuffix)"
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: dbURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            var destination = URL(fileURLWithPath: dbURL.path + ".corrupt-\(stamp)" + suffix)
            if fileManager.fileExists(atPath: destination.path) {
                let fallback = URL(fileURLWithPath: dbURL.path + ".corrupt-\(stamp)-\(UUID().uuidString.prefix(8))" + suffix)
                destination = fallback
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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

        -- One row per vehicle, like snapshots: the plist these used to live in rewrote every
        -- vehicle's entry on every save, and no erase regime could see them.
        CREATE TABLE IF NOT EXISTS charging_baselines (
            vin TEXT PRIMARY KEY NOT NULL,
            sampled_at REAL,
            vehicle_reported_at REAL,
            payload BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS provider_backoff (
            subject TEXT PRIMARY KEY NOT NULL,
            vin TEXT,
            blocked_until REAL NOT NULL,
            reason TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_provider_backoff_vin ON provider_backoff(vin);
        CREATE TABLE IF NOT EXISTS command_receipts (
            vin TEXT PRIMARY KEY NOT NULL,
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

        CREATE TABLE IF NOT EXISTS tyre_pressure_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            timestamp REAL NOT NULL,
            position TEXT NOT NULL,
            kilopascals REAL NOT NULL,
            reference_kpa REAL
        );
        CREATE INDEX IF NOT EXISTS idx_tyre_pressure_vin ON tyre_pressure_history(vin, position, timestamp DESC);

        -- One row per warning episode: opened when the warning first appears in a report, closed
        -- when a report that covers the warning no longer shows it. `cleared_at` NULL means open.
        CREATE TABLE IF NOT EXISTS vehicle_warning_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vin TEXT NOT NULL,
            warning TEXT NOT NULL,
            first_seen REAL NOT NULL,
            cleared_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_warning_events_vin ON vehicle_warning_events(vin, first_seen DESC);
        CREATE INDEX IF NOT EXISTS idx_warning_events_open ON vehicle_warning_events(vin, warning) WHERE cleared_at IS NULL;

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
            if !backupBeforeMigration(from: currentVersion) {
                // Migrations still run: the charging ledger inserts and reads the newer columns,
                // so skipping them would stop session recording. A bad data rewrite then has no
                // recovery copy until a later launch's backup succeeds.
                logger.fault("Running schema migrations from v\(currentVersion) without a pre-migration backup")
            }
            runMigrations(from: currentVersion)
            pruneMigrationBackups()
        } catch {
            // .fault: without a schema every persistence path degrades silently.
            logger.fault("Could not initialize database schema: \(error, privacy: .public)")
        }
    }
}
