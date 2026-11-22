import Foundation
import Testing
@testable import Hisingen

/// The recurring report posts once per completed window, never for the window the reader is still
/// living in, and never twice for the same one – including after a relaunch.
@Suite(.serialized)
@MainActor
struct RecurringReportControllerTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    @Test
    func aCompletedMonthlyWindowIsReportedOnce() async throws {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly)
        harness.preferences.recurringReportEnabled = true

        await harness.controller.evaluate()
        await harness.controller.evaluate()

        #expect(harness.notifier.reports.count == 1)
        #expect(harness.notifier.reports.first?.body.contains("120") == true)
        let period = try #require(harness.recorder.periods.first)
        #expect(period.cadence == .monthly)
        #expect(Self.calendar.component(.month, from: period.start) == 11)
    }

    @Test
    func theWindowTheReaderIsLivingInIsNeverReported() async throws {
        let harness = Harness(now: Self.date(2026, 11, 18), cadence: .monthly)
        harness.preferences.recurringReportEnabled = true

        await harness.controller.evaluate()

        let period = try #require(harness.recorder.periods.first)
        #expect(Self.calendar.component(.month, from: period.start) == 10)
        #expect(period.contains(Self.date(2026, 11, 18)) == false)
    }

    @Test
    func switchingTheFeatureOffStopsEveryReport() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .weekly)

        await harness.controller.evaluate()

        #expect(harness.notifier.reports.isEmpty)
        #expect(harness.recorder.periods.isEmpty)
    }

    @Test
    func aRelaunchDoesNotRepeatTheWindowAlreadyReported() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly)
        harness.preferences.recurringReportEnabled = true
        await harness.controller.evaluate()
        #expect(harness.notifier.reports.count == 1)

        // A fresh controller over the same preferences is what a relaunch looks like.
        let afterRelaunch = Harness(
            preferences: harness.preferences, now: Self.date(2026, 12, 1), cadence: .monthly)
        await afterRelaunch.controller.evaluate()

        #expect(afterRelaunch.notifier.reports.isEmpty)
        #expect(afterRelaunch.recorder.periods.isEmpty)
    }

    @Test
    func weeklyAndMonthlyTrackTheirOwnWindows() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .weekly)
        harness.preferences.recurringReportEnabled = true
        await harness.controller.evaluate()
        let weeklyKey = harness.preferences.recurringReportLastPeriod(for: "YSMREPORTTEST00001")

        harness.preferences.recurringReportCadence = .monthly
        await harness.controller.evaluate()

        #expect(harness.notifier.reports.count == 2)
        let monthlyKey = harness.preferences.recurringReportLastPeriod(for: "YSMREPORTTEST00001")
        #expect(monthlyKey != weeklyKey)
    }

    @Test
    func anEmptyWindowIsMarkedHandledWithoutPostingABanner() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly, emptyReport: true)
        harness.preferences.recurringReportEnabled = true

        await harness.controller.evaluate()

        #expect(harness.notifier.reports.isEmpty)
        #expect(harness.preferences.recurringReportLastPeriod(for: "YSMREPORTTEST00001") != nil)
    }

    @Test
    func aFailedLoadIsRetriedOnTheNextTickRatherThanRecordedAsReported() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly, loadFails: true)
        harness.preferences.recurringReportEnabled = true

        await harness.controller.evaluate()
        #expect(harness.preferences.recurringReportLastPeriod(for: "YSMREPORTTEST00001") == nil)

        harness.recorder.fails = false
        await harness.controller.evaluate()
        #expect(harness.notifier.reports.count == 1)
    }

    @Test
    func theReportTitleNamesTheCadenceAndTheWindow() async throws {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly)
        harness.preferences.recurringReportEnabled = true

        await harness.controller.evaluate()

        let title = try #require(harness.notifier.reports.first?.title)
        #expect(title.contains(L10n.text("Monthly")))
        #expect(title.contains("2026"))
    }

    @Test
    func aVehicleThatWasSignedOutIsNotReported() async {
        let harness = Harness(now: Self.date(2026, 12, 1), cadence: .monthly)
        harness.preferences.recurringReportEnabled = true
        harness.recorder.hasVehicle = false

        await harness.controller.evaluate()

        #expect(harness.notifier.reports.isEmpty)
    }

    // MARK: - Harness

    @MainActor
    private final class LoadRecorder {
        var periods: [ReportPeriod] = []
        var fails = false
        var isEmpty = false
        var hasVehicle = true
    }

    @MainActor
    private final class FakeReportNotifier: RecurringReportNotifying {
        private(set) var reports: [(title: String, body: String)] = []

        func notifyReport(title: String, body: String) {
            reports.append((title, body))
        }
    }

    @MainActor
    private final class Harness {
        let scoped: ScopedPreferences
        let notifier = FakeReportNotifier()
        let recorder = LoadRecorder()
        let controller: RecurringReportController

        var preferences: PreferencesStore { scoped.store }

        init(preferences: PreferencesStore? = nil, now: Date, cadence: ReportCadence,
             emptyReport: Bool = false, loadFails: Bool = false) {
            let scoped = ScopedPreferences(label: "RecurringReport")
            self.scoped = scoped
            let store = preferences ?? scoped.store
            store.recurringReportCadence = cadence

            let notifier = self.notifier
            let recorder = self.recorder
            recorder.fails = loadFails
            recorder.isEmpty = emptyReport

            controller = RecurringReportController(
                preferences: store,
                notifier: notifier,
                activeVehicle: {
                    recorder.hasVehicle ? ("YSMREPORTTEST00001", "Polestar 2") : nil
                },
                loadReport: { period, _ in
                    if recorder.fails { return nil }
                    recorder.periods.append(period)
                    return PeriodReportInput(
                        vehicleName: "Polestar 2",
                        vin: "YSMREPORTTEST00001",
                        period: period,
                        trips: recorder.isEmpty ? [] : [PeriodReportTrip(
                            endedAt: period.start, distanceKm: 120, energyKwh: 24, cost: 36,
                            priceUsedFallback: false)],
                        charges: recorder.isEmpty ? [] : [PeriodReportCharge(
                            startedAt: period.start, energyKwh: 40, cost: 60)],
                        maintenance: [],
                        depreciation: nil,
                        depreciationBasis: nil,
                        currencySymbol: "kr",
                        distanceUnit: .kilometers,
                        generatedAt: period.end,
                        redacted: false)
                },
                now: { now },
                calendar: RecurringReportControllerTests.calendar,
                wait: { _ in throw CancellationError() })
        }
    }
}
