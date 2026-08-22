import Foundation
import Testing
@testable import Hisingen

struct HistoryInsightsTests {

    private func sample(_ id: Int64, minutesAfterStart: Double, soc: Double,
                        powerKw: Double?, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> HistoricalChargingSample {
        HistoricalChargingSample(
            id: id, sessionId: "session", vin: "VIN", timestamp: start.addingTimeInterval(minutesAfterStart * 60),
            soc: soc, powerKw: powerKw, voltageVolts: nil, currentAmps: nil, chargingType: nil
        )
    }

    private func telemetry(_ id: Int64, daysAfterStart: Double, odometerKm: Double?,
                           consumption: Double?,
                           start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> HistoricalTelemetryRecord {
        HistoricalTelemetryRecord(
            id: id, vin: "VIN", timestamp: start.addingTimeInterval(daysAfterStart * 86_400),
            odometerKm: odometerKm, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: consumption, ambientTemperatureCelsius: nil,
            latitude: nil, longitude: nil
        )
    }

    // MARK: - Charging curve

    @Test
    func testChargingCurveEmptyInput() {
        XCTAssertTrue(HistoryInsights.chargingCurve(from: []).isEmpty)
    }

    @Test
    func testChargingCurveSortsChronologicallyAndKeepsPower() {
        let curve = HistoryInsights.chargingCurve(from: [
            sample(2, minutesAfterStart: 30, soc: 50, powerKw: 7.2),
            sample(1, minutesAfterStart: 0, soc: 40, powerKw: 7.4),
            sample(3, minutesAfterStart: 60, soc: 60, powerKw: nil),
        ])
        XCTAssertEqual(curve.map(\.id), [1, 2, 3])
        XCTAssertEqual(curve.first?.soc, 40)
        XCTAssertEqual(curve.last?.powerKw, nil)
    }

    @Test
    func testChargingCurveDropsImpossibleReadings() {
        let curve = HistoryInsights.chargingCurve(from: [
            sample(1, minutesAfterStart: 0, soc: 40, powerKw: 7),
            sample(2, minutesAfterStart: 10, soc: 0, powerKw: 7),      // zero SoC dropped
            sample(3, minutesAfterStart: 20, soc: 140, powerKw: 7),    // >100% dropped
            sample(4, minutesAfterStart: 30, soc: 55, powerKw: 900),   // absurd power dropped
            sample(5, minutesAfterStart: 40, soc: 60, powerKw: 7),
        ])
        XCTAssertEqual(curve.map(\.soc), [40, 60])
    }

    @Test
    func testChargingCurveDownsamplingKeepsFirstAndLastShape() {
        let samples = (0..<1_000).map { index in
            sample(Int64(index + 1), minutesAfterStart: Double(index), soc: Double(index % 100) + 1, powerKw: 11)
        }
        let curve = HistoryInsights.chargingCurve(from: samples, maximumPoints: 120)
        XCTAssertLessThanOrEqual(curve.count, 120)
        XCTAssertEqual(curve.first?.soc, 1)
        XCTAssertEqual(curve.last?.soc, 100)
        // Timestamps stay strictly non-decreasing after downsampling.
        let timestamps = curve.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    @Test
    func testChargingCurveSmallInputIsNotResampled() {
        let samples = [
            sample(1, minutesAfterStart: 0, soc: 20, powerKw: 6.6),
            sample(2, minutesAfterStart: 15, soc: 35, powerKw: 6.6),
        ]
        let curve = HistoryInsights.chargingCurve(from: samples, maximumPoints: 160)
        XCTAssertEqual(curve.count, 2)
    }

    // MARK: - Efficiency trend

    @Test
    func testEfficiencyTrendFiltersOutOfBoundsReadings() {
        let points = HistoryInsights.efficiencyTrend(from: [
            telemetry(1, daysAfterStart: 0, odometerKm: nil, consumption: 18),
            telemetry(2, daysAfterStart: 1, odometerKm: nil, consumption: 0.4),   // coasting glitch
            telemetry(3, daysAfterStart: 2, odometerKm: nil, consumption: 120),   // data error
            telemetry(4, daysAfterStart: 3, odometerKm: nil, consumption: nil),
            telemetry(5, daysAfterStart: 4, odometerKm: nil, consumption: 22),
        ])
        XCTAssertEqual(points.map(\.kwhPer100Km), [18, 22])
    }

    @Test
    func testEfficiencyTrendIsOldestFirstAndCollapsesDuplicates() {
        let points = HistoryInsights.efficiencyTrend(from: [
            telemetry(1, daysAfterStart: 2, odometerKm: nil, consumption: 21.0),
            telemetry(2, daysAfterStart: 0, odometerKm: nil, consumption: 21.0),
            // 21.03, not 21.05: exactly 0.05 away from 21.0 sits on the collapse threshold, and
            // `21.0 - 21.05` isn't exactly 0.05 in IEEE 754 double precision (it lands a hair
            // above), which made this test fail nondeterministically-looking on the exact
            // boundary. A value clearly inside the tolerance tests the same behavior reliably.
            telemetry(3, daysAfterStart: 0.2, odometerKm: nil, consumption: 21.03), // same reading, <6h later — collapses into #2
            telemetry(4, daysAfterStart: 3, odometerKm: nil, consumption: 23.4),
        ])
        // #2 and #3 collapse into one point (close in both value and time); #1 keeps its own
        // point even though its value matches #2 — it's 2 days later, well outside the
        // collapse window, so it's a genuinely separate reading worth its own point on the
        // chart rather than a duplicate poll of the same one. #4 is simply a different value.
        XCTAssertEqual(points.count, 3)
        XCTAssertTrue(points.first!.timestamp < points.last!.timestamp)
    }

    @Test
    func testAverageEfficiency() {
        XCTAssertNil(HistoryInsights.averageEfficiency(of: []))
        let points = [
            HistoryInsights.EfficiencyPoint(id: Int64(1), timestamp: Date(), kwhPer100Km: 10),
            HistoryInsights.EfficiencyPoint(id: Int64(2), timestamp: Date(), kwhPer100Km: 30),
        ]
        XCTAssertEqual(HistoryInsights.averageEfficiency(of: points) ?? 0, 20, accuracy: 0.001)
    }

    // MARK: - Odometer trend

    @Test
    func testOdometerTrendDropsNonPositiveValues() {
        let points = HistoryInsights.odometerTrend(from: [
            telemetry(1, daysAfterStart: 0, odometerKm: nil, consumption: nil),
            telemetry(2, daysAfterStart: 1, odometerKm: 0, consumption: nil),
            telemetry(3, daysAfterStart: 2, odometerKm: 1_500, consumption: nil),
        ])
        XCTAssertEqual(points.map(\.odometerKm), [1_500])
    }

    @Test
    func testOdometerTrendSkipsImpossibleReset() {
        let points = HistoryInsights.odometerTrend(from: [
            telemetry(1, daysAfterStart: 0, odometerKm: 10_000, consumption: nil),
            telemetry(2, daysAfterStart: 1, odometerKm: 400, consumption: nil),  // rollover glitch
            telemetry(3, daysAfterStart: 2, odometerKm: 10_050, consumption: nil),
        ])
        XCTAssertEqual(points.map(\.odometerKm), [10_000, 10_050])
    }

    @Test
    func testDistanceCovered() {
        XCTAssertNil(HistoryInsights.distanceCovered(from: []))
        let points = [
            HistoryInsights.OdometerPoint(id: Int64(1), timestamp: Date().addingTimeInterval(-3600), odometerKm: 100),
            HistoryInsights.OdometerPoint(id: Int64(2), timestamp: Date(), odometerKm: 250),
        ]
        XCTAssertEqual(HistoryInsights.distanceCovered(from: points) ?? 0, 150, accuracy: 0.001)
    }
}
