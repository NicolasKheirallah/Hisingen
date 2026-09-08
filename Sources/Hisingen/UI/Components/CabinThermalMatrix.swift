import SwiftUI

/// 2D cabin thermal layout: seat and steering-wheel heating levels rendered in their physical
/// positions (driver left / passenger right, LHD/RHD-aware where the backend reports
/// orientation), plus the interior/requested temperatures. Reads only from the already-decoded
/// `VehicleClimateStatus` levels (0 = off, 1–3 = level) — it never infers heat from the vehicle
/// name or exposes a control; remote heating stays in Controls.
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(L10n.text("Cabin Thermal Overview"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cabinLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(activityBadgeColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(activityBadgeColor)
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
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var activityBadgeColor: Color {
        switch activity {
        case .heating: return .orange
        case .cooling: return .blue
        case .ventilating: return .teal
        case .active, .starting: return .green
        case .idle, .unknown: return .secondary
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
        var parts: [String] = [cabinLabel]
        for (title, level) in [
            (L10n.text("Driver Seat"), driverSeatLevel),
            (L10n.text("Passenger Seat"), passengerSeatLevel),
            (L10n.text("Steering Wheel"), steeringWheelLevel),
        ] {
            if let level, level > 0 {
                parts.append(L10n.format("%@: level %d", title, level))
            }
        }
        if let interior = interiorTemperatureCelsius {
            parts.append(temperatureLine(interior: interior))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func heaterTile(title: String, level: Int?, symbol: String) -> some View {
        let active = (level ?? 0) > 0
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? .orange : .secondary)
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(active
                 ? L10n.format("Level %d", level ?? 0)
                 : L10n.text("Off"))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(active ? Color.orange.opacity(0.10) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}