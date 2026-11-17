import SwiftUI

struct NowWeatherButton: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences
    @State private var isShowingDetails = false

    var body: some View {
        if let weather = state.weather, weather.hasCurrentConditions {
            let temperature = weather.temperatureCelsius.map {
                Format.temperature(celsius: $0, unit: preferences.temperatureUnit)
            }
            let condition = weather.condition.flatMap { $0.isEmpty ? nil : L10n.text($0) }
            let freshness = state.hasLastKnownWeather ? L10n.text("Last known readings") : nil
            Button {
                isShowingDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: weatherSymbol(weather.condition))
                        .accessibilityHidden(true)
                    if let temperature {
                        Text(temperature)
                            .monospacedDigit()
                    }
                }
                .hisType(.body, weight: .medium)
                .foregroundStyle(HisingenTheme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 28)
                .background(HisingenTheme.chipFill)
                .fixedSize()
            }
            .buttonStyle(.pressable)
            .help(L10n.text("Ambient Conditions"))
            .accessibilityLabel(L10n.text("Ambient Conditions"))
            .accessibilityValue([temperature, condition, freshness].compactMap { $0 }.joined(separator: ", "))
            .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                NowWeatherReadout(state: state, onClose: { isShowingDetails = false })
                    .frame(width: 320)
                    .padding(.vertical, 8)
                    .background(HisingenTheme.popoverSurface)
            }
        }
    }

    private func weatherSymbol(_ condition: String?) -> String {
        switch condition {
        case "Clear": return "sun.max"
        case "Partly Cloudy": return "cloud.sun"
        case "Overcast": return "cloud"
        case "Fog": return "cloud.fog"
        case "Drizzle", "Freezing Drizzle": return "cloud.drizzle"
        case "Rain", "Freezing Rain", "Rain Showers": return "cloud.rain"
        case "Snow", "Snow Grains", "Snow Showers": return "cloud.snow"
        case "Thunderstorm": return "cloud.bolt"
        default: return "thermometer.medium"
        }
    }
}

struct NowWeatherReadout: View {
    let state: VehicleState
    var onClose: (() -> Void)? = nil

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.dynamicTypeSize) private var typeSize

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
                        if let onClose {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .hisType(.label)
                                    .foregroundStyle(HisingenTheme.ink)
                            }
                            .buttonStyle(.pressable)
                            .keyboardShortcut(.cancelAction)
                            .help(L10n.text("Close"))
                            .accessibilityLabel(L10n.text("Close"))
                        } else {
                            observation(weather.timestamp)
                        }
                    }
                    if onClose != nil {
                        observation(weather.timestamp)
                    }
                    PanelRule()
                    if onClose != nil || typeSize.isAccessibilitySize {
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
                }
            }
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
        return readings
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
