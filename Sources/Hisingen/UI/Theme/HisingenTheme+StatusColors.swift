import AppKit
import SwiftUI

@MainActor
extension HisingenTheme {

    // MARK: - Decorative Tint

    /// Recolours a *glyph* into the theme's voice. Never use this for data.
    ///
    /// Its one caller is ``CardHeader``'s symbol, which is decoration: the card's meaning is in its
    /// title and its contents. Chart series used to come through here and inherited the theme accent
    /// at four alpha steps, which made two plotted series 1.21:1 apart. Series are data and now
    /// carry their own tokens.
    static func decorativeTint(_ preferred: Color) -> Color {
        switch theme {
        case .polestar: return inkMuted
        case .volvo: return volvoNavy
        case .hisingen: return preferred
        // No alpha. A 0.8 multiplier took the card-header glyph to 2.64:1 in light mode in six of
        // nine themes, on the only non-text cue for what a card is about.
        default: return accent
        }
    }

    // MARK: - Semantic Status Colors

    static let semanticGood = Color.green

    // MARK: - Chart Series
    //
    // Theme-independent on purpose. These were four `decorativeTint(…) == … ? … : accent.opacity(x)`
    // expressions whose guard could only ever be true for `.hisingen`, so in the other eight themes
    // every series resolved to the theme accent at four different alphas: 1.0 / 0.9 / 0.85 / 0.7.
    // `chartInfo` and `chartAttention` are plotted against each other on shared axes (voltage with
    // current, PM2.5 with PM10), and at the Hisingen accent they differed by 1.21:1 against the 3:1
    // WCAG 1.4.11 floor for adjacent graphics. A chart series is data, not decoration, so it does
    // not take its colour from the theme's decoration; `decorativeTint` keeps that job and is used
    // for glyphs, as its name says.
    //
    // Each value is a dual-appearance pair picked so that (a) it clears 3:1 against the card it is
    // drawn on in both appearances and (b) `chartInfo` and `chartAttention` clear 3:1 against each
    // other in both. `verify-app-contrast.py` recomputes all ten ratios from this file.

    static let chartPositive = Color(
        light: NSColor(red: 0.0824, green: 0.5569, blue: 0.2824, alpha: 1),
        dark: NSColor(red: 0.2157, green: 0.7216, blue: 0.3843, alpha: 1)
    )
    static let chartInfo = Color(
        light: NSColor(red: 0.0235, green: 0.1961, blue: 0.4392, alpha: 1),
        dark: NSColor(red: 0.1216, green: 0.4471, blue: 0.8196, alpha: 1)
    )
    static let chartAttention = Color(
        light: NSColor(red: 0.8392, green: 0.4118, blue: 0.0431, alpha: 1),
        dark: NSColor(red: 1.0000, green: 0.7882, blue: 0.1490, alpha: 1)
    )
    static let chartHealth = Color(
        light: NSColor(red: 0.6863, green: 0.1725, blue: 0.4275, alpha: 1),
        dark: NSColor(red: 0.9647, green: 0.3882, blue: 0.7255, alpha: 1)
    )
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
        // A hardware fault and a genuinely low tyre were the same orange, so "add air" and "book
        // service" looked identical. A fault is the one a reader cannot fix themselves.
        case .sensorFault: return Color.purple
        case .unknown: return Color.secondary
        }
    }

    /// Palette for the level the domain already decided (`VehicleState.batteryLevel`). Each
    /// renderer owns its own colours; none of them owns the thresholds.
    /// One palette for one reading.
    ///
    /// Normal and charging levels use the app theme's accent. Using `ink` for normal made the
    /// battery fill nearly white in dark mode, while `Color.accentColor` would leak the user's
    /// macOS accent into the app instead of following the selected Hisingen theme.
    static func batteryColor(level: BatteryLevel) -> Color {
        switch level {
        case .critical: return semanticCritical
        case .low: return semanticWarning
        case .charging: return accent
        case .chargingComplete: return semanticGood
        case .normal: return accent
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
