import Foundation

/// One hour of Open-Meteo's global shortwave radiation, in W/m². Radiation, not panel output:
/// the client has no panel size, tilt or inverter figures, so the app never turns this into kWh.
struct SolarForecastPoint: Equatable, Sendable, Identifiable {
    let time: Date
    let wattsPerSquareMeter: Double

    var id: Date { time }
}

/// The next day or two of radiation at one place. Pure, so the horizon and peak rules are
/// testable without a network or a wall clock.
struct SolarForecast: Equatable, Sendable {
    /// The line shows one day ahead; Open-Meteo returns two so the evening still has a full
    /// tomorrow to draw.
    static let horizon: TimeInterval = 24 * 3_600

    let points: [SolarForecastPoint]

    var isEmpty: Bool { points.isEmpty }

    /// The points from `now` up to `horizon` ahead, oldest first.
    func upcoming(after now: Date, horizon: TimeInterval = SolarForecast.horizon) -> [SolarForecastPoint] {
        let end = now.addingTimeInterval(horizon)
        return points.filter { $0.time >= now && $0.time < end }.sorted { $0.time < $1.time }
    }

    /// The strongest radiation in that window, for the one-line summary. `nil` when the
    /// window has no point, which is also the failure shape the UI leaves empty.
    func peak(after now: Date) -> SolarForecastPoint? {
        upcoming(after: now).max { $0.wattsPerSquareMeter < $1.wattsPerSquareMeter }
    }
}
