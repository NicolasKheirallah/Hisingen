import Foundation
import Testing
@testable import Hisingen

/// Covers the aggregate/statistical computations added to `HistoryInsights` beyond the
/// original charging-curve/efficiency/odometer trio — battery health trend, charging-session
/// analytics, trip aggregates, command stats, data coverage and chart-gap segmentation.
struct HistoryInsightsAggregatesTests {

    /// Pinned to UTC (independent of whatever timezone the test machine runs in) so date-math
    /// in these tests is reproducible on any CI or developer machine.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon UTC, not a raw epoch offset — a "same day" or "N days later" fixture built from a
    /// near-midnight instant can silently roll into the next calendar day depending on the
    /// fraction added, which is exactly the kind of thing that should never depend on which
    /// epoch second happened to be convenient.
    private var start: Date {
        var components = DateComponents()
        components.year = 2_024; components.month = 1; components.day = 1; components.hour = 12
        return utcCalendar.date(from: components)!
    }

    private func chargingSample(_ id: Int64, minutesAfterStart: Double, soc: Double,
                                powerKw: Double?, voltage: Double? = nil, current: Double? = nil,
                                chargingType: String? = nil) -> HistoricalChargingSample {
        HistoricalChargingSample(id: id, sessionId: "session", vin: "VIN",
                                 timestamp: start.addingTimeInterval(minutesAfterStart * 60),
                                 soc: soc, powerKw: powerKw, voltageVolts: voltage, currentAmps: current,
                                 chargingType: chargingType)
    }

    private func session(_ id: String, hoursAfterStart: Double, energyKwh: Double,
                         peakPowerKw: Double = 7) -> HistoricalChargingSession {
        HistoricalChargingSession(id: id, vin: "VIN", startedAt: start.addingTimeInterval(hoursAfterStart * 3_600),
                                  endedAt: nil, startSoc: 20, endSoc: 80, energyDeliveredKwh: energyKwh,
                                  peakPowerKw: peakPowerKw, averagePowerKw: peakPowerKw * 0.7,
                                  locationName: nil, createdAt: start)
    }

    private func trip(_ id: String, daysAfterStart: Double, distanceKm: Double, durationMinutes: Double,
                      consumption: Double? = nil, temperature: Double? = nil) -> TripHistoryEntry {
        let end = start.addingTimeInterval(daysAfterStart * 86_400)
        return TripHistoryEntry(id: id, vin: "VIN", startedAt: end.addingTimeInterval(-durationMinutes * 60),
                                endedAt: end, distanceKm: distanceKm, averageConsumption: consumption,
                                ambientTemperatureCelsius: temperature, startLatitude: nil, startLongitude: nil,
                                endLatitude: nil, endLongitude: nil)
    }

    private func batteryHealth(_ id: Int64, odometerKm: Double, sohPct: Double) -> BatteryHealthRecord {
        BatteryHealthRecord(id: id, vin: "VIN", timestamp: start, odometerKm: odometerKm, stateOfHealthPct: sohPct,
                            degradationPct: 100 - sohPct, effectiveUsableKwh: 75 * sohPct / 100)
    }

    private func airQuality(_ id: Int64, daysAfterStart: Double, index: Double?) -> AirQualityRecord {
        AirQualityRecord(id: id, vin: "VIN", timestamp: start.addingTimeInterval(daysAfterStart * 86_400),
                         airQualityIndex: index, particulateMatter25: nil, particulateMatter10: nil,
                         filterRemainingPercent: nil)
    }

    private func command(_ id: String, minutesAfterStart: Double, name: String, status: String) -> RemoteCommandAuditRecord {
        RemoteCommandAuditRecord(id: id, vin: "VIN", command: name, status: status,
                                 executedAt: start.addingTimeInterval(minutesAfterStart * 60), durationMs: nil, errorMessage: nil)
    }

    // MARK: - Charging curve: type, 10-80%, idle tail, losses, tariff

