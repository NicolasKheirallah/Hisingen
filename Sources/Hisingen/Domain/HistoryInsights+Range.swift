import Foundation

extension HistoryInsights {
    struct HistoricalRangeEstimate: Equatable {
        let typicalKm: Double
        let shortestKm: Double
        let longestKm: Double
        let observationCount: Int
    }

    static func historicalRange(from records: [HistoricalTelemetryRecord], vin: String,
                                usableCapacityKwh: Double, batteryPercentage: Double) -> HistoricalRangeEstimate? {
        guard usableCapacityKwh.isFinite, usableCapacityKwh > 0,
              batteryPercentage.isFinite, (0...100).contains(batteryPercentage) else { return nil }
        // Older rows without a unit cannot distinguish electric consumption from fuel.
        let electricRecords = records.filter { $0.vin == vin && $0.averageConsumptionUnit == "kwh" }
        let points = efficiencyTrend(from: electricRecords)
        guard points.count >= 3, let first = points.first, let last = points.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 86_400 else { return nil }
        let consumption = points.map(\.kwhPer100Km)
        guard let median = Statistics.median(consumption), let minimum = consumption.min(),
              let maximum = consumption.max(), minimum > 0 else { return nil }
        let energyTimes100 = usableCapacityKwh * batteryPercentage
        return HistoricalRangeEstimate(typicalKm: energyTimes100 / median,
                                       shortestKm: energyTimes100 / maximum,
                                       longestKm: energyTimes100 / minimum,
                                       observationCount: points.count)
    }
}
