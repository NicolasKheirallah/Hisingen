import Foundation
import Testing
@testable import Hisingen

/// The window arithmetic and the report built from it.
@Suite("Report period and period report")
struct ReportPeriodAndReportTests {
    /// Monday-first so "weekly" means the same seven days on every machine running the suite.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    // MARK: - Periods

    @Test
    func aWeeklyWindowStartsOnTheCalendarsFirstWeekdayAndEndsExclusive() throws {
        let period = ReportCadence.weekly.period(containing: date(2026, 11, 18), calendar: calendar)

        #expect(calendar.component(.weekday, from: period.start) == 2)
        #expect(period.contains(period.start))
        #expect(period.contains(period.end.addingTimeInterval(-1)))
        #expect(period.contains(period.end) == false)
        #expect(abs(period.duration - 7 * 24 * 3_600) < 60)
    }

    @Test
    func aMonthlyWindowIsTheCalendarMonth() throws {
        let period = ReportCadence.monthly.period(containing: date(2026, 11, 18), calendar: calendar)
        let components = calendar.dateComponents([.year, .month], from: period.start)

        #expect(components.year == 2026)
        #expect(components.month == 11)
        #expect(period.contains(date(2026, 11, 30, 23)))
        #expect(period.contains(date(2026, 12, 1, 0)) == false)
    }

    @Test
    func theCompletedWindowIsTheOneThatJustEnded() {
        let now = date(2026, 12, 1, 9)
        let finished = ReportCadence.monthly.completedPeriod(endingAt: now, calendar: calendar)

        #expect(calendar.component(.month, from: finished.start) == 11)
        #expect(finished.end == now.addingTimeInterval(-1) || finished.end <= now)
        #expect(finished.contains(now) == false)
    }

    @Test
    func aWeekIsReportedBeforeTheMonthItBelongsTo() {
        let now = date(2026, 11, 18, 9)

        let weekly = ReportCadence.weekly.completedPeriod(endingAt: now, calendar: calendar)
        let monthly = ReportCadence.monthly.completedPeriod(endingAt: now, calendar: calendar)

        #expect(weekly.start > monthly.start)
        #expect(weekly.end <= now)
    }

    @Test
    func theKeyIdentifiesTheCadenceAndStartAndSurvivesADifferentClockTime() {
        let period = ReportCadence.weekly.period(containing: date(2026, 11, 18, 8), calendar: calendar)
        let samePeriod = ReportCadence.weekly.period(containing: date(2026, 11, 19, 20), calendar: calendar)
        let monthly = ReportCadence.monthly.period(containing: date(2026, 11, 18), calendar: calendar)

        #expect(period.key == samePeriod.key)
        #expect(period.key != monthly.key)
    }

    @Test
    func thePeriodTitleNamesRealDates() {
        let weekly = ReportCadence.weekly.period(containing: date(2026, 11, 18), calendar: calendar)
        let monthly = ReportCadence.monthly.period(containing: date(2026, 11, 18), calendar: calendar)

        #expect(!weekly.titleText(calendar: calendar).isEmpty)
        #expect(monthly.titleText(calendar: calendar).contains("2026"))
    }

    // MARK: - Report

    private func input(
        trips: [PeriodReportTrip] = [],
        charges: [PeriodReportCharge] = [],
        maintenance: [MaintenanceEntry] = [],
        depreciation: DepreciationFigure? = nil,
        redacted: Bool = false
    ) -> PeriodReportInput {
        PeriodReportInput(
            vehicleName: "Polestar 2",
            vin: "YSMREPORTTEST00001",
            period: ReportCadence.monthly.period(containing: date(2026, 11, 18), calendar: calendar),
            trips: trips,
            charges: charges,
            maintenance: maintenance,
            depreciation: depreciation,
            depreciationBasis: depreciation == nil ? nil
                : "Assumes 15 % a year from 400 000 kr paid on 2023-03-15.",
            currencySymbol: "kr",
            distanceUnit: .kilometers,
            generatedAt: date(2026, 12, 1, 8),
            redacted: redacted)
    }

    private func trip(distance: Double, energy: Double?, cost: Double?, fallback: Bool = false) -> PeriodReportTrip {
        PeriodReportTrip(
            endedAt: date(2026, 11, 18, 17), distanceKm: distance, energyKwh: energy,
            cost: cost, priceUsedFallback: fallback)
    }

