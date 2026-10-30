import Testing
import Foundation
@testable import Hisingen

@Suite("History retention covers sample tables")
struct HistoryRetentionSampleTests {

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "HisingenTests.HistoryRetentionSample.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Inserts one sample and one telemetry row at `timestamp`. Raw SQL keeps the test free of
    /// ledger-specific side effects, so only the prune path decides what survives.
    private func insertRows(into handle: SQLiteDatabase, timestamp: TimeInterval) throws {
        try handle.execute(sql: """
            INSERT INTO charging_samples (session_id, vin, timestamp, soc) VALUES ('s', 'V', \(timestamp), 50);
            INSERT INTO telemetry_logs (vin, timestamp, odometer_km) VALUES ('V', \(timestamp), 1000);
            """)
    }

    @Test("Saved sample retention is read from defaults, falling back to 90 days")
    func resolvesSavedRetention() {
        let defaults = makeDefaults("resolve")
        defer { defaults.removePersistentDomain(forName: "HisingenTests.HistoryRetentionSample.resolve") }

        #expect(HistoryRetention.sampleRetentionDays(defaults: defaults) == 90)

        defaults.set(365, forKey: "history_sample_retention_days")
        #expect(HistoryRetention.sampleRetentionDays(defaults: defaults) == 365)

        defaults.set(12, forKey: "history_sample_retention_days")
        #expect(HistoryRetention.sampleRetentionDays(defaults: defaults) == 90)
    }

    @Test("Aged pass prunes samples and telemetry to the retention horizon")
    func agedPassPrunesSampleTables() throws {
        let handle = try SQLiteDatabase.inMemory()
        let database = VehicleDatabase(database: handle)
        let now = Date().timeIntervalSince1970
        let oldTimestamp = now - 120 * 86_400
        try insertRows(into: handle, timestamp: oldTimestamp)
        try insertRows(into: handle, timestamp: now)

        try database.pruneAgedHistoryOrThrow(sampleRetentionDays: 90)

        let counts = database.recordCounts()
        #expect(counts.chargingSamples == 1)
        #expect(counts.telemetry == 1)
    }

    @Test("Aged pass leaves sample tables alone when no retention is given")
    func agedPassWithoutRetentionKeepsSamples() throws {
        let handle = try SQLiteDatabase.inMemory()
        let database = VehicleDatabase(database: handle)
        let oldTimestamp = Date().timeIntervalSince1970 - 400 * 86_400
        try insertRows(into: handle, timestamp: oldTimestamp)

        try database.pruneAgedHistoryOrThrow()

        let counts = database.recordCounts()
        #expect(counts.chargingSamples == 1)
        #expect(counts.telemetry == 1)
    }

    @Test("Database size reports zero for an in-memory handle")
    func sizeIsZeroInMemory() {
        #expect(VehicleDatabase.inMemory().databaseSizeBytes == 0)
    }
}
