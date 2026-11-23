import EventKit
import SwiftUI

struct NowWeatherButton: View {
    let state: VehicleState
    let weather: VehicleWeather

    @Environment(\.preferencesStore) private var preferences
    @State private var showsDetails = false

    private var symbol: String {
        switch weather.condition?.lowercased() {
        case "clear": "sun.max"
        case "overcast", "cloudy": "cloud"
        case "fog": "cloud.fog"
        case "drizzle": "cloud.drizzle"
        case "rain", "rain showers": "cloud.rain"
        case "freezing rain", "freezing drizzle": "cloud.sleet"
        case "snow", "snow grains", "snow showers": "cloud.snow"
        case "thunderstorm": "cloud.bolt.rain"
        default: "cloud.sun"
        }
    }

    /// The figure the symbol stands for, so the reader does not have to open the popover for it.
    private var temperatureText: String? {
        weather.temperatureCelsius.map { Format.temperature(celsius: $0, unit: preferences.temperatureUnit) }
    }

    private var summary: String {
        let condition = weather.condition.flatMap { $0.isEmpty ? nil : L10n.text($0) }
        let temperature = weather.temperatureCelsius.map {
            Format.temperature(celsius: $0, unit: preferences.temperatureUnit)
        }
        let values = [condition, temperature].compactMap { $0 }
        let context = state.hasLastKnownWeather ? [L10n.text("Last known readings")] : []
        return (context + values).joined(separator: " · ")
    }

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .hisType(.title)
                if let temperatureText {
                    Text(temperatureText)
                        .hisType(.subhead)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(HisingenTheme.inkMuted)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(L10n.text("Ambient Conditions"))
        .accessibilityValue(summary)
        .help(summary.isEmpty ? L10n.text("Ambient Conditions") : summary)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            NowWeatherReadout(state: state)
                .frame(width: 310)
        }
    }
}