    @Test
    func testChargingTypePowerFallbackWhenNoSamplesReportIt() {
        // Legacy samples (recorded before the `chargingType` column existed) carry `nil`, so
        // the peak-power heuristic is the only signal available.
        let legacy = [chargingSample(1, minutesAfterStart: 0, soc: 20, powerKw: 11)]
        XCTAssertEqual(HistoryInsights.chargingType(from: legacy, peakPowerKw: 11), .ac)
        XCTAssertEqual(HistoryInsights.chargingType(from: legacy, peakPowerKw: 22), .ac)
        XCTAssertEqual(HistoryInsights.chargingType(from: legacy, peakPowerKw: 22.01), .dc)
        XCTAssertEqual(HistoryInsights.chargingType(from: legacy, peakPowerKw: 150), .dc)
        XCTAssertEqual(HistoryInsights.chargingType(from: legacy, peakPowerKw: nil), .unknown)
    }

    @Test
    func testChargingTypePrefersVehicleReportedSignalOverPowerHeuristic() {
        // Vehicle explicitly reports AC throughout, even though peak power (a hand-wavy 30 kW,
        // above the 22 kW AC/DC heuristic threshold) would otherwise suggest DC — the real,
        // manufacturer-reported signal must win over the inferred one.
        let samples = (0..<4).map {
            HistoricalChargingSample(id: Int64($0), sessionId: "s", vin: "VIN",
                                     timestamp: start.addingTimeInterval(Double($0) * 60),
                                     soc: 20 + Double($0), powerKw: 30, voltageVolts: nil,
                                     currentAmps: nil, chargingType: "ac")
        }
        XCTAssertEqual(HistoryInsights.chargingType(from: samples, peakPowerKw: 30), .ac)
    }

    @Test
    func testChargingTypeMajorityVoteAcrossMixedSamples() {
        let types = ["dc", "dc", "dc", "ac", "unknown"]
        let samples = types.enumerated().map { offset, type in
            HistoricalChargingSample(id: Int64(offset), sessionId: "s", vin: "VIN",
                                     timestamp: start.addingTimeInterval(Double(offset) * 60),
                                     soc: 20, powerKw: 50, voltageVolts: nil, currentAmps: nil,
                                     chargingType: type)
        }
        XCTAssertEqual(HistoryInsights.chargingType(from: samples, peakPowerKw: 50), .dc)
    }

    @Test
    func testTenToEightyDurationInterpolatesBetweenSamples() throws {
        // A single 20-minute segment from 10% to 90% SoC: the 10% crossing sits exactly at the
        // first sample (fraction 0), the 80% crossing at fraction (80-10)/(90-10) = 7/8 of the
        // way through, i.e. minute 17.5 — giving an exact, hand-checkable 17.5-minute duration.
        let samples = [
            chargingSample(1, minutesAfterStart: 0, soc: 10, powerKw: 50),
            chargingSample(2, minutesAfterStart: 20, soc: 90, powerKw: 50),
        ]
        let curve = HistoryInsights.chargingCurve(from: samples)
        let duration = try XCTUnwrap(HistoryInsights.tenToEightyDuration(from: curve))
        XCTAssertEqual(duration, 17.5 * 60, accuracy: 1)
    }

    @Test
    func testTenToEightyDurationNilWhenBoundsNotReached() {
        let samples = [
            chargingSample(1, minutesAfterStart: 0, soc: 40, powerKw: 50),
            chargingSample(2, minutesAfterStart: 10, soc: 60, powerKw: 50),
        ]
        let curve = HistoryInsights.chargingCurve(from: samples)
        XCTAssertNil(HistoryInsights.tenToEightyDuration(from: curve))
    }

    @Test
    func testIdleTailDetectsTrailingLowPowerAtHighSoc() throws {
        let samples = [
            chargingSample(1, minutesAfterStart: 0, soc: 60, powerKw: 40),
            chargingSample(2, minutesAfterStart: 30, soc: 96, powerKw: 40),
            chargingSample(3, minutesAfterStart: 45, soc: 97, powerKw: 0.5),
            chargingSample(4, minutesAfterStart: 60, soc: 98, powerKw: 0.3),
        ]
        let curve = HistoryInsights.chargingCurve(from: samples)
        let tail = try XCTUnwrap(HistoryInsights.idleTailDuration(from: curve))
        XCTAssertEqual(tail, 15 * 60, accuracy: 1)
    }

