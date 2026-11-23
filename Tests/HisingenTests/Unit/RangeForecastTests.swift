import Foundation
import Testing
@testable import Hisingen

struct RangeForecastTests {
    private static let departure = Date(timeIntervalSince1970: 1_800_000_000)

    /// Trips on the exact line consumption = 20 - 0.5 * temperature, so 0 °C is 20 and -10 °C is 25.
    private func trips(count: Int = 20, from coldest: Double = -5, to warmest: Double = 20) -> [TripHistoryEntry] {
        (0..<count).map { index in
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            let temperature = coldest + (warmest - coldest) * fraction
            return TripHistoryEntry(
                id: "t\(index)", vin: "V", startedAt: Self.departure, endedAt: Self.departure.addingTimeInterval(600),
                distanceKm: 12, averageConsumption: 20 - 0.5 * temperature, ambientTemperatureCelsius: temperature,
                startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil)
        }
    }

    private func hourly(celsius: Double, offset: TimeInterval = 0) -> [HourlyTemperature] {
        [HourlyTemperature(time: Self.departure.addingTimeInterval(offset), temperatureCelsius: celsius)]
    }

    private func forecast(trips: [TripHistoryEntry], range: Int? = 300, current: Double? = 5,
                          departure: Date? = RangeForecastTests.departure,
                          hourly: [HourlyTemperature]) -> RangeForecast? {
        RangeForecast.forecast(trips: trips, reportedRangeKm: range, currentTemperatureCelsius: current,
                               departure: departure, hourly: hourly)
    }

    @Test("Colder at departure scales the reported range by the fitted consumption")
    func colderShrinksRange() throws {
        // 5 °C is 17.5 kWh/100 km and -5 °C is 22.5, so the change is +28.571 % and 300 km becomes 233.
        let result = try #require(forecast(trips: trips(), hourly: hourly(celsius: -5)))
        #expect(abs(result.consumptionChangePercent - 28.571) < 0.01)
        #expect(result.rangeKm == 233)
        #expect(result.tripCount == 20)
        #expect(result.temperatureCelsius == -5)
    }

    @Test("Warmer at departure lengthens the range")
    func warmerLengthensRange() throws {
        let result = try #require(forecast(trips: trips(), current: -5, hourly: hourly(celsius: 15)))
        #expect(result.consumptionChangePercent < 0)
        #expect(result.rangeKm > 300)
    }

    @Test("Too few trips give nothing")
    func needsEnoughTrips() {
        #expect(forecast(trips: trips(count: RangeForecast.minimumTrips - 1), hourly: hourly(celsius: -5)) == nil)
        #expect(forecast(trips: trips(count: RangeForecast.minimumTrips), hourly: hourly(celsius: -5)) != nil)
    }

    @Test("Trips driven across a narrow temperature span give nothing")
    func needsTemperatureSpan() {
        #expect(forecast(trips: trips(from: 4, to: 10), hourly: hourly(celsius: 2)) == nil)
    }

    @Test("A line that gets cheaper in the cold is not used")
    func needsConsumptionToRiseInTheCold() {
        let backwards = trips().map {
            TripHistoryEntry(id: $0.id, vin: $0.vin, startedAt: $0.startedAt, endedAt: $0.endedAt,
                             distanceKm: $0.distanceKm,
                             averageConsumption: 15 + 0.3 * ($0.ambientTemperatureCelsius ?? 0),
                             ambientTemperatureCelsius: $0.ambientTemperatureCelsius,
                             startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil)
        }
        #expect(forecast(trips: backwards, hourly: hourly(celsius: -5)) == nil)
    }

    @Test("A temperature far outside what the trips covered is not extrapolated")
    func refusesToExtrapolate() {
        // Trips cover -5 to 20 °C; the margin allows down to -10 °C.
        #expect(forecast(trips: trips(), hourly: hourly(celsius: -10)) != nil)
        #expect(forecast(trips: trips(), hourly: hourly(celsius: -10.5)) == nil)
        #expect(forecast(trips: trips(), current: 26, hourly: hourly(celsius: 0)) == nil)
    }

    @Test("A small difference stays quiet")
    func smallDifferenceIsSilent() {
        // 5 °C against 4 °C is about 2.9 %.
        #expect(forecast(trips: trips(), hourly: hourly(celsius: 4)) == nil)
    }

    @Test("Missing inputs give nothing")
    func missingInputs() {
        #expect(forecast(trips: trips(), range: nil, hourly: hourly(celsius: -5)) == nil)
        #expect(forecast(trips: trips(), range: 0, hourly: hourly(celsius: -5)) == nil)
        #expect(forecast(trips: trips(), current: nil, hourly: hourly(celsius: -5)) == nil)
        #expect(forecast(trips: trips(), departure: nil, hourly: hourly(celsius: -5)) == nil)
        #expect(forecast(trips: trips(), hourly: []) == nil)
    }

    @Test("The forecast hour must be within an hour of the departure")
    func forecastHourMustBeNearTheDeparture() {
        #expect(forecast(trips: trips(), hourly: hourly(celsius: -5, offset: 3_600)) != nil)
        #expect(forecast(trips: trips(), hourly: hourly(celsius: -5, offset: 3_601)) == nil)
    }
}
