import Foundation

/// One hour of Open-Meteo's global shortwave radiation, in W/m². Open-Meteo reports the mean of
/// the hour that ended at each timestamp, so the point keeps the hour it describes rather than
/// the instant the provider stamped it with. Radiation, not panel output: the client has no panel
/// size, tilt or inverter figures, so the app never turns this into kWh of production.
struct SolarForecastPoint: Equatable, Sendable, Identifiable {
    /// Every point covers one hour.
    static let interval: TimeInterval = 3_600

    /// The start of the hour the mean covers.
    let start: Date
    let wattsPerSquareMeter: Double

    var end: Date { start.addingTimeInterval(Self.interval) }
    /// Where a chart readout snaps a pointer to: the middle of the hour, not its edge.
    var midpoint: Date { start.addingTimeInterval(Self.interval / 2) }
    var id: Date { start }
}

/// The next day or two of radiation at one place. Pure, so the window, peak and day-total rules
/// are testable without a network or a wall clock.
struct SolarForecast: Equatable, Sendable {
    /// Open-Meteo returns two calendar days from local midnight, which is the whole outlook the
    /// planner's price chart can ever show (today and tomorrow), so nothing is cut by default.
    static let horizon: TimeInterval = 48 * 3_600

    let points: [SolarForecastPoint]
    /// The zone of the place the radiation was forecast for. Hours are read on that place's clock.
    var timeZone: TimeZone = .current

    var isEmpty: Bool { points.isEmpty }

    /// The hours that have not ended by `now` and begin before `horizon` ahead, oldest first.
    /// The hour running now is included: its mean is the best reading of the sun at this moment.
    func upcoming(after now: Date, horizon: TimeInterval = SolarForecast.horizon) -> [SolarForecastPoint] {
        let limit = now.addingTimeInterval(horizon)
        return points.filter { $0.end > now && $0.start < limit }.sorted { $0.start < $1.start }
    }

    /// The strongest hour in that window, for the one-line summary. `nil` when the window has no
    /// hour, which is also the failure shape the UI leaves empty.
    func peak(after now: Date, horizon: TimeInterval = SolarForecast.horizon) -> SolarForecastPoint? {
        upcoming(after: now, horizon: horizon).max { $0.wattsPerSquareMeter < $1.wattsPerSquareMeter }
    }

    /// Today's and tomorrow's totals on the place's calendar, each nil when that day is incomplete.
    func dayTotals(at now: Date) -> (today: Double?, tomorrow: Double?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        return (dailyTotalKwhPerSquareMeter(containing: now),
                tomorrow.flatMap { dailyTotalKwhPerSquareMeter(containing: $0) })
    }

    /// Radiation that reaches a square metre over the calendar day containing `date`, in kWh/m².
    /// Nil unless the forecast holds every hour from 00:00 to 22:00 of that day: a day with gaps
    /// would understate the total, and the app shows no number rather than a smaller one. The
    /// 23:00 hour is optional because the last day of a complete outlook ends one stamp short of
    /// it, and that hour carries no meaningful sun at the latitudes this runs at. A day that
    /// lacks an hour on the clock, as on a spring-forward Sunday, also gets no total.
    func dailyTotalKwhPerSquareMeter(containing date: Date) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: date)
        let hours = points.filter { calendar.startOfDay(for: $0.start) == day }
        let present = Set(hours.map { calendar.component(.hour, from: $0.start) })
        guard (0...22).allSatisfy(present.contains) else { return nil }
        let wattHours = hours.reduce(0) { $0 + $1.wattsPerSquareMeter * SolarForecastPoint.interval / 3_600 }
        return wattHours / 1_000
    }
}
