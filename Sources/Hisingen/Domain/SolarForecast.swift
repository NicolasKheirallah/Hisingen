import Foundation

/// One hour of Open-Meteo's global shortwave radiation, in W/m². Open-Meteo reports the mean of
/// the hour that ended at each timestamp, so the point keeps the hour it describes rather than
/// the instant the provider stamped it with. Radiation, not panel output: unless the reader types
/// in their own array (`SolarArray`), the client has no panel size, tilt or inverter figures, so
/// the app never turns this into kWh of production.
struct SolarForecastPoint: Equatable, Sendable, Identifiable {
    /// Every point covers one hour.
    static let interval: TimeInterval = 3_600

    /// The start of the hour the mean covers.
    let start: Date
    let wattsPerSquareMeter: Double
    /// Radiation on a plane tilted like the reader's panels, W/m², mean of the same hour. Only
    /// present when the request carried a panel orientation and Open-Meteo answered for that hour;
    /// never filled in from the flat-plane figure.
    var tiltedWattsPerSquareMeter: Double? = nil

    var end: Date { start.addingTimeInterval(Self.interval) }
    /// Where a chart readout snaps a pointer to: the middle of the hour, not its edge.
    var midpoint: Date { start.addingTimeInterval(Self.interval / 2) }
    var id: Date { start }
}

/// The reader's own panel figures, typed into Settings. Hisingen never learns these from a
/// provider or a meter; without them the forecast stays radiation and never becomes kWh.
struct SolarArray: Equatable, Sendable {
    /// Share of the tilted-plane radiation that leaves the inverter as usable power: panel
    /// temperature, wiring, inverter and soiling losses. A typical rooftop system lands between
    /// 0.75 and 0.85. It is one disclosed assumption, applied to every estimate, not a
    /// measurement of the reader's system.
    static let systemEfficiency = 0.8
    static let maximumKwp = 100.0

    let kwp: Double
    /// Panel tilt in degrees, 0 flat to 90 upright.
    let tiltDegrees: Double
    /// Open-Meteo's convention: 0 is south, -90 east, 90 west, ±180 north.
    let azimuthDegrees: Double

    /// Clamps to the ranges the provider accepts. Nil unless the array has a positive size.
    init?(kwp: Double, tiltDegrees: Double, azimuthDegrees: Double) {
        guard kwp.isFinite, tiltDegrees.isFinite, azimuthDegrees.isFinite, kwp > 0 else { return nil }
        self.kwp = min(kwp, Self.maximumKwp)
        self.tiltDegrees = min(max(tiltDegrees, 0), 90)
        self.azimuthDegrees = min(max(azimuthDegrees, -180), 180)
    }

    /// Estimated output for an hour with `tiltedWatts` W/m² on the panel plane, in kW.
    func estimatedKw(tiltedWattsPerSquareMeter tiltedWatts: Double) -> Double {
        kwp * tiltedWatts / 1_000 * Self.systemEfficiency
    }
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
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        return (dailyTotalKwhPerSquareMeter(containing: now),
                tomorrow.flatMap { dailyTotalKwhPerSquareMeter(containing: $0) })
    }

    /// Today's and tomorrow's estimated output for `array`, in kWh, each nil when that day is
    /// incomplete or lacks a tilted-plane figure for any of its hours.
    func dayEstimates(at now: Date, array: SolarArray) -> (today: Double?, tomorrow: Double?) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        return (dailyEstimatedKwh(containing: now, array: array),
                tomorrow.flatMap { dailyEstimatedKwh(containing: $0, array: array) })
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The hours of the calendar day containing `date`, only when the forecast holds every hour
    /// from 00:00 to 22:00: a day with gaps would understate a total, and the app shows no number
    /// rather than a smaller one. The 23:00 hour is optional because the last day of a complete
    /// outlook ends one stamp short of it, and that hour carries no meaningful sun at the
    /// latitudes this runs at. A day that lacks an hour on the clock, as on a spring-forward
    /// Sunday, also gets no total.
    private func completeHours(inDayContaining date: Date) -> [SolarForecastPoint]? {
        let calendar = self.calendar
        let day = calendar.startOfDay(for: date)
        let hours = points.filter { calendar.startOfDay(for: $0.start) == day }
        let present = Set(hours.map { calendar.component(.hour, from: $0.start) })
        return (0...22).allSatisfy(present.contains) ? hours : nil
    }

    /// Radiation that reaches a square metre over the calendar day containing `date`, in kWh/m².
    func dailyTotalKwhPerSquareMeter(containing date: Date) -> Double? {
        guard let hours = completeHours(inDayContaining: date) else { return nil }
        let wattHours = hours.reduce(0) { $0 + $1.wattsPerSquareMeter * SolarForecastPoint.interval / 3_600 }
        return wattHours / 1_000
    }

    /// Estimated output for `array` over the calendar day containing `date`, in kWh.
    func dailyEstimatedKwh(containing date: Date, array: SolarArray) -> Double? {
        guard let hours = completeHours(inDayContaining: date) else { return nil }
        var total = 0.0
        for hour in hours {
            guard let tilted = hour.tiltedWattsPerSquareMeter else { return nil }
            total += array.estimatedKw(tiltedWattsPerSquareMeter: tilted) * SolarForecastPoint.interval / 3_600
        }
        return total
    }
}
