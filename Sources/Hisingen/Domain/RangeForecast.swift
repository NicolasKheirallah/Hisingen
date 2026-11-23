import Foundation

/// The car's range at the next departure's forecast temperature, from what its own trips say
/// about cold. The line is the least-squares fit through the recorded (outside °C, kWh/100 km)
/// pairs that the History tab already uses to normalise consumption. The reported range is scaled
/// by how much that line says consumption differs between now and the departure hour, so the
/// figure answers "how much will cold cost me" and never claims an absolute range of its own.
///
/// Nil whenever the trips cannot back a number: too few of them, too narrow a temperature span,
/// a line that does not rise as it gets colder, a temperature the trips never covered, or a
/// difference too small to be worth a line.
struct RangeForecast: Equatable, Sendable {
    /// Fewer recorded trips than this and the fitted line is noise.
    static let minimumTrips = 15
    /// The trips must have been driven across at least this many degrees, or the slope says nothing.
    static let minimumSpanCelsius = 8.0
    /// How far outside the temperatures the trips cover the fit may be read. Beyond this the line
    /// is an extrapolation, and consumption bends upward in deep cold.
    static let extrapolationMargin = 5.0
    /// Differences under this stay quiet: the fit is not that precise.
    static let reportingThresholdPercent = 5.0
    /// A change this large means the fit and the reading disagree about the world, not that the
    /// car will use that much more energy.
    static let implausiblePercent = 50.0
    /// The nearest forecast hour must be this close to the departure, as the departure advice requires.
    static let forecastTolerance: TimeInterval = 3_600

    let departure: Date
    /// The forecast outside temperature at the departure hour.
    let temperatureCelsius: Double
    /// Energy per kilometre at the departure against now, in percent. Positive means colder.
    let consumptionChangePercent: Double
    /// The reported range scaled by that change, in kilometres.
    let rangeKm: Int
    let tripCount: Int

    static func forecast(trips: [TripHistoryEntry],
                         reportedRangeKm: Int?,
                         currentTemperatureCelsius: Double?,
                         departure: Date?,
                         hourly: [HourlyTemperature]) -> RangeForecast? {
        guard let reportedRangeKm, reportedRangeKm > 0,
              let currentTemperatureCelsius, currentTemperatureCelsius.isFinite,
              let departure,
              let reading = hourly.min(by: {
                  abs($0.time.timeIntervalSince(departure)) < abs($1.time.timeIntervalSince(departure))
              }),
              abs(reading.time.timeIntervalSince(departure)) <= forecastTolerance,
              reading.temperatureCelsius.isFinite else { return nil }

        let points = HistoryInsights.temperatureConsumptionPoints(from: trips)
        guard points.count >= minimumTrips,
              let coldest = points.map(\.temperature).min(),
              let warmest = points.map(\.temperature).max(),
              warmest - coldest >= minimumSpanCelsius,
              let fit = HistoryInsights.linearFit(points.map { ($0.temperature, $0.consumption) }),
              fit.slope < 0 else { return nil }

        let covered = (coldest - extrapolationMargin)...(warmest + extrapolationMargin)
        let forecastTemperature = reading.temperatureCelsius
        guard covered.contains(forecastTemperature), covered.contains(currentTemperatureCelsius) else { return nil }

        func fitted(_ temperature: Double) -> Double { fit.intercept + fit.slope * temperature }
        let now = fitted(currentTemperatureCelsius)
        let then = fitted(forecastTemperature)
        guard now > 0, then > 0 else { return nil }

        let change = (then / now - 1) * 100
        guard abs(change) >= reportingThresholdPercent, abs(change) <= implausiblePercent else { return nil }
        let range = Int((Double(reportedRangeKm) * now / then).rounded())
        guard range > 0 else { return nil }
        return RangeForecast(departure: departure,
                             temperatureCelsius: forecastTemperature,
                             consumptionChangePercent: change,
                             rangeKm: range,
                             tripCount: points.count)
    }
}
