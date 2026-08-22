import Foundation
import Testing
@testable import Hisingen

/// Coverage for the round-3 insight helpers: filter-life guesstimate and lifetime
/// cost-per-km. Both are explicitly estimates — the tests pin their honest-failure
/// behaviour (nil until enough data exists) as much as their arithmetic.
struct InsightEstimatesTests {

    private func airRecord(_ id: Int64, daysAgo: Double, filterPercent: Double,
                           now: Date) -> AirQualityRecord {
        AirQualityRecord(id: id, vin: "VIN", timestamp: now.addingTimeInterval(-daysAgo * 86_400),
                         airQualityIndex: nil, particulateMatter25: nil,
                         particulateMatter10: nil, filterRemainingPercent: filterPercent)
    }

    @Test("Filter estimate returns nil before 7 days of history")
    func filterEstimateNeedsAtLeastAWeek() {
        let now = Date()
        let records = [
            airRecord(1, daysAgo: 2, filterPercent: 80, now: now),
            airRecord(2, daysAgo: 0, filterPercent: 79, now: now),
        ]
        #expect(HistoryInsights.filterLifeEstimate(from: records, now: now) == nil)
    }

    @Test("Filter estimate returns nil until measurable decline")
    func filterEstimateNeedsMeasurableDecline() {
        let now = Date()
        // A week apart but only 0.1 points of wear: noise, not signal.
        let records = [
            airRecord(1, daysAgo: 8, filterPercent: 80.0, now: now),
            airRecord(2, daysAgo: 0, filterPercent: 79.9, now: now),
        ]
        #expect(HistoryInsights.filterLifeEstimate(from: records, now: now) == nil)
    }

    @Test("Filter estimate extrapolates linearly from observed rate")
    func filterEstimateExtrapolates() throws {
        let now = Date()
        // 4 points lost over 40 days → 0.1/day → 600 days from 60%.
        let records = [
            airRecord(1, daysAgo: 40, filterPercent: 64, now: now),
            airRecord(2, daysAgo: 0, filterPercent: 60, now: now),
        ]
        let estimate = try #require(HistoryInsights.filterLifeEstimate(from: records, now: now))
        #expect(abs(estimate.percentPerDay - 0.1) < 0.001)
        #expect(abs(estimate.daysRemaining - 600) < 1)
    }

    @Test("Cost per km requires energy, price, and at least 100 km of odometer span")
    func costPerKmGuards() {
        let now = Date()
        #expect(HistoryInsights.costPerKm(totalEnergyKwh: 10, pricePerKwh: 0.30,
                                          odometerPoints: []) == nil)
        #expect(HistoryInsights.costPerKm(totalEnergyKwh: 0, pricePerKwh: 0.30,
                                          odometerPoints: [
            .init(id: 1, timestamp: now.addingTimeInterval(-86_400 * 30), odometerKm: 1000),
            .init(id: 2, timestamp: now, odometerKm: 1500),
        ]) == nil)
    }

    @Test("Cost per km divides tariffed energy by driven distance")
    func costPerKmComputes() throws {
        let now = Date()
        let points = [
            HistoryInsights.OdometerPoint(id: 1, timestamp: now.addingTimeInterval(-86_400 * 30), odometerKm: 1000),
            HistoryInsights.OdometerPoint(id: 2, timestamp: now, odometerKm: 1500),
        ]
        // 100 kWh at 0.30 over 500 km → 0.06 currency/km.
        let value = try #require(HistoryInsights.costPerKm(
            totalEnergyKwh: 100, pricePerKwh: 0.30, odometerPoints: points))
        #expect(abs(value - 0.06) < 0.0005)
    }
}
