import AppKit
import SwiftUI

@MainActor
extension HisingenTheme {

    // MARK: - Decorative Tint

    static func decorativeTint(_ preferred: Color) -> Color {
        switch theme {
        case .polestar: return inkMuted
        case .volvo: return volvoNavy.opacity(0.75)
        case .hisingen: return preferred
        default: return accent.opacity(0.8)
        }
    }

    // MARK: - Semantic Status Colors

    static let semanticGood = Color.green

    /// Chart series tokens. Themes with a strong accent identity (Monochrome Precision and
    /// Heritage Blue) collapse charts toward the theme accent; expressive themes
    /// keep distinct hues so multi-series cards stay readable.
    static var chartPositive: Color { decorativeTint(.green) == .green ? .green : HisingenTheme.accent }
    static var chartInfo: Color { decorativeTint(.cyan) == .cyan ? .cyan : HisingenTheme.accent.opacity(0.85) }
    static var chartAttention: Color { decorativeTint(.orange) == .orange ? .orange : HisingenTheme.accent.opacity(0.7) }
    static var chartHealth: Color { decorativeTint(.pink) == .pink ? .pink : HisingenTheme.accent.opacity(0.9) }
    static let semanticActive = Color.blue
    static let semanticWarning = Color.orange
    static let semanticCritical = Color.red

    // MARK: - Domain Color Helpers

    /// UI severity color for a tyre's reported warning level: green when explicitly OK,
    /// red for critically low, orange for low/high, muted gray when nothing was reported.
    static func tyreWarningColor(_ warning: TyrePressureWarning) -> Color {
        switch warning {
        case .none: return semanticGood
        case .veryLow: return semanticCritical
        case .low, .high: return semanticWarning
        case .sensorFault: return semanticWarning
        case .unknown: return Color.secondary
        }
    }

    /// Palette for the level the domain already decided (`VehicleState.batteryLevel`). Each
    /// renderer owns its own colours; none of them owns the thresholds.
    static func batteryColor(level: BatteryLevel) -> Color {
        switch level {
        case .critical: return semanticCritical
        case .low: return .yellow
        case .charging: return accent
        case .chargingComplete: return semanticGood
        case .normal: return .accentColor
        }
    }

    /// The menu bar has room for one alert tint, so both low levels read orange and critical
    /// escalates to red.
    static func menuBarBatteryTint(level: BatteryLevel) -> NSColor {
        switch level {
        case .critical: return .systemRed
        case .low: return .systemOrange
        case .charging, .chargingComplete: return .systemGreen
        case .normal: return .controlAccentColor
        }
    }

    /// A fleet row is a two-state reading: charging is good news, a low pack is an alert.
    static func fleetBatteryTint(level: BatteryLevel) -> Color {
        switch level {
        case .critical, .low: return .orange
        case .charging, .chargingComplete: return .green
        case .normal: return .secondary
        }
    }

    static func fuelColor(percentage: Double) -> Color {
        if percentage <= 12 { return semanticCritical }
        if percentage <= 25 { return semanticWarning }
        return Color(red: 0.96, green: 0.60, blue: 0.12)
    }

    static func statusColor(state: ChargingState) -> Color {
        if state == .fault { return semanticWarning }
        if state.isActivelyCharging { return semanticGood }
        return .secondary
    }

    static func temperatureColor(celsius: Double) -> Color {
        if celsius < 20.0 { return semanticActive }
        if celsius > 22.0 { return polestarAmber }
        return .primary
    }
}