    @Test
    func totalsAddUpFromTheRowsTheyAreBuiltFrom() {
        let report = input(
            trips: [trip(distance: 40, energy: 8, cost: 12), trip(distance: 60, energy: 12, cost: 18)],
            charges: [
                PeriodReportCharge(startedAt: date(2026, 11, 17), energyKwh: 30, cost: 45),
                PeriodReportCharge(startedAt: date(2026, 11, 10), energyKwh: 10, cost: 15),
            ],
            maintenance: [
                MaintenanceEntry(vin: "YSMREPORTTEST00001", date: date(2026, 11, 5), odometerKm: 42_000,
                                 kind: .service, title: "Service", notes: nil, cost: 3_200),
            ])

        #expect(report.distanceKm == 100)
        #expect(report.tripEnergyKwh == 20)
        #expect(report.tripCost == 30)
        #expect(report.chargingEnergyKwh == 40)
        #expect(report.chargingCost == 60)
        #expect(report.maintenanceCost == 3_200)
        #expect(report.tripCostCoverage == 2)
        #expect(report.chargingCostCoverage == 2)
        #expect(report.isEmpty == false)
    }

    @Test
    func aTripWithNoConsumptionReadingIsNotCountedAsAFreeTrip() {
        let report = input(trips: [trip(distance: 40, energy: nil, cost: nil)])

        #expect(report.distanceKm == 40)
        #expect(report.tripCost == 0)
        #expect(report.tripCostCoverage == 0)
    }

    @Test
    func theTextReportCarriesEverySectionAndTheFiguresInTheTotals() {
        let report = input(
            trips: [trip(distance: 40, energy: 8, cost: 12)],
            charges: [PeriodReportCharge(startedAt: date(2026, 11, 17), energyKwh: 30, cost: 45)],
            maintenance: [
                MaintenanceEntry(vin: "YSMREPORTTEST00001", date: date(2026, 11, 5), odometerKm: 42_000,
                                 kind: .service, title: "Front brake pads", notes: nil, cost: 3_200),
            ],
            depreciation: DepreciationFigure(valueAtStart: 390_000, valueAtEnd: 385_000, yearsOwned: 3.6))

        let text = VehiclePeriodReport.text(report)

        #expect(text.contains(L10n.text("Period Report")))
        #expect(text.contains("40"))
        #expect(text.contains("12"))
        #expect(text.contains("45"))
        #expect(text.contains("3 200") || text.contains("3200") || text.contains("3,200"))
        #expect(text.contains("Front brake pads"))
        #expect(text.contains("5 000") || text.contains("5000") || text.contains("5,000"))
        #expect(text.contains("15"))
    }

    @Test
    func anEmptyWindowSaysSoInsteadOfPrintingNothing() {
        let text = VehiclePeriodReport.text(input())

        #expect(text.contains(L10n.text("No trips in this period.")))
        #expect(text.contains(L10n.text("No charging sessions in this period.")))
        #expect(text.contains(L10n.text("No maintenance entries in this period.")))
    }

    @Test
    func theCsvHasAHeaderAndOneRowPerItemInTypeOrder() {
        let report = input(
            trips: [trip(distance: 40, energy: 8, cost: 12)],
            charges: [PeriodReportCharge(startedAt: date(2026, 11, 17), energyKwh: 30, cost: 45)],
            maintenance: [
                MaintenanceEntry(vin: "YSMREPORTTEST00001", date: date(2026, 11, 5), odometerKm: 42_000,
                                 kind: .inspection, title: "Inspection", notes: nil, cost: 600),
            ])

        let lines = VehiclePeriodReport.csv(report).split(separator: "\n").map(String.init)

        #expect(lines.count == 4)
        #expect(lines[0] == VehiclePeriodReport.csvHeader)
        #expect(lines[1].hasPrefix("trip,"))
        #expect(lines[2].hasPrefix("charging,"))
        #expect(lines[3].hasPrefix("maintenance,"))
        #expect(lines[3].contains("inspection"))
    }

    @Test
    func theSummaryLineNamesDistanceEnergyAndCost() {
        let summary = VehiclePeriodReport.summaryText(input(
            trips: [trip(distance: 320, energy: 60, cost: 90)],
            charges: [PeriodReportCharge(startedAt: date(2026, 11, 17), energyKwh: 120, cost: 180)]))

        #expect(summary.contains("320"))
        #expect(summary.contains("120"))
        #expect(summary.contains("270"))
    }

    @Test
    func aRedactedReportMasksTheVIN() {
        let text = VehiclePeriodReport.text(input(redacted: true))

        #expect(text.contains("YSMREPORTTEST00001") == false)
        #expect(text.contains("0001"))
    }
}