    @Test
    func testIdleTailNilWhenSessionEndsAtPeakPower() {
        let samples = [
            chargingSample(1, minutesAfterStart: 0, soc: 60, powerKw: 40),
            chargingSample(2, minutesAfterStart: 10, soc: 70, powerKw: 45),
        ]
        let curve = HistoryInsights.chargingCurve(from: samples)
        XCTAssertNil(HistoryInsights.idleTailDuration(from: curve))
    }

    @Test
    func testEstimatedChargingLossWithinPlausibleBounds() throws {
        // 30 kW for 20 minutes ~= 10 kWh input; SoC rises 20% of a 60 kWh pack = 12 kWh stored,
        // which is *more* than input (physically impossible), so this should be rejected as nil.
        let impossible = [
            chargingSample(1, minutesAfterStart: 0, soc: 40, powerKw: 30),
            chargingSample(2, minutesAfterStart: 20, soc: 60, powerKw: 30),
        ]
        XCTAssertNil(HistoryInsights.estimatedChargingLossPct(from: impossible, packCapacityKwh: 60))

        // 30 kW for 60 minutes = 30 kWh input; SoC rises 20% of a 60 kWh pack = 12 kWh stored.
        // Loss = 1 - 12/30 = 60%, outside the plausible 0...40% band, so also nil.
        let implausible = [
            chargingSample(1, minutesAfterStart: 0, soc: 40, powerKw: 30),
            chargingSample(2, minutesAfterStart: 60, soc: 60, powerKw: 30),
        ]
        XCTAssertNil(HistoryInsights.estimatedChargingLossPct(from: implausible, packCapacityKwh: 60))

        // 30 kW for 24 minutes = 12 kWh input; SoC rises 20% of a 60 kWh pack = 12 kWh stored.
        // Loss = 0%, a plausible (if optimistic) result.
        let realistic = [
            chargingSample(1, minutesAfterStart: 0, soc: 40, powerKw: 30),
            chargingSample(2, minutesAfterStart: 24, soc: 60, powerKw: 30),
        ]
        let loss = try XCTUnwrap(HistoryInsights.estimatedChargingLossPct(from: realistic, packCapacityKwh: 60))
        XCTAssertEqual(loss, 0, accuracy: 0.5)
    }

    @Test
    func testTariffAwareCostSplitsDayAndNightEnergy() throws {
        // Session starts at 23:00 UTC (night, per a 22:00-06:00 schedule) and runs 2 hours,
        // crossing into the day bucket at 01:00.
        let calendar = utcCalendar
        var components = DateComponents()
        components.year = 2_026; components.month = 1; components.day = 1
        components.hour = 23; components.minute = 0
        let sessionStart = calendar.date(from: components)!
        let samples = [
            HistoricalChargingSample(id: 1, sessionId: "s", vin: "VIN", timestamp: sessionStart, soc: 20, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: nil),
            HistoricalChargingSample(id: 2, sessionId: "s", vin: "VIN", timestamp: sessionStart.addingTimeInterval(3_600), soc: 50, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: nil),
            HistoricalChargingSample(id: 3, sessionId: "s", vin: "VIN", timestamp: sessionStart.addingTimeInterval(2 * 3_600), soc: 80, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: nil),
        ]
        let result = try XCTUnwrap(HistoryInsights.tariffAwareCost(
            from: samples, dayRatePerKwh: 3, nightRatePerKwh: 1,
            nightStartHour: 22, nightEndHour: 6, calendar: calendar))
        // 23:00-00:00 interval (night) = 10 kWh, 00:00-01:00 interval (still night, before 06:00) = 10 kWh.
        XCTAssertEqual(result.nightEnergyKwh, 20, accuracy: 0.01)
        XCTAssertEqual(result.dayEnergyKwh, 0, accuracy: 0.01)
        XCTAssertEqual(result.cost, 20, accuracy: 0.01)
    }

    @Test
    func testTariffAwareCostDisabledWhenStartEqualsEndHour() throws {
        let samples = [
            chargingSample(1, minutesAfterStart: 0, soc: 20, powerKw: 10),
            chargingSample(2, minutesAfterStart: 60, soc: 40, powerKw: 10),
        ]
        let result = try XCTUnwrap(HistoryInsights.tariffAwareCost(
            from: samples, dayRatePerKwh: 2, nightRatePerKwh: 0.5, nightStartHour: 3, nightEndHour: 3))
        XCTAssertEqual(result.nightEnergyKwh, 0, accuracy: 0.01)
    }

