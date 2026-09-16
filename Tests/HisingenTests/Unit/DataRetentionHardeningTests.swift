import Foundation
import Testing
@testable import Hisingen

/// Guards the "don't lose data on an update or a stray sign-out" hardening:
/// sign-out keeps local history by default, schema migrations never drop rows, and a
/// bundle-identifier change carries `UserDefaults` forward.
@MainActor
struct DataRetentionHardeningTests {
    private func seededDatabase(vin: String) -> VehicleDatabase {
        let database = VehicleDatabase.inMemory()
        _ = database.charging.startChargingSession(vin: vin, startSoc: 30)
        #expect(database.recordTelemetry(
            vin: vin, odometerKm: 1_234, tripManualKm: nil, tripAutoKm: nil,
            avgConsumption: nil, ambientTempC: nil, latitude: nil, longitude: nil
        ))
        #expect(database.addFuelEntry(vin: vin, date: Date(), liters: 10, pricePerLiter: 2, odometerKm: 500))
        return database
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "io.kheirallah.hisingen.retentiontest.\(UUID().uuidString)"))
    }

    @Test
    func signOutKeepsLocalHistoryByDefault() throws {
        let vin = "RETENTION_KEEP_TEST"
        let database = seededDatabase(vin: vin)
        let store = VehicleStateStore(defaults: try makeDefaults(), database: database)

        store.clear(vin: vin)

        let counts = database.recordCounts()
        #expect(counts.chargingSessions == 1)
        #expect(counts.telemetry == 1)
        #expect(database.history.recentFuelEntries(for: vin).count == 1)
    }

    @Test
    func signOutClearsHistoryWhenExplicitlyRequested() throws {
        let vin = "RETENTION_ERASE_TEST"
        let database = seededDatabase(vin: vin)
        let store = VehicleStateStore(defaults: try makeDefaults(), database: database)

        store.clear(vin: vin, eraseHistory: true)

        let counts = database.recordCounts()
        #expect(counts.chargingSessions == 0)
        #expect(counts.telemetry == 0)
        #expect(database.history.recentFuelEntries(for: vin).isEmpty)
    }

    @Test
    func fleetWideSignOutClearKeepsLocalHistoryByDefault() throws {
        // The sign-out path that has no vehicle left to name: the fleet-wide clear is its own
        // call, and it keeps the same promise – history stays unless the reader asked for it.
        let first = "RETENTION_FLEET_ONE"
        let second = "RETENTION_FLEET_TWO"
        let database = VehicleDatabase.inMemory()
        _ = database.charging.startChargingSession(vin: first, startSoc: 30)
        _ = database.charging.startChargingSession(vin: second, startSoc: 40)
        #expect(database.recordTelemetry(
            vin: second, odometerKm: 1_234, tripManualKm: nil, tripAutoKm: nil,
            avgConsumption: nil, ambientTempC: nil, latitude: nil, longitude: nil
        ))
        let store = VehicleStateStore(defaults: try makeDefaults(), database: database)

        store.clearAll()

        let counts = database.recordCounts()
        #expect(counts.chargingSessions == 2)
        #expect(counts.telemetry == 1)
    }

    @Test
    func localDataEraseClearsReceiptsButLocationErasePreservesThem() throws {
        let vin = "RECEIPT_RETENTION_TEST"
        let defaults = try makeDefaults()
        let preferences = PreferencesStore(defaults: defaults)
        let database = VehicleDatabase.inMemory()
        let stateStore = VehicleStateStore(defaults: defaults, database: database)
        let record = StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "lock", issuedAt: Date()),
            confirmationDeadline: Date().addingTimeInterval(60)
        )
        stateStore.saveCommandReceipt(record, for: vin)

        // A location erase names the one store it invalidates. The receipt is a row the eraser
        // owns, not a plist entry, so this is the only path that can reach it.
        let eraser = LocalDataEraser(
            database: database, preferences: preferences, imageCache: CarImageCache())
        try eraser.perform(.locations(.vehicle(vin)))
        #expect(stateStore.commandReceipt(for: vin) == record)

        stateStore.clear(vin: vin)
        #expect(stateStore.commandReceipt(for: vin) == nil)
    }

    @Test
    func legacyPlistBaselinesMigrateIntoRowsAndExpiredOnesDoNot() throws {
        let vin = "LEGACY_BASELINE_TEST"
        let expiredVIN = "LEGACY_BASELINE_EXPIRED"
        let defaults = try makeDefaults()
        let baseline = ChargingBaseline(
            vin: vin, state: .charging, connection: .connected, batteryPercentage: 42,
            targetPercentage: 80, vehicleReportedAt: Date(), sampledAt: Date(),
            chargingSessionActive: true, interruptionSamples: 0, lowBatteryNotified: false)
        // The stale one must not come forward: the retention rule is about the baseline, not
        // about which tier it happens to be sitting in.
        let expired = ChargingBaseline(
            vin: expiredVIN, state: .idle, connection: .disconnected, batteryPercentage: 12,
            targetPercentage: 80, vehicleReportedAt: Date().addingTimeInterval(-9 * 24 * 60 * 60),
            sampledAt: Date().addingTimeInterval(-9 * 24 * 60 * 60),
            chargingSessionActive: false, interruptionSamples: 0, lowBatteryNotified: false)
        defaults.set(
            try JSONEncoder().encode([vin: baseline, expiredVIN: expired]),
            forKey: "charging_baselines_v1")

        let database = VehicleDatabase.inMemory()
        let stateStore = VehicleStateStore(defaults: defaults, database: database)
        // The read is pure: nothing is in the row yet, and reading must not move the entry.
        #expect(stateStore.baseline(for: vin) == nil)

        stateStore.activate()

        #expect(stateStore.baseline(for: vin)?.batteryPercentage == 42)
        #expect(database.loadBaseline(for: vin)?.batteryPercentage == 42)
        #expect(stateStore.baseline(for: expiredVIN) == nil)
        #expect(database.loadBaseline(for: expiredVIN) == nil)
        #expect(defaults.data(forKey: "charging_baselines_v1") == nil)
    }

    @Test
    func legacySingleReceiptStorageMigratesToACollection() throws {
        struct LegacyReceipt: Codable {
            var receipt: CommandReceipt
            var confirmationDeadline: Date?
        }

        let vin = "LEGACY_RECEIPT_TEST"
        let defaults = try makeDefaults()
        let deadline = Date(timeIntervalSince1970: 1_750_000_100)
        let receipt = CommandReceipt(
            commandIdentifier: "lock",
            issuedAt: deadline.addingTimeInterval(-60)
        )
        defaults.set(
            try JSONEncoder().encode([
                vin: LegacyReceipt(receipt: receipt, confirmationDeadline: deadline)
            ]),
            forKey: "command_receipts_v1"
        )
        let stateStore = VehicleStateStore(defaults: defaults, database: .inMemory())
        stateStore.activate()

        #expect(stateStore.commandReceipts(for: vin) == [
            StoredCommandReceipt(receipt: receipt, confirmationDeadline: deadline)
        ])
    }

    @Test
    func clearingOneVehicleKeepsOtherReceiptCollections() throws {
        let defaults = try makeDefaults()
        let stateStore = VehicleStateStore(defaults: defaults, database: .inMemory())
        let first = StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "lock", issuedAt: Date()),
            confirmationDeadline: nil
        )
        let second = StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "climate", issuedAt: Date()),
            confirmationDeadline: nil
        )
        stateStore.saveCommandReceipts([first], for: "VIN_A")
        stateStore.saveCommandReceipts([second], for: "VIN_B")

        stateStore.clearCommandReceipts(for: "VIN_A")

        #expect(stateStore.commandReceipts(for: "VIN_A").isEmpty)
        #expect(stateStore.commandReceipts(for: "VIN_B") == [second])
    }

    @Test
    func schemaMigrationPreservesExistingRows() throws {
        // A pre-`user_version` install: `charging_sessions` exists but lacks every column
        // the v2 migration adds, and it already holds a row.
        let handle = try SQLiteDatabase.inMemory()
        try handle.execute(sql: """
            CREATE TABLE charging_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                vin TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                start_soc REAL NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO charging_sessions (id, vin, started_at, start_soc, created_at)
            VALUES ('legacy-session', 'MIGRATION_TEST', 1000, 20, 1000);
            PRAGMA user_version = 0;
            """)

        let database = VehicleDatabase(database: handle)

        #expect(database.recordCounts().chargingSessions == 1)
        #expect(handle.passesQuickCheck())
        let version = try handle.query(sql: "PRAGMA user_version;") { stmt -> Int in
            stmt.step() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(version == VehicleDatabase.latestSchemaVersion)
    }

    @Test
    func quickCheckPassesForAHealthyDatabase() {
        let database = VehicleDatabase.inMemory()
        #expect(database.db.passesQuickCheck())
    }

    @Test
    func staleMigrationBackupsArePrunedOnceSchemaIsCurrent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-bak-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("hisingen.sqlite3")
        let handle = try SQLiteDatabase(path: dbURL.path)
        // Leftovers from earlier schema bumps, plus an unrelated file that must survive.
        for name in ["hisingen.sqlite3.pre-v1.bak", "hisingen.sqlite3.pre-v2.bak",
                     "hisingen.sqlite3.pre-v\(VehicleDatabase.latestSchemaVersion).bak", "keep.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        _ = VehicleDatabase(database: handle)   // schema setup runs pruneMigrationBackups()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!remaining.contains("hisingen.sqlite3.pre-v1.bak"))
        #expect(!remaining.contains("hisingen.sqlite3.pre-v2.bak"))
        #expect(remaining.contains("hisingen.sqlite3.pre-v\(VehicleDatabase.latestSchemaVersion).bak"),
                "the recovery point for the current migration must survive rotation")
        #expect(remaining.contains("hisingen.sqlite3"))
        #expect(remaining.contains("keep.txt"))
    }

    @Test
    func legacyDefaultsAreCarriedForwardOnce() throws {
        let legacyName = "io.kheirallah.hisingen.retentiontest.\(UUID().uuidString)"
        let targetName = "io.kheirallah.hisingen.retentiontest.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let target = try #require(UserDefaults(suiteName: targetName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            target.removePersistentDomain(forName: targetName)
        }
        legacy.set(["exteriorStatus", "notifications"], forKey: "enabled_features_v2")
        legacy.set(35, forKey: "low_battery_threshold")

        let store = PreferencesStore(defaults: target)
        store.migrateLegacyDefaults(domains: [legacyName])

        #expect(target.array(forKey: "enabled_features_v2") as? [String] == ["exteriorStatus", "notifications"])
        #expect(target.integer(forKey: "low_battery_threshold") == 35)
        #expect(target.bool(forKey: "defaults_domain_migrated_v1"))

        // Runs once, and never clobbers a value the new domain already holds.
        target.set(15, forKey: "low_battery_threshold")
        store.migrateLegacyDefaults(domains: [legacyName])
        #expect(target.integer(forKey: "low_battery_threshold") == 15)
    }
}
