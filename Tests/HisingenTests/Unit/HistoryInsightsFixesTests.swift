import Foundation
import Testing
@testable import Hisingen

/// Regression coverage for History insight edge cases: weekday/weekend day spans, lifetime cost
/// under mixed tariffs, nil-power idle tails, deterministic ties and even-count medians.
struct HistoryInsightsFixesTests {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func trip(_ id: String, at startedAt: Date, distanceKm: Double) -> TripHistoryEntry {
        TripHistoryEntry(
            id: id, vin: "VIN", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20 * 60),
            distanceKm: distanceKm, averageConsumption: nil, ambientTemperatureCelsius: nil,
            startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil
        )
    }

    private func session(_ id: String, energyKwh: Double, estimatedCost: Double? = nil,
                         tariffPricePerKwh: Double? = nil) -> HistoricalChargingSession {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return HistoricalChargingSession(
            id: id, vin: "VIN", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3_600),
            startSoc: 20, endSoc: 60, energyDeliveredKwh: energyKwh, peakPowerKw: 50,
            averagePowerKw: 35, locationName: nil, createdAt: startedAt,
            tariffPricePerKwh: tariffPricePerKwh, estimatedCost: estimatedCost
        )
    }

    // MARK: - Weekday / weekend day spans

    @Test
    func weekdayWeekendCountsEveryCalendarDayInTheSpan() {
        // Monday 5 January to Sunday 18 January 2026: ten weekdays and four weekend days,
        // including the idle stretch between trips.
        let trips = [
            trip("mon", at: utcDate(2_026, 1, 5), distanceKm: 100),
            trip("sat", at: utcDate(2_026, 1, 10), distanceKm: 40),
            trip("fri", at: utcDate(2_026, 1, 16), distanceKm: 60),
            trip("sun", at: utcDate(2_026, 1, 18), distanceKm: 20)
        ]
        let split = HistoryInsights.weekdayWeekendDistance(from: trips, calendar: utcCalendar)
        #expect(split.weekdayDayCount == 10)
        #expect(split.weekendDayCount == 4)
        #expect(split.weekdayKmPerDay == 16)
        #expect(split.weekendKmPerDay == 15)
    }

    @Test
    func weekdayWeekendZeroDaysYieldsZeroPerDay() {
        // A single Saturday has no weekday in its span, so the weekday figure must not divide by zero.
        let trips = [trip("sat", at: utcDate(2_026, 1, 3), distanceKm: 80)]
        let split = HistoryInsights.weekdayWeekendDistance(from: trips, calendar: utcCalendar)
        #expect(split.weekendDayCount == 1)
        #expect(split.weekdayDayCount == 0)
        #expect(split.weekdayKmPerDay == 0)
        #expect(split.weekendKmPerDay == 80)
    }

    @Test
    func weekdayWeekendNoTripsHasNoDays() {
        let split = HistoryInsights.weekdayWeekendDistance(from: [], calendar: utcCalendar)
        #expect(split.weekdayDayCount == 0)
        #expect(split.weekendDayCount == 0)
        #expect(split.weekdayKmPerDay == 0)
        #expect(split.weekendKmPerDay == 0)
    }

    // MARK: - Lifetime cost per km

    @Test
    func costPerKmSumsResolvedCostAcrossMixedTariffs() throws {
        // Stored cost 20 for 100 kWh, a 0.40/kWh tariff on 50 kWh (20), and 10 kWh with no price
        // falling back to 0.30 (3). Total 43 over 500 km.
        let sessions = [
            session("stored", energyKwh: 100, estimatedCost: 20),
            session("tariff", energyKwh: 50, tariffPricePerKwh: 0.40),
            session("fallback", energyKwh: 10)
        ]
        let odometer = [
            HistoryInsights.OdometerPoint(id: 1, timestamp: utcDate(2_026, 1, 1), odometerKm: 1_000),
            HistoryInsights.OdometerPoint(id: 2, timestamp: utcDate(2_026, 3, 1), odometerKm: 1_500)
        ]
        let value = try #require(HistoryInsights.costPerKm(
            sessions: sessions, fallbackPricePerKwh: 0.30, odometerPoints: odometer))
        #expect(abs(value - 0.086) < 0.0005)

        // The flat-rate overload prices all 160 kWh at the fallback, which the session-based figure must not do.
        let flat = try #require(HistoryInsights.costPerKm(
            totalEnergyKwh: 160, pricePerKwh: 0.30, odometerPoints: odometer))
        #expect(abs(flat - 0.096) < 0.0005)
    }

    @Test
    func costPerKmSessionsRespectsDistanceGuard() {
        let odometer = [
            HistoryInsights.OdometerPoint(id: 1, timestamp: utcDate(2_026, 1, 1), odometerKm: 1_000),
            HistoryInsights.OdometerPoint(id: 2, timestamp: utcDate(2_026, 1, 5), odometerKm: 1_050)
        ]
        #expect(HistoryInsights.costPerKm(sessions: [session("a", energyKwh: 10, estimatedCost: 5)],
                                          fallbackPricePerKwh: 0.3, odometerPoints: odometer) == nil)
    }

    // MARK: - Idle tail

    @Test
    func idleTailDoesNotTreatMissingPowerAsIdle() throws {
        // The sample with nil power sits in the trailing run at or above 95%. It is not a
        // confirmed trickle, so the tail starts at the first sample that reports low power.
        let curve = [
            HistoryInsights.ChargingCurvePoint(id: 1, timestamp: utcDate(2_026, 1, 1, hour: 10), soc: 90, powerKw: 10, voltageVolts: nil, currentAmps: nil),
            HistoryInsights.ChargingCurvePoint(id: 2, timestamp: utcDate(2_026, 1, 1, hour: 11), soc: 96, powerKw: nil, voltageVolts: nil, currentAmps: nil),
            HistoryInsights.ChargingCurvePoint(id: 3, timestamp: utcDate(2_026, 1, 1, hour: 12), soc: 97, powerKw: 0.5, voltageVolts: nil, currentAmps: nil),
            HistoryInsights.ChargingCurvePoint(id: 4, timestamp: utcDate(2_026, 1, 1, hour: 13), soc: 98, powerKw: 0.2, voltageVolts: nil, currentAmps: nil)
        ]
        let tail = try #require(HistoryInsights.idleTailDuration(from: curve))
        #expect(tail == 3_600)
    }

    @Test
    func idleTailIsNilWhenLastSampleHasNoPower() {
        let curve = [
            HistoryInsights.ChargingCurvePoint(id: 1, timestamp: utcDate(2_026, 1, 1, hour: 10), soc: 97, powerKw: 0.5, voltageVolts: nil, currentAmps: nil),
            HistoryInsights.ChargingCurvePoint(id: 2, timestamp: utcDate(2_026, 1, 1, hour: 11), soc: 98, powerKw: nil, voltageVolts: nil, currentAmps: nil)
        ]
        #expect(HistoryInsights.idleTailDuration(from: curve) == nil)
    }

    // MARK: - Deterministic ties

    @Test
    func chargingTypeTieGoesToEarliestSample() {
        // One AC and one DC sample, no peak fallback in play. The earlier sample wins, regardless of input order.
        let dcFirst = [
            HistoricalChargingSample(id: 1, sessionId: "s", vin: "VIN", timestamp: utcDate(2_026, 1, 1, hour: 10), soc: 40, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: "dc"),
            HistoricalChargingSample(id: 2, sessionId: "s", vin: "VIN", timestamp: utcDate(2_026, 1, 1, hour: 11), soc: 50, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: "ac")
        ]
        #expect(HistoryInsights.chargingType(from: dcFirst, peakPowerKw: 10) == .dc)
        #expect(HistoryInsights.chargingType(from: Array(dcFirst.reversed()), peakPowerKw: 10) == .dc)

        let acFirst = [
            HistoricalChargingSample(id: 1, sessionId: "s", vin: "VIN", timestamp: utcDate(2_026, 1, 1, hour: 10), soc: 40, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: "ac"),
            HistoricalChargingSample(id: 2, sessionId: "s", vin: "VIN", timestamp: utcDate(2_026, 1, 1, hour: 11), soc: 50, powerKw: 10, voltageVolts: nil, currentAmps: nil, chargingType: "dc")
        ]
        #expect(HistoryInsights.chargingType(from: acFirst, peakPowerKw: 10) == .ac)
    }

    @Test
    func mostUsedCommandTieGoesToEarliestExecution() {
        let records = [
            RemoteCommandAuditRecord(id: "late", vin: "VIN", command: "lock", status: "completed",
                                     executedAt: utcDate(2_026, 1, 2), durationMs: nil, errorMessage: nil),
            RemoteCommandAuditRecord(id: "early", vin: "VIN", command: "horn", status: "completed",
                                     executedAt: utcDate(2_026, 1, 1), durationMs: nil, errorMessage: nil)
        ]
        #expect(HistoryInsights.commandStatistics(from: records).mostUsedCommand == "horn")
        #expect(HistoryInsights.commandStatistics(from: Array(records.reversed())).mostUsedCommand == "horn")
    }

    // MARK: - Peak anomaly median

    @Test
    func sessionPeakAnomalyUsesMeanOfMiddlePairForEvenCount() {
        // Four priors: the median is (50 + 60) / 2 = 55, so the derate threshold is 33 kW.
        // The old upper-middle pick (60) would have put it at 36 kW and flagged 34 kW.
        let priors = [40.0, 50.0, 60.0, 70.0]
        #expect(HistoryInsights.sessionPeakAnomaly(currentPeakKw: 34, priorPeaksKwAtSameLocation: priors) == false)
        #expect(HistoryInsights.sessionPeakAnomaly(currentPeakKw: 32, priorPeaksKwAtSameLocation: priors) == true)
    }
}