@MainActor
struct NowWeatherReadout: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.dynamicTypeSize) private var typeSize
    /// One store while the popover is open, the same arrangement the calendar settings card uses.
    @State private var eventStore = EKEventStore()
    @State private var calendarDeparture: Date?
    @State private var calendarTask: Task<Void, Never>?

    private struct Reading {
        let label: String
        let value: String
        var isPrimary = false
    }

    var body: some View {
        if let weather = state.weather, weather.hasCurrentConditions {
            let readings = readings(for: weather)
            Card(compact: true) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeaderWithAccessory(
                        heading: CardHeader(symbol: "cloud.sun", title: L10n.text("Ambient Conditions"), color: HisingenTheme.ink)
                    ) {
                        observation(weather.timestamp)
                    }
                    PanelRule()
                    if typeSize.isAccessibilitySize {
                        stackedReadings(readings)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                ForEach(readings, id: \.label) { reading in
                                    figure(reading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            stackedReadings(readings)
                        }
                    }
                    if let departureAdviceLine {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(departureAdviceLine)
                                .hisType(.micro)
                                .foregroundStyle(HisingenTheme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            InformationButton(
                                message: L10n.text("The line appears when the departure hour is at or below 0 °C, has any rain or snow, or the wind or gusts reach 40 km/h. A climate timer that starts within two hours before the departure counts as covering it, and then the line stays quiet.")
                                    + " " + L10n.text("It also appears for wet roads at or below 1 °C, which a timer cannot fix, and when the air reaches 28 °C."),
                                subject: L10n.text("Departure"))
                        }
                    }
                }
            }
            .task { refreshCalendarDeparture() }
        }
    }

    private func readings(for weather: VehicleWeather) -> [Reading] {
        var readings: [Reading] = []
        if let temperature = weather.temperatureCelsius {
            readings.append(Reading(label: L10n.text("Outside Temperature"),
                                    value: Format.temperature(celsius: temperature, unit: preferences.temperatureUnit),
                                    isPrimary: true))
        }
        if let condition = weather.condition, !condition.isEmpty {
            readings.append(Reading(label: L10n.text("Condition"), value: L10n.text(condition)))
        }
        if let feelsLike = weather.apparentTemperatureCelsius {
            readings.append(Reading(label: L10n.text("Feels Like"),
                                    value: Format.temperature(celsius: feelsLike, unit: preferences.temperatureUnit)))
        }
        if let humidity = weather.relativeHumidity {
            readings.append(Reading(label: L10n.text("Humidity"), value: Format.percent(Double(humidity))))
        }
        if let wind = weather.windSpeedKmh {
            readings.append(Reading(label: L10n.text("Wind"),
                                    value: Format.speed(kmH: Int(wind.rounded()), unit: preferences.distanceUnit)))
        }
        // Gusts only earn their own figure when they stand clear of the mean wind.
        if let gusts = weather.windGustsKmh, gusts > (weather.windSpeedKmh ?? 0) {
            readings.append(Reading(label: L10n.text("Gusts"),
                                    value: Format.speed(kmH: Int(gusts.rounded()), unit: preferences.distanceUnit)))
        }
        if let precipitation = weather.precipitationMm {
            readings.append(Reading(label: L10n.text("Precipitation"), value: Format.number(precipitation) + " mm"))
        }
        return readings
    }

    /// One line of climate timing advice before the next departure the app can name: the
    /// calendar preconditioning schedule's next event, or the car's own departure timers.
    /// Silent when the forecast or the departure time is missing, when the hour is calm and
    /// dry, or when a climate timer the car will run already covers it.
    private var departureAdviceLine: String? {
        guard let advice = DepartureWeatherAdvice.advice(
            schedules: state.energy.schedules,
            climateTimers: state.climateTimers,
            calendarDeparture: calendarDeparture,
            forecast: state.weather?.hourlyTemperatures ?? []
        ) else { return nil }
        if advice.icyRoad {
            return L10n.format(
                "Icy roads possible at %@ (%@).",
                Format.shortTime(date: advice.departure),
                Format.temperature(celsius: advice.temperatureCelsius, unit: preferences.temperatureUnit, decimals: 0)
            )
        }
        if advice.needsClimateTimer {
            return L10n.format(
                "Frost forecast at %@ (%@). A climate timer would clear the windows.",
                Format.shortTime(date: advice.departure),
                Format.temperature(celsius: advice.temperatureCelsius, unit: preferences.temperatureUnit, decimals: 0)
            )
        }
        if advice.wet, let snowfall = advice.snowfallCm {
            return L10n.format(
                "Snow forecast at %@ (%@ cm). A climate timer would warm the cabin.",
                Format.shortTime(date: advice.departure),
                Format.number(snowfall)
            )
        }
        if advice.wet {
            return L10n.format(
                "Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin.",
                Format.shortTime(date: advice.departure),
                Format.number(advice.precipitationMm ?? 0)
            )
        }
        if advice.hot {
            return L10n.format(
                "Hot forecast at %@ (%@). A climate timer would cool the cabin.",
                Format.shortTime(date: advice.departure),
                Format.temperature(celsius: advice.temperatureCelsius, unit: preferences.temperatureUnit, decimals: 0)
            )
        }
        if advice.windy {
            let gusts = advice.windGustsKmh ?? advice.windSpeedKmh ?? 0
            return L10n.format(
                "Strong wind forecast at %@ (%@). A climate timer would warm the cabin.",
                Format.shortTime(date: advice.departure),
                Format.speed(kmH: Int(gusts.rounded()), unit: preferences.distanceUnit)
            )
        }
        return nil
    }

    /// Snapshots the Sendable calendar inputs and mirrors the controller's next-trigger fetch
    /// off the main thread, the same hand-off the calendar settings card uses. The window is
    /// 48 hours: the forecast the advice draws on only reaches two days.
    private func refreshCalendarDeparture() {
        calendarTask?.cancel()
        guard preferences.calendarPreconditioningEnabled,
              CalendarPreconditioningController.hasCalendarAccess,
              !preferences.calendarPreconditioningCalendarIDs.isEmpty else { return }
        let calendarIDs = preferences.calendarPreconditioningCalendarIDs
        let lead = TimeInterval(preferences.calendarPreconditioningLeadTimeMinutes * 60)
        let fired = Set(preferences.calendarPreconditioningFiredOccurrences.keys)
        nonisolated(unsafe) let store = eventStore
        calendarTask = Task {
            let next = await Task.detached(priority: .utility) { () -> Date? in
                let now = Date()
                let calendars = store.calendars(for: .event).filter {
                    calendarIDs.contains($0.calendarIdentifier)
                }
                guard !calendars.isEmpty else { return nil }
                let predicate = store.predicateForEvents(
                    withStart: now, end: now.addingTimeInterval(48 * 3_600), calendars: calendars)
                return store.events(matching: predicate)
                    .filter { !$0.isAllDay && $0.startDate > now }
                    .compactMap { event -> (Date, Date)? in
                        let key = "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))"
                        guard !fired.contains(key) else { return nil }
                        return (event.startDate, max(event.startDate.addingTimeInterval(-lead), now))
                    }
                    .min { $0.1 < $1.1 }?.0
            }.value
            guard !Task.isCancelled else { return }
            calendarDeparture = next
        }
    }

    private func observation(_ timestamp: Date?) -> some View {
        let time = timestamp.map { "\(L10n.text("Observed")) · \(Format.dateTimeFormatter.string(from: $0))" }
            ?? L10n.text("Reading time unknown")
        return VStack(alignment: .trailing, spacing: 3) {
            Text(time)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
                .monospacedDigit()
            if state.hasLastKnownWeather {
                Text(L10n.text("Last known readings"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.semanticWarning)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.value)
                .hisType(reading.isPrimary ? .displaySmall : .title)
                .foregroundStyle(HisingenTheme.ink)
                .monospacedDigit()
            Text(reading.label)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.label)
        .accessibilityValue(reading.value)
    }

    private func stackedReadings(_ readings: [Reading]) -> some View {
        VStack(spacing: 4) {
            ForEach(readings, id: \.label) { reading in
                KVRow(reading.label, reading.value)
            }
        }
    }
}

private extension VehicleState {
    var hasLastKnownWeather: Bool {
        freshness.isCached || freshness.retainedDataCategories.contains(.vehicleWeather)
    }
}
