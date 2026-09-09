import Foundation
import Testing
@testable import Hisingen

struct HistoricalRangeTests {
    private func record(_ id: Int64, consumption: Double, unit: String? = "kwh", vin: String = "VIN") -> HistoricalTelemetryRecord {
        HistoricalTelemetryRecord(id: id, vin: vin, timestamp: Date(timeIntervalSince1970: Double(id) * 86_400),
                                  odometerKm: nil, tripManualKm: nil, tripAutomaticKm: nil,
                                  averageConsumption: consumption, averageConsumptionUnit: unit,
                                  ambientTemperatureCelsius: nil, latitude: nil, longitude: nil)
    }

    @Test func estimatesFromElectricConsumptionAndExcludesOtherVehiclesAndUnits() throws {
        let records = [record(1, consumption: 15), record(2, consumption: 20), record(3, consumption: 25),
                       record(4, consumption: 5, unit: "l"), record(5, consumption: 5, unit: nil),
                       record(6, consumption: 5, vin: "OTHER")]
        let estimate = try #require(HistoryInsights.historicalRange(from: records, vin: "VIN",
                                                                   usableCapacityKwh: 60, batteryPercentage: 50))
        #expect(estimate.typicalKm == 150)
        #expect(estimate.shortestKm == 120)
        #expect(estimate.longestKm == 200)
        #expect(estimate.observationCount == 3)
    }

    @Test func rejectsSparseOrInvalidInputs() {
        let records = [record(1, consumption: 15), record(2, consumption: 20)]
        #expect(HistoryInsights.historicalRange(from: records, vin: "VIN", usableCapacityKwh: 60, batteryPercentage: 50) == nil)
        #expect(HistoryInsights.historicalRange(from: records, vin: "VIN", usableCapacityKwh: .nan, batteryPercentage: 50) == nil)
        #expect(HistoryInsights.historicalRange(from: records, vin: "VIN", usableCapacityKwh: 60, batteryPercentage: 110) == nil)
    }
}
