import Foundation
import Testing
@testable import Hisingen

@Suite("History performance boundaries")
struct HistoryPerformanceTests {
    @Test("Scoped dashboards query no earlier than the comparison horizon")
    func scopedDashboardQueryWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 14, hour: 12
        )))
        let rangeStart = try #require(calendar.date(byAdding: .day, value: -7, to: now))
        let lowerBound = try #require(VehicleHistoryLedger.dashboardQueryStart(
            for: rangeStart...now, now: now, calendar: calendar
        ))
        let expected = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(lowerBound == expected)
        #expect(VehicleHistoryLedger.dashboardQueryStart(for: nil, now: now, calendar: calendar) == nil)
    }

    @Test("Trip derivation has a hard telemetry-row budget")
    func tripTelemetryBudget() {
        #expect(VehicleHistoryLedger.telemetryRowLimit(forTripLimit: 1) == 2_000)
        #expect(VehicleHistoryLedger.telemetryRowLimit(forTripLimit: 3_000) == 12_000)
        #expect(VehicleHistoryLedger.telemetryRowLimit(forTripLimit: 10_000) == 12_000)
    }

    @Test("Disk databases use an independent WAL read connection")
    func independentReadConnection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisingenHistoryPerformance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("history.sqlite3").path)
        #expect(database.usesIndependentReadConnection)
    }
}
