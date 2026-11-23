import Foundation
import Testing
@testable import Hisingen

/// How much of a planned charge the reader's own panels could supply. The figure describes the
/// window the planner chose; it never moves it, and it is nil whenever it would be a guess.
@Suite("Solar coverage of a charge window")
struct SolarCoverageTests {
    private static func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// Hours starting at 10:00Z, each with the given tilted radiation in W/m² (nil leaves it out).
    private func forecast(tilted: [Double?]) -> SolarForecast {
        let start = Self.instant("2026-11-22T10:00:00Z")
        return SolarForecast(points: tilted.enumerated().map { index, value in
            SolarForecastPoint(start: start.addingTimeInterval(TimeInterval(index) * 3_600),
                               wattsPerSquareMeter: 300, tiltedWattsPerSquareMeter: value)
        }, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// 5 kWp at 1000 W/m² on the panels: 5 x 1.0 x 0.8 = 4 kW.
    private let array = SolarArray(kwp: 5, tiltDegrees: 35, azimuthDegrees: 0)!

    private func window(_ from: String, _ to: String) -> DateInterval {
        DateInterval(start: Self.instant(from), end: Self.instant(to))
    }

    @Test
    func panelsThatMatchTheChargeCoverItAll() {
        // 4 kW for two hours is 8 kWh, the whole charge, on a charger that can take it.
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, 1000, 1000]), array: array,
            window: window("2026-11-22T10:00:00Z", "2026-11-22T12:00:00Z"), chargerKw: 7.4, energyKwh: 8)

        #expect(share == 1)
    }

    @Test
    func theChargerCapsWhatEachHourCanContribute() {
        // The panels make 4 kW but the charger takes 3, so two hours supply 6 kWh of a 12 kWh charge.
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, 1000]), array: array,
            window: window("2026-11-22T10:00:00Z", "2026-11-22T12:00:00Z"), chargerKw: 3, energyKwh: 12)

        #expect(share == 0.5)
    }

    @Test
    func theShareNeverExceedsTheWholeCharge() {
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, 1000]), array: array,
            window: window("2026-11-22T10:00:00Z", "2026-11-22T12:00:00Z"), chargerKw: 22, energyKwh: 2)

        #expect(share == 1)
    }

    @Test
    func aWindowThatStartsMidHourCountsOnlyItsOwnMinutes() {
        // 10:30 to 12:00 is 1.5 hours: half an hour of 4 kW, then an hour of 2 kW (500 W/m²).
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, 500]), array: array,
            window: window("2026-11-22T10:30:00Z", "2026-11-22T12:00:00Z"), chargerKw: 7.4, energyKwh: 8)

        #expect(share == (4 * 0.5 + 2 * 1.0) / 8)
    }

    @Test
    func nothingIsClaimedWhenTheForecastDoesNotCoverTheWholeWindow() {
        // The forecast ends at 12:00; the window runs to 13:00.
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, 1000]), array: array,
            window: window("2026-11-22T11:00:00Z", "2026-11-22T13:00:00Z"), chargerKw: 7.4, energyKwh: 8)

        #expect(share == nil)
    }

    @Test
    func nothingIsClaimedWhenAnHourInTheWindowHasNoTiltedFigure() {
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [1000, nil]), array: array,
            window: window("2026-11-22T10:00:00Z", "2026-11-22T12:00:00Z"), chargerKw: 7.4, energyKwh: 8)

        #expect(share == nil)
    }

    @Test
    func aMissingFigureOutsideTheWindowDoesNotMatter() {
        let share = SolarCoverage.fraction(
            forecast: forecast(tilted: [nil, 1000]), array: array,
            window: window("2026-11-22T11:00:00Z", "2026-11-22T12:00:00Z"), chargerKw: 7.4, energyKwh: 4)

        #expect(share == 1)
    }

    @Test
    func degenerateInputsAreNothing() {
        let tilted = forecast(tilted: [1000])
        let hour = window("2026-11-22T10:00:00Z", "2026-11-22T11:00:00Z")

        #expect(SolarCoverage.fraction(forecast: tilted, array: array, window: hour, chargerKw: 7.4, energyKwh: 0) == nil)
        #expect(SolarCoverage.fraction(forecast: tilted, array: array, window: hour, chargerKw: 0, energyKwh: 4) == nil)
        #expect(SolarCoverage.fraction(forecast: tilted, array: array, window: hour, chargerKw: .nan, energyKwh: 4) == nil)
        #expect(SolarCoverage.fraction(forecast: tilted, array: array,
                                       window: DateInterval(start: hour.start, duration: 0),
                                       chargerKw: 7.4, energyKwh: 4) == nil)
    }
}
