import Foundation
import Testing
@testable import Hisingen

/// The migration machinery had no direct test: a fresh store's schema version, a
/// close/re-open round-trip over a real file, and a re-run of the migrator at the latest
/// version (the no-op path every launch after the first takes).
@Suite("SchemaMigration")
struct SchemaMigrationTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaMigrationTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hisingen-test.sqlite3")
    }

    private func userVersion(_ raw: SQLiteDatabase) throws -> Int {
        try raw.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            _ = stmt.step()
            return Int(stmt.columnInt64(at: 0) ?? 0)
        } ?? -1
    }

    @Test func freshStoreMigratesToTheLatestKnownSchemaVersion() throws {
        let raw = try SQLiteDatabase.inMemory()
        _ = VehicleDatabase(database: raw)
        #expect(try userVersion(raw) == VehicleDatabase.latestSchemaVersion)
    }

    @Test func snapshotSurvivesCloseAndReopenOfAFileStore() throws {
        let url = tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let raw = try SQLiteDatabase(path: url.path)
        let first = VehicleDatabase(database: raw)
        let vin = "MIGRATION_ROUNDTRIP_01"
        first.snapshots.saveSnapshot(vehicle(vin: vin, battery: 77))
        #expect(try userVersion(raw) == VehicleDatabase.latestSchemaVersion)

        let reopened = VehicleDatabase(database: try SQLiteDatabase(path: url.path))
        let restored = reopened.snapshots.loadSnapshot(for: vin)
        #expect(restored?.energy.batteryPercentage == 77)
        #expect(restored?.identity.vin == vin)
    }

    @Test func rerunningTheMigratorAtTheLatestVersionIsAHarmlessNoOp() throws {
        let url = tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let raw = try SQLiteDatabase(path: url.path)
        let database = VehicleDatabase(database: raw)
        let before = try userVersion(raw)
        try database.runMigrations(from: before)
        #expect(try userVersion(raw) == VehicleDatabase.latestSchemaVersion)
        // The store still works after the no-op migration: a snapshot round-trips.
        let vin = "MIGRATION_NOOP_02"
        database.snapshots.saveSnapshot(vehicle(vin: vin, battery: 42))
        #expect(database.snapshots.loadSnapshot(for: vin)?.energy.batteryPercentage == 42)
    }
}
