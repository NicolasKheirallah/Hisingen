import Foundation
import Testing
@testable import Hisingen

/// Two guards around the one file every launch opens.
///
/// A downgrade (a store written by a newer build, opened by an older one) used to pass
/// silently: `runMigrations` had nothing to do at a higher version and the SQL that followed
/// read whatever columns happened to be there. The refusal has to happen before anything
/// reads, and it must leave the newer build's file exactly where it was.
///
/// Corruption is the other end: a store that cannot be trusted must be moved aside so its
/// bytes stay recoverable, never deleted and never half-read into screens as if it were empty.
@Suite("VehicleDatabaseOpenGuard")
struct VehicleDatabaseOpenGuardTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VehicleDatabaseOpenGuard-\(UUID())", isDirectory: true)
    }

    private func makeDirectory() throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Downgrade guard

    @Test func aStoreWrittenByANewerBuildIsRefusedInsteadOfHalfRead() throws {
        let raw = try SQLiteDatabase.inMemory()
        let newerVersion = VehicleDatabase.latestSchemaVersion + 1
        // A newer build's store: its own table shape and a row this build does not understand.
        try raw.execute(sql: """
            CREATE TABLE vehicle_snapshots (
                vin TEXT PRIMARY KEY NOT NULL,
                brand TEXT NOT NULL,
                payload BLOB NOT NULL,
                column_this_build_has_never_seen TEXT
            );
            INSERT INTO vehicle_snapshots (vin, brand, payload) VALUES ('NEWERBUILDVIN00001', 'Polestar', X'00');
            PRAGMA user_version = \(newerVersion);
            """)

        let database = VehicleDatabase(database: raw)

        #expect(database.storageAvailable == false, "a newer store must not stay open for reads")
        #expect(database.db.isOpen == false)
        let refusal = try #require(database.schemaIncompatibility)
        #expect(refusal.storeVersion == newerVersion)
        #expect(refusal.supportedVersion == VehicleDatabase.latestSchemaVersion)

        let message = L10n.withInterfaceLanguageOverride("en") { refusal.message }
        #expect(message.contains("newer version"), "the refusal message must say why it refused: \(message)")
        #expect(message.contains("\(newerVersion)") && message.contains("\(VehicleDatabase.latestSchemaVersion)"),
                "the refusal message must name both schema versions: \(message)")
        #expect(message.contains("Update Hisingen"), "the refusal message must say what to do: \(message)")

        // Not half-read: every read path fails closed rather than returning the newer row.
        #expect(database.snapshots.loadSnapshot(for: "NEWERBUILDVIN00001") == nil)
        #expect(database.history.recentTelemetry(for: "NEWERBUILDVIN00001").isEmpty)
        #expect(database.schemaVersion() == 0, "the refused store's version must not be reported as readable")
    }

    @Test func aStoreWrittenByANewerBuildIsLeftIntactForTheNewerBuild() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hisingen.sqlite3")
        let newerVersion = VehicleDatabase.latestSchemaVersion + 3

        let raw = try SQLiteDatabase(path: url.path)
        try raw.execute(sql: """
            CREATE TABLE vehicle_snapshots (vin TEXT PRIMARY KEY NOT NULL, brand TEXT NOT NULL, payload BLOB NOT NULL);
            INSERT INTO vehicle_snapshots (vin, brand, payload) VALUES ('NEWERBUILDVIN00002', 'Volvo', X'00');
            PRAGMA user_version = \(newerVersion);
            """)

        let database = VehicleDatabase(database: raw)
        #expect(database.schemaIncompatibility != nil)
        raw.close()

        // The next launch of the build that wrote it must find the same store: same version,
        // same row, and no backup or quarantine copy this build invented.
        let inspection = try SQLiteDatabase(path: url.path)
        let versionAfter = try inspection.query(sql: "PRAGMA user_version;") { _ in } process: { statement -> Int in
            try statement.stepOrThrow() ? Int(statement.columnInt64(at: 0) ?? 0) : 0
        }
        let rowsAfter = try inspection.query(sql: "SELECT vin FROM vehicle_snapshots;") { _ in } process: { statement -> [String] in
            var vins: [String] = []
            while try statement.stepOrThrow() {
                if let vin = statement.columnText(at: 0) { vins.append(vin) }
            }
            return vins
        }
        inspection.close()

        #expect(versionAfter == newerVersion, "the refused store's schema version changed")
        #expect(rowsAfter == ["NEWERBUILDVIN00002"], "the refused store's rows changed")
        let extraFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("hisingen.sqlite3.") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(extraFiles.isEmpty, "a refused store must not be backed up, quarantined or renamed: \(extraFiles)")
    }

    @Test func aStoreAtThisBuildsVersionStillOpensAndMigrates() throws {
        let raw = try SQLiteDatabase.inMemory()
        try raw.execute(sql: "PRAGMA user_version = \(VehicleDatabase.latestSchemaVersion);")
        let database = VehicleDatabase(database: raw)

        #expect(database.storageAvailable)
        #expect(database.schemaIncompatibility == nil)
        database.snapshots.saveSnapshot(vehicle(vin: "GUARD-CURRENT-VIN", battery: 61))
        #expect(database.snapshots.loadSnapshot(for: "GUARD-CURRENT-VIN")?.energy.batteryPercentage == 61)
    }

    // MARK: - Corruption quarantine

    @Test func aDatabaseThatFailsQuickCheckIsMovedAsideNotDeleted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hisingen.sqlite3")

        do {
            let raw = try SQLiteDatabase(path: url.path)
            // Enough rows that the store has a second b-tree page to damage.
            try raw.execute(sql: "CREATE TABLE quarantine_proof (id INTEGER PRIMARY KEY, payload TEXT);")
            for index in 0..<200 {
                try raw.execute(sql: "INSERT INTO quarantine_proof (payload) VALUES ('row-\(index)-\(String(repeating: "x", count: 120))');")
            }
            raw.close()
        }

        // Break the page header of page 2: the file still opens, so this is exactly the
        // damage `PRAGMA quick_check` is there to catch.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0, count: 8))
        try handle.close()
        let damagedSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(damagedSize > 4_096)

        let opened = VehicleDatabase.openQuarantiningCorruption(
            at: url, preexisting: true, logger: AppLog.logger("database"))
        #expect(opened.isOpen, "a damaged store must be replaced by a usable one")
        #expect(opened.passesQuickCheck())

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // The main file is moved first; any -wal/-shm siblings SQLite left beside it follow it.
        let quarantined = files.filter {
            $0.hasPrefix("hisingen.sqlite3.corrupt-")
                && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm")
        }
        #expect(quarantined.count == 1, "expected exactly one quarantined database, found \(files)")

        // The damaged bytes are still recoverable: the schema text from page 1 survives.
        let quarantinedURL = directory.appendingPathComponent(quarantined[0])
        let preserved = try Data(contentsOf: quarantinedURL)
        #expect(preserved.count >= damagedSize - 1, "the quarantined copy lost bytes")
        #expect(String(decoding: preserved, as: UTF8.self).contains("quarantine_proof"),
                "the quarantined copy no longer holds the store it was made from")

        // Half-use is the failure this test exists for: the replacement store starts empty and
        // the app's own entry point can write to and read from it.
        let database = VehicleDatabase(database: opened)
        database.snapshots.saveSnapshot(vehicle(vin: "QUARANTINE-FRESH-VIN", battery: 55))
        #expect(database.snapshots.loadSnapshot(for: "QUARANTINE-FRESH-VIN")?.energy.batteryPercentage == 55)
        #expect(database.history.recentTelemetry(for: "QUARANTINE-FRESH-VIN").isEmpty)
    }

    @Test func aFileThatIsNotADatabaseIsMovedAsideWithItsWalSiblings() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hisingen.sqlite3")
        let garbage = Data("this file was never a SQLite database, it is a truncated download".utf8)
        try garbage.write(to: url)
        try Data("wal-bytes".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("shm-bytes".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))

        let opened = VehicleDatabase.openQuarantiningCorruption(
            at: url, preexisting: true, logger: AppLog.logger("database"))
        #expect(opened.isOpen, "an unreadable store must be replaced by a usable one")
        #expect(opened.passesQuickCheck())
        opened.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let quarantined = files.filter { $0.hasPrefix("hisingen.sqlite3.corrupt-") }
        #expect(quarantined.count == 3, "expected the database and both siblings quarantined, found \(files)")

        let quarantinedMain = try #require(quarantined.first { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(quarantinedMain)) == garbage,
                "the unreadable bytes must be preserved, not deleted")
        #expect(quarantined.contains { $0.hasSuffix("-wal") })
        #expect(quarantined.contains { $0.hasSuffix("-shm") })
    }

    @Test func aHealthyStoreIsOpenedInPlaceWithoutCreatingACopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hisingen.sqlite3")

        do {
            let raw = try SQLiteDatabase(path: url.path)
            try raw.execute(sql: "CREATE TABLE healthy (id INTEGER PRIMARY KEY);")
            raw.close()
        }

        let opened = VehicleDatabase.openQuarantiningCorruption(
            at: url, preexisting: true, logger: AppLog.logger("database"))
        #expect(opened.isOpen)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.contains(".corrupt-") },
                "a healthy store must not be quarantined: \(files)")
        #expect(files.contains("hisingen.sqlite3"))
    }
}
