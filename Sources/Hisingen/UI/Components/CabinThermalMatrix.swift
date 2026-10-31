import SwiftUI

/// Requested heater levels (0 off, 1-3 intensity). Missing requests stay unknown;
/// the vehicle can apply automatic heating independently.
struct CabinThermalMatrix: View {
    let driverSeatLevel: Int?
    let passengerSeatLevel: Int?
    let steeringWheelLevel: Int?
    let interiorTemperatureCelsius: Double?
    let requestedTemperatureCelsius: Double?
    let activity: ClimateActivity

    @Environment(\.preferencesStore) private var preferences

    private var cabinLabel: String {
        switch activity {
        case .heating: return L10n.text("Heating")
        case .cooling: return L10n.text("Cooling")
        case .ventilating: return L10n.text("Ventilating")
        case .active, .starting: return L10n.text("Conditioning")
        case .idle, .unknown: return L10n.text("Idle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.and.liquid.waves")
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Text(L10n.text("Heating Requests"))
                    .hisType(.caption, weight: .medium)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer()
                Text(cabinLabel)
                    .hisType(.micro, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(activityBadgeColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(activityBadgeColor)
                    .hisAnimation(Motion.stateChange, value: activity)
            }

            HStack(alignment: .top, spacing: 10) {
                heaterTile(
                    title: L10n.text("Driver Seat"),
                    level: driverSeatLevel,
                    symbol: "carseat.left.and.heat.waves"
                )
                heaterTile(
                    title: L10n.text("Passenger Seat"),
                    level: passengerSeatLevel,
                    symbol: "carseat.right.and.heat.waves"
                )
                heaterTile(
                    title: L10n.text("Steering Wheel"),
                    level: steeringWheelLevel,
                    symbol: "steeringwheel.and.heat.waves"
                )
            }

            if let interior = interiorTemperatureCelsius {
                Text(temperatureLine(interior: interior))
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Text(L10n.text("Heater requests may differ from automatic heating in the car."))
                .hisType(.micro)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .hisCaptionLeading()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var activityBadgeColor: Color {
        switch activity {
        case .heating: return HisingenTheme.semanticWarning
        case .cooling: return HisingenTheme.semanticActive
        case .ventilating: return HisingenTheme.chartInfo
        case .active, .starting: return HisingenTheme.semanticGood
        case .idle, .unknown: return HisingenTheme.inkMuted
        }
    }

    private func temperatureText(_ celsius: Double) -> String {
        Format.temperature(celsius: celsius, unit: preferences.temperatureUnit)
    }

    private func temperatureLine(interior: Double) -> String {
        if let requested = requestedTemperatureCelsius, requested != interior {
            return L10n.format("Cabin %@ → target %@",
                               temperatureText(interior), temperatureText(requested))
        }
        return L10n.format("Cabin %@", temperatureText(interior))
    }

    /// Combined VoiceOver description of the cabin thermal state. Internal so the wiring
    /// tests can assert which heaters and temperatures are announced.
    var accessibilitySummary: String {
        var parts: [String] = [L10n.text("Heating Requests"), cabinLabel]
        for (title, level) in [
            (L10n.text("Driver Seat"), driverSeatLevel),
            (L10n.text("Passenger Seat"), passengerSeatLevel),
            (L10n.text("Steering Wheel"), steeringWheelLevel),
        ] {
            if let level, (1...3).contains(level) {
                parts.append(L10n.format("%@: level %d", title, level))
            } else {
                parts.append("\(title): \(Self.heaterLevelText(level))")
            }
        }
        if let interior = interiorTemperatureCelsius {
            parts.append(temperatureLine(interior: interior))
        }
        parts.append(L10n.text("Heater requests may differ from automatic heating in the car."))
        return parts.joined(separator: ", ")
    }

    static func heaterLevelText(_ level: Int?) -> String {
        guard let level, (0...3).contains(level) else { return L10n.text("Not reported") }
        return level == 0 ? L10n.text("Off") : L10n.format("Level %d", level)
    }

    @ViewBuilder
    private func heaterTile(title: String, level: Int?, symbol: String) -> some View {
        let active = (1...3).contains(level ?? 0)
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .hisType(.heading)
                .foregroundStyle(active ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
            Text(title)
                .hisType(.micro, weight: HisingenTheme.captionWeight)
                .foregroundStyle(HisingenTheme.ink)
            Text(Self.heaterLevelText(level))
                .hisType(.micro, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(active ? HisingenTheme.semanticWarning.opacity(0.12) : HisingenTheme.chipFill,
                    in: RoundedRectangle(cornerRadius: 6))
        .hisAnimation(Motion.stateChange, value: level)
    }
}
