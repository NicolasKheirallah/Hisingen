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
        _ = database.startChargingSession(vin: vin, startSoc: 30)
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
        #expect(database.recentFuelEntries(for: vin).count == 1)
    }

    @Test
    func signOutErasesHistoryWhenExplicitlyRequested() throws {
        let vin = "RETENTION_ERASE_TEST"
        let database = seededDatabase(vin: vin)
        let store = VehicleStateStore(defaults: try makeDefaults(), database: database)

        store.clear(vin: vin, eraseHistory: true)

        let counts = database.recordCounts()
        #expect(counts.chargingSessions == 0)
        #expect(counts.telemetry == 0)
        #expect(database.recentFuelEntries(for: vin).isEmpty)
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
                     "hisingen.sqlite3.pre-v3.bak", "keep.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        _ = VehicleDatabase(database: handle)   // schema setup runs pruneMigrationBackups()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!remaining.contains("hisingen.sqlite3.pre-v1.bak"))
        #expect(!remaining.contains("hisingen.sqlite3.pre-v2.bak"))
        #expect(remaining.contains("hisingen.sqlite3.pre-v3.bak"),
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
