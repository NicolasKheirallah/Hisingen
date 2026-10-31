import Foundation
import Testing
@testable import Hisingen

/// The tyre-pressure trend rule over stored samples, and the two local history tables it reads:
/// round trips through the ledger, the recorder's health-report path, retention, per-VIN erase,
/// and a check that a fresh install and a migrated store end up with the same schema.
@Suite("Tyre pressure trend and warning timeline")
struct TyreAndWarningHistoryTests {
    private let vin = "TYRE-WARNING-VIN"
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let day: TimeInterval = 86_400

    // MARK: - Slow-leak rule

    private func sample(_ position: TyrePosition, _ kilopascals: Double, atDay days: Double) -> VehicleDatabase.TyrePressureRecord {
        VehicleDatabase.TyrePressureRecord(
            id: 0, vin: vin, timestamp: start.addingTimeInterval(days * day),
            position: position, kilopascals: kilopascals, referenceKilopascals: 250)
    }

    /// Eight evenly spaced samples per tyre. Each tyre moves linearly from 250 kPa by its drop.
    private func series(drops: [TyrePosition: Double], count: Int = 8, spacingDays: Double = 0.4,
                        omitting omitted: Set<TyrePosition> = []) -> [VehicleDatabase.TyrePressureRecord] {
        var records: [VehicleDatabase.TyrePressureRecord] = []
        for step in 0..<count {
            let fraction = Double(step) / Double(max(count - 1, 1))
            for position in TyrePosition.allCases where !omitted.contains(position) {
                let drop = drops[position] ?? 0
                records.append(sample(position, 250 - drop * fraction, atDay: Double(step) * spacingDays))
            }
        }
        return records
    }

    @Test func flagsOneTyreLosingPressureWhileTheOthersHold() throws {
        let leak = try #require(TyrePressureTrend.slowLeak(in: series(drops: [.frontLeft: 20])))
        #expect(leak.position == .frontLeft)
        #expect(abs(leak.dropKilopascals - 20) < 0.001)
        #expect(leak.span >= 2 * day)
    }

    @Test func ignoresAllFourTyresFallingTogether() {
        let together = series(drops: [.frontLeft: 15, .frontRight: 15, .rearLeft: 15, .rearRight: 15])
        #expect(TyrePressureTrend.slowLeak(in: together) == nil)
    }

    @Test func ignoresTooFewSamplesForTheSuspectTyre() {
        #expect(TyrePressureTrend.slowLeak(in: series(drops: [.frontLeft: 20], count: 5)) == nil)
    }

    @Test func ignoresAWindowShorterThanTwoDays() {
        #expect(TyrePressureTrend.slowLeak(in: series(drops: [.frontLeft: 20], spacingDays: 0.2)) == nil)
    }

    @Test func ignoresADropBelowTenKilopascals() {
        #expect(TyrePressureTrend.slowLeak(in: series(drops: [.frontLeft: 8])) == nil)
    }

    @Test func needsEveryOtherTyreReportedToCallTheOthersStable() {
        let missingRearRight = series(drops: [.frontLeft: 20], omitting: [.rearRight])
        #expect(TyrePressureTrend.slowLeak(in: missingRearRight) == nil)
    }

    @Test func emptyHistoryHasNoLeak() {
        #expect(TyrePressureTrend.slowLeak(in: []) == nil)
    }

    // MARK: - Ledger round trips

    private func makeDatabase() -> VehicleDatabase {
        VehicleDatabase.inMemory()
    }

