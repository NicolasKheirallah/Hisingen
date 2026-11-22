import Foundation

/// Weather advice for the next scheduled departure. Compares the hourly forecast at the
/// departure with the climate timers the car will run before leaving. The departure comes
/// from the car's own departure timers, or from the calendar preconditioning schedule when
/// the caller knows its next event; the earliest upcoming time wins. Nil when no departure
/// is scheduled, when the forecast does not cover that time, or when nothing needs saying.
struct DepartureWeatherAdvice: Equatable, Sendable {
    /// A climate timer this close before departure is taken to clear the glass in time.
    static let coverageLead: TimeInterval = 2 * 3_600
    /// The nearest forecast hour must be this close to the departure, or the advice is dropped.
    static let forecastTolerance: TimeInterval = 3_600
    static let frostThreshold = 0.0
    static let coldBatteryThreshold = -5.0
    /// Gusts from this speed make the departure hour windy: the Beaufort scale's strong
    /// breeze begins near 39 km/h, and gusts reach it before the mean wind does.
    static let windyThresholdKmh = 40.0

    let departure: Date
    let temperatureCelsius: Double
    /// Freezing at departure and no climate timer runs early enough to clear the windows.
    let needsClimateTimer: Bool
    /// Cold enough that the battery slows DC charging.
    let coldBattery: Bool
    /// Precipitation at the departure hour, and no climate timer covering it.
    let wet: Bool
    /// Gusts (or mean wind, when gusts are absent) at the strong-breeze line, uncovered.
    let windy: Bool
    /// The departure hour's wind and precipitation, for the caller to quote.
    let windSpeedKmh: Double?
    let windGustsKmh: Double?
    let precipitationMm: Double?

    static func advice(schedules: [VehicleSchedule],
                       climateTimers: [VehicleSchedule],
                       calendarDeparture: Date? = nil,
                       forecast: [HourlyTemperature],
                       now: Date = Date(),
                       calendar: Calendar = .current) -> DepartureWeatherAdvice? {
        let next = ([calendarDeparture].compactMap { $0 }
                    + schedules
                        .filter { $0.kind == .departure && $0.isActive }
                        .compactMap { ScheduleOccurrence.next(of: $0, after: now, calendar: calendar) })
            .min()
        guard let departure = next,
              let reading = forecast.min(by: { abs($0.time.timeIntervalSince(departure)) < abs($1.time.timeIntervalSince(departure)) }),
              abs(reading.time.timeIntervalSince(departure)) <= forecastTolerance else { return nil }

        let cold = reading.temperatureCelsius <= frostThreshold
        let wet = (reading.precipitationMm ?? 0) > 0
        let windy = max(reading.windGustsKmh ?? 0, reading.windSpeedKmh ?? 0) >= windyThresholdKmh
        guard cold || wet || windy else { return nil }

        let covered = climateTimers.contains { timer in
            guard timer.kind == .climate, timer.isActive,
                  let start = ScheduleOccurrence.next(of: timer, after: departure.addingTimeInterval(-coverageLead - 1), calendar: calendar)
            else { return false }
            return start <= departure
        }
        let advice = DepartureWeatherAdvice(
            departure: departure,
            temperatureCelsius: reading.temperatureCelsius,
            needsClimateTimer: cold && !covered,
            coldBattery: reading.temperatureCelsius <= coldBatteryThreshold,
            wet: wet && !covered,
            windy: windy && !covered,
            windSpeedKmh: reading.windSpeedKmh,
            windGustsKmh: reading.windGustsKmh,
            precipitationMm: reading.precipitationMm
        )
        return advice.needsClimateTimer || advice.coldBattery || advice.wet || advice.windy ? advice : nil
    }
}

/// The next time a timer starts after a given instant. Repeating timers only count on the
/// weekdays they list, and a timer with no weekdays and no one-shot date has no known next
/// start, so it is skipped rather than assumed to be daily.
enum ScheduleOccurrence {
    static func next(of schedule: VehicleSchedule, after now: Date, calendar: Calendar) -> Date? {
        guard let hour = schedule.startHour, let minute = schedule.startMinute else { return nil }

        if let oneShot = schedule.oneShotDate {
            guard let when = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                           of: calendar.startOfDay(for: oneShot)),
                  when > now else { return nil }
            return when
        }

        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let when = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  when > now else { continue }
            // Calendar weekdays run Sunday = 1; VehicleWeekday runs Monday = 1 ... Sunday = 7.
            let calendarWeekday = calendar.component(.weekday, from: day)
            let vehicleWeekday = calendarWeekday == 1 ? 7 : calendarWeekday - 1
            if schedule.weekdays.contains(where: { $0.rawValue == vehicleWeekday }) {
                return when
            }
        }
        return nil
    }
}
