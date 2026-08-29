import Foundation
import Testing
@testable import Hisingen

/// Covers the History-dashboard analytics added alongside the dashboard rebuild: session
/// peak-anomaly scanning, month/year-to-date windows, monthly charging energy, per-location
/// breakdown, driving-pattern buckets, combustion consumption, tank-to-tank fuel economy and
/// the emissions comparison.
struct HistoryInsightsExtraTests {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ id: String, hoursAfterStart: Double, energyKwh: Double,
                         peakKw: Double = 50, location: String? = nil,
                         cost: Double? = nil, currency: String? = nil,
                         ended: Bool = true) -> HistoricalChargingSession {
        let startedAt = start.addingTimeInterval(hoursAfterStart * 3_600)
        return HistoricalChargingSession(
            id: id, vin: "VIN", startedAt: startedAt,
            endedAt: ended ? startedAt.addingTimeInterval(3_600) : nil,
            startSoc: 20, endSoc: 60, energyDeliveredKwh: energyKwh,
            peakPowerKw: peakKw, averagePowerKw: peakKw * 0.7,
            locationName: location, createdAt: startedAt,
            currencySymbol: currency, estimatedCost: cost
        )
    }

    private func trip(_ id: String, secondsAfterStart: Double, distanceKm: Double,
                      durationMinutes: Double = 20) -> TripHistoryEntry {
        let startedAt = start.addingTimeInterval(secondsAfterStart)
        return TripHistoryEntry(
            id: id, vin: "VIN", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationMinutes * 60),
            distanceKm: distanceKm, averageConsumption: nil, ambientTemperatureCelsius: nil,
            startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil
        )
    }

    private func telemetry(_ id: Int64, daysAfterStart: Double, consumption: Double?,
                           unit: String?) -> HistoricalTelemetryRecord {
        HistoricalTelemetryRecord(
            id: id, vin: "VIN", timestamp: start.addingTimeInterval(daysAfterStart * 86_400),
            odometerKm: nil, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: consumption, averageConsumptionUnit: unit,
            ambientTemperatureCelsius: nil, latitude: nil, longitude: nil
        )
    }

    // MARK: - Session peak anomalies

    @Test
    func testSessionPeakAnomaliesFlagsDeratedSessionAtKnownLocation() {
        var sessions = (0..<4).map { session("normal-\($0)", hoursAfterStart: Double($0) * 24, energyKwh: 30, peakKw: 50, location: "Home") }
        sessions.append(session("bad", hoursAfterStart: 200, energyKwh: 30, peakKw: 15, location: "Home"))
        let flagged = HistoryInsights.sessionPeakAnomalies(in: sessions)
        #expect(flagged == ["bad"])
    }

    @Test
    func testSessionPeakAnomaliesIgnoresFirstVisitAndUnnamedLocations() {
        let sessions = [
            session("a", hoursAfterStart: 0, energyKwh: 30, peakKw: 10, location: "Work"),
            session("b", hoursAfterStart: 24, energyKwh: 30, peakKw: 9, location: nil)
        ]
        #expect(HistoryInsights.sessionPeakAnomalies(in: sessions).isEmpty)
    }

    // MARK: - Month / year windows

    @Test
    func testMonthToDateWindowsMirrorsElapsedDays() throws {
        let calendar = utcCalendar
        var now = DateComponents(); now.year = 2_026; now.month = 3; now.day = 10; now.hour = 12
        let nowDate = calendar.date(from: now)!
        let windows = try #require(HistoryInsights.monthToDateWindows(now: nowDate, calendar: calendar))
        #expect(windows.current.start == calendar.date(from: DateComponents(year: 2_026, month: 3, day: 1)))
        #expect(windows.current.end == nowDate)
        #expect(windows.previous.start == calendar.date(from: DateComponents(year: 2_026, month: 2, day: 1)))
        // Same elapsed span, so the two windows are the same length.
        #expect(abs(windows.current.duration - windows.previous.duration) < 1)
    }

    @Test
    func testMonthToDateWindowsClampsToShorterPreviousMonth() throws {
        // 31 March: February only has 28 days, so the mirrored window cannot spill into January.
        let calendar = utcCalendar
        let nowDate = calendar.date(from: DateComponents(year: 2_026, month: 3, day: 31, hour: 23))!
        let windows = try #require(HistoryInsights.monthToDateWindows(now: nowDate, calendar: calendar))
        #expect(windows.previous.start == calendar.date(from: DateComponents(year: 2_026, month: 2, day: 1)))
        #expect(windows.previous.end <= calendar.date(from: DateComponents(year: 2_026, month: 3, day: 1))!)
    }

    @Test
    func testYearToDateWindows() throws {
        let calendar = utcCalendar
        let nowDate = calendar.date(from: DateComponents(year: 2_026, month: 5, day: 20))!
        let windows = try #require(HistoryInsights.yearToDateWindows(now: nowDate, calendar: calendar))
        #expect(windows.current.start == calendar.date(from: DateComponents(year: 2_026, month: 1, day: 1)))
        #expect(windows.previous.start == calendar.date(from: DateComponents(year: 2_025, month: 1, day: 1)))
        #expect(windows.previous.end == calendar.date(from: DateComponents(year: 2_025, month: 5, day: 20)))
    }

    // MARK: - Monthly charging energy

    @Test
    func testMonthlyChargingEnergyBucketsAndSumsCost() {
        let calendar = utcCalendar
        func at(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2_026, month: month, day: day, hour: 12))!
        }
        let sessions = [
            HistoricalChargingSession(id: "a", vin: "VIN", startedAt: at(1, 5), endedAt: at(1, 5).addingTimeInterval(3_600),
                                      startSoc: 20, endSoc: 60, energyDeliveredKwh: 10, peakPowerKw: 40, averagePowerKw: 30,
                                      locationName: nil, createdAt: at(1, 5), currencySymbol: "kr", estimatedCost: 20),
            HistoricalChargingSession(id: "b", vin: "VIN", startedAt: at(1, 20), endedAt: at(1, 20).addingTimeInterval(3_600),
                                      startSoc: 20, endSoc: 60, energyDeliveredKwh: 5, peakPowerKw: 40, averagePowerKw: 30,
                                      locationName: nil, createdAt: at(1, 20), currencySymbol: "kr", estimatedCost: 10),
            HistoricalChargingSession(id: "c", vin: "VIN", startedAt: at(2, 2), endedAt: at(2, 2).addingTimeInterval(3_600),
                                      startSoc: 20, endSoc: 60, energyDeliveredKwh: 8, peakPowerKw: 40, averagePowerKw: 30,
                                      locationName: nil, createdAt: at(2, 2), currencySymbol: "kr", estimatedCost: 16)
        ]
        let monthly = HistoryInsights.monthlyChargingEnergy(from: sessions, fallbackPricePerKwh: 2,
                                                            fallbackCurrency: "kr", calendar: calendar)
        #expect(monthly.count == 2)
        #expect(monthly[0].energyKwh == 15)
        #expect(monthly[0].cost == 30)
        #expect(monthly[1].energyKwh == 8)
    }

    // MARK: - Location breakdown

    @Test
    func testLocationStatsGroupsAndSortsByUsage() {
        let sessions = [
            session("a", hoursAfterStart: 0, energyKwh: 10, peakKw: 7, location: "Home", cost: 20, currency: "kr"),
            session("b", hoursAfterStart: 24, energyKwh: 12, peakKw: 7, location: "Home", cost: 24, currency: "kr"),
            session("c", hoursAfterStart: 48, energyKwh: 30, peakKw: 120, location: "Ionity", cost: 90, currency: "kr"),
            session("d", hoursAfterStart: 72, energyKwh: 5, peakKw: 7, location: nil, cost: 10, currency: "kr")
        ]
        let stats = HistoryInsights.locationStats(from: sessions, fallbackPricePerKwh: 2,
                                                  fallbackCurrency: "kr", unknownLabel: "Unknown")
        #expect(stats.first?.name == "Home")
        #expect(stats.first?.sessionCount == 2)
        #expect(stats.first?.energyKwh == 22)
        #expect(stats.contains { $0.name == "Unknown" })
    }

    // MARK: - Driving patterns

    @Test
    func testTripsByHourOfDayReturnsFullDay() {
        let calendar = Calendar.current
        let hour8 = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: start)!
        let trips = [
            trip("a", secondsAfterStart: hour8.timeIntervalSince(start), distanceKm: 12),
            trip("b", secondsAfterStart: hour8.timeIntervalSince(start) + 60, distanceKm: 8)
        ]
        let buckets = HistoryInsights.tripsByHourOfDay(from: trips, calendar: calendar)
        #expect(buckets.count == 24)
        #expect(buckets[8].tripCount == 2)
        #expect(buckets[8].distanceKm == 20)
    }

    @Test
    func testWeekdayWeekendSplitNormalisesPerDay() {
        let calendar = utcCalendar
        // 2026-01-03 is a Saturday, 2026-01-05 a Monday.
        let saturday = calendar.date(from: DateComponents(year: 2_026, month: 1, day: 3, hour: 10))!
        let monday = calendar.date(from: DateComponents(year: 2_026, month: 1, day: 5, hour: 10))!
        let trips = [
            trip("sat", secondsAfterStart: saturday.timeIntervalSince(start), distanceKm: 100),
            trip("mon", secondsAfterStart: monday.timeIntervalSince(start), distanceKm: 50)
        ]
        var cal = calendar
        cal.firstWeekday = 2
        let split = HistoryInsights.weekdayWeekendDistance(from: trips, calendar: cal)
        #expect(split.weekendKm == 100)
        #expect(split.weekdayKm == 50)
        #expect(split.weekdayKmPerDay == 10)
        #expect(split.weekendKmPerDay == 50)
    }

    // MARK: - Combustion consumption

    @Test
    func testCombustionConsumptionTrendReadsLitreRowsOnly() {
        let records = [
            telemetry(1, daysAfterStart: 0, consumption: 6.5, unit: "l"),
            telemetry(2, daysAfterStart: 1, consumption: 18.0, unit: "kwh"),   // electric row, ignored
            telemetry(3, daysAfterStart: 2, consumption: 7.2, unit: "l"),
            telemetry(4, daysAfterStart: 3, consumption: 99.0, unit: "l")      // out of bounds, ignored
        ]
        let points = HistoryInsights.combustionConsumptionTrend(from: records)
        #expect(points.map(\.kwhPer100Km) == [6.5, 7.2])
    }

    // MARK: - Fuel economy

    @Test
    func testFuelEconomyBetweenFillsUsesOdometerDeltas() {
        let entries: [(id: Int64, date: Date, liters: Double, pricePerLiter: Double, odometerKm: Double?)] = [
            (1, start, 40, 20, 1_000),
            (2, start.addingTimeInterval(7 * 86_400), 30, 21, 1_500),   // 30 L over 500 km -> 6.0 L/100km
            (3, start.addingTimeInterval(14 * 86_400), 45, 22, nil)     // missing odometer -> skipped
        ]
        let points = HistoryInsights.fuelEconomyBetweenFills(entries)
        #expect(points.count == 1)
        #expect(abs((points.first?.litersPer100Km ?? 0) - 6.0) < 0.001)
        #expect(points.first?.id == 2)
    }

    // MARK: - Emissions

    @Test
    func testEmissionsComparisonAvoidsCO2AgainstPetrolBaseline() throws {
        // 1000 km at 18 kWh/100km = 180 kWh. At 120 g/kWh that is 21.6 kg.
        // Petrol baseline 170 g/km over 1000 km = 170 kg. Avoided ~148.4 kg.
        let result = try #require(HistoryInsights.emissionsComparison(
            electricKm: 1_000, consumptionKwhPer100Km: 18, gridGramsCO2PerKwh: 120))
        #expect(abs(result.electricKgCO2 - 21.6) < 0.01)
        #expect(abs(result.petrolKgCO2 - 170) < 0.01)
        #expect(abs(result.avoidedKgCO2 - 148.4) < 0.01)
    }

    @Test
    func testEmissionsComparisonRejectsNonPositiveInputs() {
        #expect(HistoryInsights.emissionsComparison(electricKm: 0, consumptionKwhPer100Km: 18, gridGramsCO2PerKwh: 120) == nil)
        #expect(HistoryInsights.emissionsComparison(electricKm: 100, consumptionKwhPer100Km: 0, gridGramsCO2PerKwh: 120) == nil)
    }
}