    @Test func tyreReadingsAreStoredOnChangeOrAfterAnHour() {
        let database = makeDatabase()
        let first = database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 250, referenceKilopascals: 250),
            .init(position: .frontRight, kilopascals: 248, referenceKilopascals: 250)
        ], timestamp: start)
        #expect(first == 2)

        // Unchanged and inside the hour: nothing is written.
        #expect(database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 250, referenceKilopascals: 250)
        ], timestamp: start.addingTimeInterval(600)) == 0)

        // A changed value is written straight away.
        #expect(database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 249, referenceKilopascals: 250)
        ], timestamp: start.addingTimeInterval(1_200)) == 1)

        // Unchanged, but the last sample is more than an hour old.
        #expect(database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 249, referenceKilopascals: 250)
        ], timestamp: start.addingTimeInterval(1_200 + 3_600)) == 1)

        let stored = database.history.recentTyrePressure(for: vin)
        #expect(stored.count == 4)
        #expect(stored.filter { $0.position == .frontLeft }.count == 3)
        #expect(database.history.recentTyrePressure(for: "OTHER-VIN").isEmpty)
    }

    @Test func warningEpisodeStaysOpenUntilAReportCoveringItClears() {
        let database = makeDatabase()
        let opened = start
        database.history.syncWarningEvents(vin: vin, active: [.washerFluid],
                                           reported: [.washerFluid, .tyrePressure], timestamp: opened)

        // A report that does not mention washer fluid says nothing about it.
        database.history.syncWarningEvents(vin: vin, active: [], reported: [.tyrePressure],
                                           timestamp: opened.addingTimeInterval(3_600))
        var events = database.history.recentWarningEvents(for: vin)
        #expect(events.count == 1)
        #expect(events.first?.clearedAt == nil)

        let cleared = opened.addingTimeInterval(2 * day)
        database.history.syncWarningEvents(vin: vin, active: [], reported: [.washerFluid, .tyrePressure],
                                           timestamp: cleared)
        events = database.history.recentWarningEvents(for: vin)
        #expect(events.count == 1)
        #expect(events.first?.warning == .washerFluid)
        #expect(events.first?.firstSeen == opened)
        #expect(events.first?.clearedAt == cleared)

        // Reappearing opens a second episode rather than reopening the first.
        database.history.syncWarningEvents(vin: vin, active: [.washerFluid], reported: [.washerFluid],
                                           timestamp: cleared.addingTimeInterval(day))
        #expect(database.history.recentWarningEvents(for: vin).count == 2)
    }

    @Test func dashboardLoadsTyreRowsAndOpenWarningsForThePeriod() {
        let database = makeDatabase()
        database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .rearLeft, kilopascals: 240, referenceKilopascals: 250)
        ], timestamp: Date().addingTimeInterval(-3_600))
        database.history.syncWarningEvents(vin: vin, active: [.lowVoltageBattery],
                                           reported: [.lowVoltageBattery], timestamp: Date().addingTimeInterval(-7_200))

        let snapshot = database.history.dashboard(vin: vin, range: nil, rowCap: 3_000,
                                                  tripLimit: 3_000, chargingCapacity: 60)
        #expect(snapshot.tyrePressureRecords.map(\.position) == [.rearLeft])
        #expect(snapshot.warningEvents.count == 1)
        #expect(snapshot.warningEvents.first?.clearedAt == nil)
    }

    // MARK: - Recorder

    @MainActor
    @Test func healthReportFeedsTyreHistoryAndTheWarningTimeline() async throws {
        let suite = "HisingenTests.TyreWarning.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = makeDatabase()
        let recorder = VehicleHistoryRecorder(database: database, preferences: PreferencesStore(defaults: defaults))

        func health(warnings: [VehicleWarning], frontLeft: Double?) -> VehicleHealthDetails {
            VehicleHealthDetails(
                tyres: [
                    TyrePressure(position: .frontLeft, kilopascals: frontLeft, warning: .none, referenceKilopascals: 250),
                    TyrePressure(position: .frontRight, kilopascals: 250, warning: .none, referenceKilopascals: 250),
                    TyrePressure(position: .rearLeft, kilopascals: nil, warning: .none, referenceKilopascals: 250),
                    TyrePressure(position: .rearRight, kilopascals: 250, warning: .none, referenceKilopascals: 250)
                ],
                warnings: warnings,
                reportedWarnings: [.washerFluid, .tyrePressure]
            )
        }
        func observe(_ details: VehicleHealthDetails, at time: Date) async {
            var state = vehicle(vin: vin, battery: 60, brand: .polestar, fetchedAt: time)
            state.freshness.isCached = false
            state.freshness.readingDates[.health] = time
            state.maintenance.details = details
            recorder.record(state)
            await recorder.drain()
        }

        await observe(health(warnings: [.washerFluid], frontLeft: 240), at: start)
        // Only the three numeric readings are stored; the tyre without kilopascals is skipped.
        #expect(database.history.recentTyrePressure(for: vin).count == 3)
        #expect(database.history.recentWarningEvents(for: vin).first?.clearedAt == nil)

        await observe(health(warnings: [], frontLeft: 240), at: start.addingTimeInterval(3_600))
        let events = database.history.recentWarningEvents(for: vin)
        #expect(events.count == 1)
        #expect(events.first?.clearedAt == start.addingTimeInterval(3_600))
    }

    @MainActor
    @Test func cachedHealthReportDoesNotOpenOrCloseAnything() async throws {
        let suite = "HisingenTests.TyreWarning.Cached.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = makeDatabase()
        let recorder = VehicleHistoryRecorder(database: database, preferences: PreferencesStore(defaults: defaults))

        var state = vehicle(vin: vin, battery: 60, brand: .polestar, fetchedAt: start)
        state.freshness.isCached = true
        state.freshness.readingDates[.health] = start
        state.maintenance.details = VehicleHealthDetails(
            tyres: [TyrePressure(position: .frontLeft, kilopascals: 240, warning: .none, referenceKilopascals: 250)],
            warnings: [.washerFluid], reportedWarnings: [.washerFluid])
        recorder.record(state)
        await recorder.drain()

        #expect(database.history.recentTyrePressure(for: vin).isEmpty)
        #expect(database.history.recentWarningEvents(for: vin).isEmpty)
    }

    // MARK: - Retention and erase

    @Test func agingKeepsOpenWarningsAndDropsOldTyreRowsAndClosedEpisodes() throws {
        let database = makeDatabase()
        let old = Date().addingTimeInterval(-400 * day)
        database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 250, referenceKilopascals: nil)
        ], timestamp: old)
        database.history.syncWarningEvents(vin: vin, active: [.washerFluid], reported: [.washerFluid],
                                           timestamp: old)
        database.history.syncWarningEvents(vin: vin, active: [.oil], reported: [.oil],
                                           timestamp: old)
        database.history.syncWarningEvents(vin: vin, active: [], reported: [.washerFluid],
                                           timestamp: old.addingTimeInterval(day))
        #expect(database.history.recentWarningEvents(for: vin).count == 2)

        try database.pruneAgedHistoryOrThrow()

        #expect(database.history.recentTyrePressure(for: vin).isEmpty)
        let remaining = database.history.recentWarningEvents(for: vin)
        #expect(remaining.count == 1)
        #expect(remaining.first?.warning == .oil)
        #expect(remaining.first?.clearedAt == nil)
    }

    @Test func perVehicleWipeRemovesOnlyThatVehiclesRows() throws {
        let database = makeDatabase()
        let other = "OTHER-TYRE-VIN"
        database.history.recordTyrePressure(vin: vin, readings: [
            .init(position: .frontLeft, kilopascals: 250, referenceKilopascals: nil)
        ], timestamp: start)
        database.history.recordTyrePressure(vin: other, readings: [
            .init(position: .frontLeft, kilopascals: 251, referenceKilopascals: nil)
        ], timestamp: start)
        database.history.syncWarningEvents(vin: vin, active: [.oil], reported: [.oil], timestamp: start)
        database.history.syncWarningEvents(vin: other, active: [.oil], reported: [.oil], timestamp: start)

        try database.wipeVehicleOrThrow(for: vin)

        #expect(database.history.recentTyrePressure(for: vin).isEmpty)
        #expect(database.history.recentWarningEvents(for: vin).isEmpty)
        #expect(database.history.recentTyrePressure(for: other).count == 1)
        #expect(database.history.recentWarningEvents(for: other).count == 1)
    }

    // MARK: - Schema parity

    /// Tables and indexes for the two new history tables, normalised for whitespace so the
    /// baseline DDL and the migration DDL compare by meaning rather than by layout.
    private func schema(_ handle: SQLiteDatabase) throws -> [String] {
        try handle.query(sql: """
            SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
            WHERE tbl_name IN ('tyre_pressure_history', 'vehicle_warning_events') AND sql IS NOT NULL
            ORDER BY name;
            """) { _ in } process: { stmt -> [String] in
            var rows: [String] = []
            while try stmt.stepOrThrow() {
                if let row = stmt.columnText(at: 0) {
                    rows.append(row.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                }
            }
            return rows
        }
    }

    @Test func freshInstallAndMigratedStoreShareTheNewTableSchema() throws {
        let fresh = try SQLiteDatabase.inMemory()
        _ = VehicleDatabase(database: fresh)
        let freshSchema = try schema(fresh)
        #expect(freshSchema.count == 5)

        let migratedRaw = try SQLiteDatabase.inMemory()
        let migrated = VehicleDatabase(database: migratedRaw)
        try migratedRaw.execute(sql: """
            DROP INDEX IF EXISTS idx_warning_events_open;
            DROP INDEX IF EXISTS idx_warning_events_vin;
            DROP TABLE IF EXISTS vehicle_warning_events;
            DROP INDEX IF EXISTS idx_tyre_pressure_vin;
            DROP TABLE IF EXISTS tyre_pressure_history;
            PRAGMA user_version = 5;
            """)
        #expect(try schema(migratedRaw).isEmpty)

        migrated.runMigrations(from: 5)

        #expect(try schema(migratedRaw) == freshSchema)
        let version = try migratedRaw.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            guard try stmt.stepOrThrow() else { return -1 }
            return Int(stmt.columnInt64(at: 0) ?? 0)
        }
        #expect(version == VehicleDatabase.latestSchemaVersion)
        #expect(VehicleDatabase.latestSchemaVersion == 6)
    }
}
