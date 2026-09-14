import Foundation
import Testing
@testable import Hisingen

struct TemperatureConsumptionSlopeTests {
    private func trip(id: String, temperature: Double, consumption: Double) -> TripHistoryEntry {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return TripHistoryEntry(
            id: id, vin: "TESTVIN0000000001", startedAt: start,
            endedAt: start.addingTimeInterval(1_800), distanceKm: 40,
            averageConsumption: consumption, ambientTemperatureCelsius: temperature,
            startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil)
    }

    @Test
    func quantifiesAColdWeatherPenalty() throws {
        // Consumption rises linearly by 0.15 kWh/100km per degree of cooling — about a
        // 7% penalty per 10 °C against the ~20 kWh/100km median.
        let trips = stride(from: 20.0, through: -10.0, by: -5.0).enumerated().map { index, temperature in
            trip(id: "t\(index)", temperature: temperature,
                 consumption: 18 + (20 - temperature) * 0.15)
        }
        let slope = HistoryInsights.temperatureConsumptionSlope(from: trips)
        let value = try #require(slope)
        #expect(value.observationCount == 7)
        #expect(value.percentPer10DegreesColder > 5)
        #expect(value.percentPer10DegreesColder < 12)
    }

    @Test
    func rejectsTooFewTripsAndAWrongWayFit() {
        let warm = stride(from: 15.0, through: 25.0, by: 1.0).map { temperature in
            trip(id: "w\(Int(temperature))", temperature: temperature, consumption: 18)
        }
        #expect(HistoryInsights.temperatureConsumptionSlope(from: Array(warm.prefix(4))) == nil)

        // Consumption falls as it gets colder: no cold-weather penalty to report.
        let inverted = stride(from: 20.0, through: -10.0, by: -5.0).enumerated().map { index, temperature in
            trip(id: "i\(index)", temperature: temperature,
                 consumption: 18 - (20 - temperature) * 0.15)
        }
        #expect(HistoryInsights.temperatureConsumptionSlope(from: inverted) == nil)
    }
}
