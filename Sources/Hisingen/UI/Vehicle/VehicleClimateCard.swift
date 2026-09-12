import SwiftUI

@MainActor
struct VehicleClimateCard: View {
    let state: VehicleState
    let features: FeatureSelection
    let preferences: PreferencesStore

    static func make(state: VehicleState, features: FeatureSelection, preferences: PreferencesStore) -> AnyView? {
        let card = Self(state: state, features: features, preferences: preferences)
        guard !card.rows.isEmpty || card.climateUnavailable else { return nil }
        return AnyView(card)
    }

    private var climateActive: Bool {
        [.active, .heating, .cooling, .ventilating].contains(state.climateStatus?.activity)
    }

    private var climateUnavailable: Bool {
        features.contains(.climateStatus) && state.climateStatus == nil && !features.contains(.remoteClimate)
    }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if features.contains(.climateStatus) {
            if let climate = state.climateStatus, climate.activity != .unknown {
                var value = climate.activity.displayName
                if let minutes = climate.timeRemainingMinutes { value += " · \(Format.shortDuration(minutes: minutes))" }
                if climate.timerTriggered { value += " (\(L10n.text("Timer")))" }
                rows.append(KVRow(L10n.text("Cabin Climate"), value, symbol: climateActive ? "fan.fill" : "fan"))
                if let temperature = climate.interiorTemperatureCelsius { rows.append(KVRow(L10n.text("Cabin Temperature"), Format.temperature(celsius: temperature, unit: preferences.temperatureUnit), symbol: "thermometer.medium")) }
                if let target = climate.requestedTemperatureCelsius { rows.append(KVRow(L10n.text("Climate Target"), Format.temperature(celsius: target, unit: preferences.temperatureUnit), symbol: "target")) }
                if let level = climate.driverSeatHeatingLevel, level > 0 { rows.append(KVRow(L10n.text("Driver Seat Heating"), L10n.format("Level %d", level), symbol: "carseat.left.and.heat.waves")) }
                if let level = climate.passengerSeatHeatingLevel, level > 0 { rows.append(KVRow(L10n.text("Passenger Seat Heating"), L10n.format("Level %d", level), symbol: "carseat.right.and.heat.waves")) }
                if let level = climate.steeringWheelHeatingLevel, level > 0 { rows.append(KVRow(L10n.text("Steering Wheel Heating"), L10n.text("Active"), symbol: "steeringwheel.and.heat.waves")) }
            } else if features.contains(.remoteClimate) {
                rows.append(KVRow(L10n.text("Cabin Climate"), L10n.text("Off"), symbol: "fan"))
            }
            for timer in state.climateTimers.filter(\.isActive).prefix(3) {
                rows.append(KVRow(L10n.text("Ready at"), Format.scheduleText(timer), symbol: "clock.badge.checkmark"))
            }
        }
        if features.contains(.chargingSchedule) {
            for schedule in state.energy.schedules.filter(\.isActive).prefix(4) {
                var key = schedule.kind == .departure ? L10n.text("Departure Schedule") : L10n.text("Charging Schedule")
                if let location = schedule.locationName, !location.isEmpty { key = "\(location) \(key)" }
                rows.append(KVRow(key, Format.scheduleText(schedule), symbol: "calendar.badge.clock"))
            }
        }
        if features.contains(.airQuality), let air = state.airQuality {
            var value = air.cleaningState.displayName
            if air.cleaningState == .on, let runtime = air.runtimeRemainingMinutes, runtime > 0 { value += " · \(Format.shortDuration(minutes: runtime))" }
            rows.append(KVRow(L10n.text("Cabin Air Purifier"), value, symbol: "sparkles", valueWarning: air.hasError))
            if let aqi = air.airQualityIndex { rows.append(KVRow(L10n.text("Air Quality Index"), "\(aqi) AQI", symbol: "wind")) }
            if let pm = air.particulateMatter25 { rows.append(KVRow(L10n.text("PM2.5 Concentration"), "\(pm) µg/m³", symbol: "aqi.medium")) }
            if let outside = air.externalParticulateMatter25 {
                let comparison = air.particulateMatter25.map { " (\(L10n.text("Cabin")): \($0) µg/m³)" } ?? ""
                rows.append(KVRow(L10n.text("Outside PM2.5"), "\(outside) µg/m³\(comparison)", symbol: "leaf.fill"))
            }
            if let life = air.filterRemainingPercent { rows.append(KVRow(L10n.text("Air Filter Life"), "\(life)%", symbol: "allergens", valueWarning: life < 15)) }
        }
        if features.contains(.vehicleWeather), let weather = state.weather, let temperature = weather.temperatureCelsius {
            var value = Format.temperature(celsius: temperature, unit: preferences.temperatureUnit, decimals: 0)
            if let condition = weather.condition { value += " · \(L10n.text(condition))" }
            if let humidity = weather.relativeHumidity { value += " · \(humidity)% " + L10n.text("humidity") }
            if let feels = weather.apparentTemperatureCelsius { value += " (" + L10n.format("feels like %@", Format.temperature(celsius: feels, unit: preferences.temperatureUnit, decimals: 0)) + ")" }
            rows.append(KVRow(L10n.text("Ambient Weather"), value, symbol: "cloud.sun.fill"))
        }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(isSpinning: climateActive, size: 14, color: climateActive ? .orange : HisingenTheme.inkMuted)
                        Text(L10n.text("Climate & Timers")).font(.system(size: 12, weight: .bold)).foregroundStyle(HisingenTheme.ink)
                    }
                    Spacer()
                    if climateActive { Pill(text: state.climateStatus?.activity.displayName ?? L10n.text("Active"), color: .orange, symbol: "fan.fill") }
                }
                if climateUnavailable { CapabilityBadge(title: L10n.text("Climate status"), state: .unavailable) }
                if !rows.isEmpty { VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } } }
            }
        }
    }
}