    // MARK: - Charging aggregates

    @Test
    func testSessionsPerWeek() {
        let sessions = [session("a", hoursAfterStart: 0, energyKwh: 10), session("b", hoursAfterStart: 7 * 24, energyKwh: 10)]
        // Exactly one week apart, two sessions -> 2 sessions / 1 week.
        XCTAssertEqual(HistoryInsights.sessionsPerWeek(from: sessions) ?? 0, 2, accuracy: 0.01)
        XCTAssertNil(HistoryInsights.sessionsPerWeek(from: [session("a", hoursAfterStart: 0, energyKwh: 10)]))
    }

    @Test
    func testEnergyByTimeOfDayBucketsByStartHour() {
        var morning = DateComponents(); morning.year = 2_026; morning.month = 1; morning.day = 1; morning.hour = 8
        var evening = DateComponents(); evening.year = 2_026; evening.month = 1; evening.day = 1; evening.hour = 20
        let calendar = utcCalendar
        let sessions = [
            HistoricalChargingSession(id: "a", vin: "VIN", startedAt: calendar.date(from: morning)!, endedAt: nil,
                                      startSoc: 20, endSoc: 80, energyDeliveredKwh: 10, peakPowerKw: 7, averagePowerKw: 5,
                                      locationName: nil, createdAt: start),
            HistoricalChargingSession(id: "b", vin: "VIN", startedAt: calendar.date(from: evening)!, endedAt: nil,
                                      startSoc: 20, endSoc: 80, energyDeliveredKwh: 30, peakPowerKw: 7, averagePowerKw: 5,
                                      locationName: nil, createdAt: start),
        ]
        let byTime = HistoryInsights.energyByTimeOfDay(from: sessions, calendar: calendar)
        XCTAssertEqual(byTime[.morning] ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(byTime[.evening] ?? 0, 30, accuracy: 0.01)
        XCTAssertNil(byTime[.night])
    }

    // MARK: - Efficiency: seasonal & trend slope

    @Test
    func testSeasonalEfficiencyBucketsByTemperature() {
        let records = [
            HistoricalTelemetryRecord(id: 1, vin: "VIN", timestamp: start, odometerKm: nil, tripManualKm: nil,
                                      tripAutomaticKm: nil, averageConsumption: 24, averageConsumptionUnit: "kwh", ambientTemperatureCelsius: -2,
                                      latitude: nil, longitude: nil),
            HistoricalTelemetryRecord(id: 2, vin: "VIN", timestamp: start, odometerKm: nil, tripManualKm: nil,
                                      tripAutomaticKm: nil, averageConsumption: 16, averageConsumptionUnit: "kwh", ambientTemperatureCelsius: 22,
                                      latitude: nil, longitude: nil),
        ]
        let seasonal = HistoryInsights.seasonalEfficiency(from: records)
        XCTAssertEqual(seasonal.coldAverage ?? 0, 24, accuracy: 0.01)
        XCTAssertEqual(seasonal.warmAverage ?? 0, 16, accuracy: 0.01)
        XCTAssertNil(seasonal.mildAverage)
    }

    @Test
    func testEfficiencyTrendSlopeDetectsRisingConsumption() throws {
        // Consumption climbs by 1 kWh/100km every 10 days, well past the collapse tolerance
        // and >=5 points, so a positive slope should be recovered.
        let points = (0..<6).map { index in
            HistoryInsights.EfficiencyPoint(id: Int64(index), timestamp: start.addingTimeInterval(Double(index) * 10 * 86_400),
                                            kwhPer100Km: 15 + Double(index))
        }
        let slope = try XCTUnwrap(HistoryInsights.efficiencyTrendSlopePerDay(from: points))
        XCTAssertEqual(slope, 0.1, accuracy: 0.001) // 1 kWh/100km per 10 days = 0.1 per day
    }

    @Test
    func testEfficiencyTrendSlopeNilWithFewPoints() {
        let points = (0..<3).map { HistoryInsights.EfficiencyPoint(id: Int64($0), timestamp: start, kwhPer100Km: 18) }
        XCTAssertNil(HistoryInsights.efficiencyTrendSlopePerDay(from: points))
    }

    // MARK: - Odometer: rate & monthly mileage

    @Test
    func testAverageKmPerDay() {
        let points = [
            HistoryInsights.OdometerPoint(id: 1, timestamp: start, odometerKm: 10_000),
            HistoryInsights.OdometerPoint(id: 2, timestamp: start.addingTimeInterval(10 * 86_400), odometerKm: 10_300),
        ]
        XCTAssertEqual(HistoryInsights.averageKmPerDay(from: points) ?? 0, 30, accuracy: 0.01)
    }

    @Test
    func testMonthlyMileageBucketsAcrossMonthBoundary() {
        let calendar = utcCalendar
        var jan = DateComponents(); jan.year = 2_026; jan.month = 1; jan.day = 15
        var feb = DateComponents(); feb.year = 2_026; feb.month = 2; feb.day = 15
        let points = [
            HistoryInsights.OdometerPoint(id: 1, timestamp: calendar.date(from: jan)!, odometerKm: 1_000),
            HistoryInsights.OdometerPoint(id: 2, timestamp: calendar.date(from: feb)!, odometerKm: 1_500),
        ]
        let monthly = HistoryInsights.monthlyMileage(from: points, calendar: calendar)
        XCTAssertEqual(monthly.count, 1)
        XCTAssertEqual(monthly.first?.distanceKm ?? 0, 500, accuracy: 0.01)
    }

    // MARK: - Trip aggregates

    @Test
    func testLongestTripPicksMaxDistance() {
        let trips = [trip("a", daysAfterStart: 0, distanceKm: 5, durationMinutes: 10),
                     trip("b", daysAfterStart: 1, distanceKm: 40, durationMinutes: 30)]
        XCTAssertEqual(HistoryInsights.longestTrip(from: trips)?.id, "b")
    }

    @Test
    func testAverageSpeedKmh() {
        let fast = trip("a", daysAfterStart: 0, distanceKm: 60, durationMinutes: 60)
        XCTAssertEqual(HistoryInsights.averageSpeedKmh(fast) ?? 0, 60, accuracy: 0.01)
        let tooShort = trip("b", daysAfterStart: 0, distanceKm: 1, durationMinutes: 0.1)
        XCTAssertNil(HistoryInsights.averageSpeedKmh(tooShort))
    }

    @Test
    func testTemperatureConsumptionCorrelationNegativeForColderMeansHigherUse() throws {
        let trips = (0..<6).map { index in
            trip("t\(index)", daysAfterStart: Double(index), distanceKm: 10, durationMinutes: 20,
                consumption: 25 - Double(index), temperature: Double(index) * 5)
        }
        let correlation = try XCTUnwrap(HistoryInsights.temperatureConsumptionCorrelation(from: trips))
        XCTAssertTrue(correlation < -0.9)
    }

    @Test
    func testDailyAndWeeklyDistanceBucketing() {
        let calendar = utcCalendar
        let trips = [trip("a", daysAfterStart: 0, distanceKm: 10, durationMinutes: 10),
                     trip("b", daysAfterStart: 0.2, distanceKm: 15, durationMinutes: 10),
                     trip("c", daysAfterStart: 1, distanceKm: 20, durationMinutes: 10)]
        let daily = HistoryInsights.dailyDistance(from: trips, calendar: calendar)
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily.first?.distanceKm ?? 0, 25, accuracy: 0.01)
        let weekly = HistoryInsights.weeklyDistance(from: trips, calendar: calendar)
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly.first?.distanceKm ?? 0, 45, accuracy: 0.01)
    }

    // MARK: - Battery health trend & projection

    @Test
    func testBatteryHealthTrendRecoversNegativeSlope() {
        let records = (0..<5).map { batteryHealth(Int64($0), odometerKm: Double($0) * 10_000, sohPct: 100 - Double($0)) }
        let trend = HistoryInsights.batteryHealthTrend(from: records)
        XCTAssertEqual(trend.stateOfHealthPctPer10kKm ?? 0, -1, accuracy: 0.01)
    }

    @Test
    func testProjectedStateOfHealthUsesTrend() throws {
        let records = (0..<5).map { batteryHealth(Int64($0), odometerKm: Double($0) * 10_000, sohPct: 100 - Double($0)) }
        let projected = try XCTUnwrap(HistoryInsights.projectedStateOfHealth(from: records, atOdometerKm: 60_000))
        XCTAssertEqual(projected, 94, accuracy: 0.1)
    }

    @Test
    func testProjectedStateOfHealthRejectsOutOfRangeResult() {
        // A wildly steep synthetic slope projected far out would fall below 0%, which should
        // come back nil rather than a nonsensical negative "health".
        let records = [batteryHealth(1, odometerKm: 0, sohPct: 100), batteryHealth(2, odometerKm: 1_000, sohPct: 50)]
        XCTAssertNil(HistoryInsights.projectedStateOfHealth(from: records, atOdometerKm: 100_000))
    }

    // MARK: - Air quality trend

    @Test
    func testAirQualityTrendDropsNilAndSortsChronologically() {
        let records = [airQuality(1, daysAfterStart: 1, index: 20), airQuality(2, daysAfterStart: 0, index: 10),
                       airQuality(3, daysAfterStart: 0.5, index: nil)]
        let points = HistoryInsights.airQualityTrend(from: records)
        XCTAssertEqual(points.map(\.id), [2, 1])
        XCTAssertTrue(points.first!.timestamp < points.last!.timestamp)
    }

    // MARK: - Command statistics

    @Test
    func testCommandStatisticsComputesSuccessRateAndMostUsed() {
        let commands = [
            command("1", minutesAfterStart: 0, name: "lock", status: "success"),
            command("2", minutesAfterStart: 1, name: "lock", status: "success"),
            command("3", minutesAfterStart: 2, name: "climate", status: "failed"),
        ]
        let stats = HistoryInsights.commandStatistics(from: commands)
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.successCount, 2)
        XCTAssertEqual(stats.successRatePct ?? 0, 66.66, accuracy: 0.1)
        XCTAssertEqual(stats.mostUsedCommand, "lock")
    }

    @Test
    func testCommandStatisticsEmptyInput() {
        let stats = HistoryInsights.commandStatistics(from: [])
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertNil(stats.successRatePct)
        XCTAssertNil(stats.mostUsedCommand)
    }

    // MARK: - Data coverage

    @Test
    func testDataCoverageConfidenceLevels() {
        let now = start.addingTimeInterval(20 * 86_400)
        let dense = (0..<25).map { start.addingTimeInterval(Double($0) * 86_400) }
        XCTAssertEqual(HistoryInsights.dataCoverage(timestamps: dense, now: now).confidence, .high)

        let sparse = (0..<2).map { start.addingTimeInterval(Double($0) * 86_400) }
        XCTAssertEqual(HistoryInsights.dataCoverage(timestamps: sparse, now: now).confidence, .insufficient)

        XCTAssertEqual(HistoryInsights.dataCoverage(timestamps: []).sampleCount, 0)
    }

    // MARK: - Chart-gap segmentation

    @Test
    func testSegmentsBreaksRunsAtLargeGaps() {
        struct Point { let timestamp: Date }
        let points = [
            Point(timestamp: start),
            Point(timestamp: start.addingTimeInterval(3_600)),
            Point(timestamp: start.addingTimeInterval(30 * 86_400)), // big gap: new run
            Point(timestamp: start.addingTimeInterval(30 * 86_400 + 3_600)),
        ]
        let runs = HistoryInsights.segments(of: points, maxGap: 3 * 86_400, timestamp: \.timestamp)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 2)
        XCTAssertEqual(runs[1].count, 2)
    }

    @Test
    func testSegmentsEmptyInput() {
        struct Point { let timestamp: Date }
        let runs = HistoryInsights.segments(of: [Point](), maxGap: 86_400, timestamp: \.timestamp)
        XCTAssertTrue(runs.isEmpty)
    }

    // MARK: - Bucketing helpers

    @Test
    func testDayWeekMonthBucketsTruncateToPeriodStart() {
        let calendar = utcCalendar
        var components = DateComponents()
        components.year = 2_026; components.month = 3; components.day = 18; components.hour = 14; components.minute = 30
        let date = calendar.date(from: components)!
        let day = HistoryInsights.dayBucket(date, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: day), 0)
        let month = HistoryInsights.monthBucket(date, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: month), 1)
        XCTAssertEqual(calendar.component(.month, from: month), 3)
    }
}
