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
        case .polestar: return palette.inkMuted
        case .volvo: return volvoNavy
        case .hisingen: return preferred
        default: return palette.accent
        }
    }

    // MARK: - Chart Series

    static var chartPositive: Color { palette.chartPositive }
    static var chartInfo: Color { palette.chartInfo }
    static var chartAttention: Color { palette.chartAttention }
    static var chartHealth: Color { palette.chartHealth }

    // MARK: - Semantic Status Colors
    //
    // This is the token family that was still raw system colours. `Color.orange` and friends do
    // resolve per appearance, but they are built to be *seen*, not *read*: as 10–12 pt text on a
    // card they measured 1.86–3.81:1 in the light appearance, and three of them failed even in the
    // dark. `polestarAmber` had already been corrected for exactly this reason; this is the same
    // correction applied to the family — dual-appearance, and held to 4.5:1 on every theme's card
    // *and* on a 12 % wash of themselves over it, which is the surface a ``Pill``,
    // ``StateSummaryChip`` or ``CommandReceiptChip`` actually draws its label on.
    //
    // Each keeps its system colour's hue and moves only lightness.
    // `Scripts/verify-app-contrast.py` recomputes every one of these pairs and fails the build.
    static let semanticGood = Color(
        light: NSColor(red: 0.0500, green: 0.4000, blue: 0.1800, alpha: 1),
        dark: NSColor(red: 0.3000, green: 0.8500, blue: 0.5000, alpha: 1)
    )
    static let semanticActive = Color(
        light: NSColor(red: 0.0000, green: 0.3200, blue: 0.6200, alpha: 1),
        dark: NSColor(red: 0.4921, green: 0.7414, blue: 1.0000, alpha: 1)
    )
    static let semanticWarning = Color(
        light: NSColor(red: 0.6200, green: 0.3000, blue: 0.0200, alpha: 1),
        dark: NSColor(red: 1.0000, green: 0.7000, blue: 0.3400, alpha: 1)
    )
    static let semanticCritical = Color(
        light: NSColor(red: 0.7000, green: 0.0900, blue: 0.1000, alpha: 1),
        dark: NSColor(red: 1.0000, green: 0.6198, blue: 0.5944, alpha: 1)
    )
    /// A hardware fault. Was `Color.purple`, kept distinct from the low-pressure warning so
    /// "add air" and "book service" never render as the same label.
    static let semanticFault = Color(
        light: NSColor(red: 0.4500, green: 0.1600, blue: 0.6200, alpha: 1),
        dark: NSColor(red: 0.8500, green: 0.6400, blue: 1.0000, alpha: 1)
    )
    /// Fuel level: a warm amber, distinct from the warning orange so a healthy tank and a low one
    /// are not the same swatch. Was a bare `Color(red:green:blue:)` measured at 2.03:1 on the
    /// light card while being used as a foreground label.
    static let semanticFuel = Color(
        light: NSColor(red: 0.5742, green: 0.3564, blue: 0.0000, alpha: 1),
        dark: NSColor(red: 1.0000, green: 0.7600, blue: 0.3000, alpha: 1)
    )

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
        case .sensorFault: return semanticFault
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
    ///
    /// These stay *system* colours rather than theme tokens, deliberately, and it is the one place
    /// the app does so. The glyph is drawn into an `NSImage` that sits on the user's menu bar, an
    /// arbitrary surface the app cannot see and does not own: `.controlAccentColor` is the colour
    /// macOS itself uses for that chrome and already adapts to the menu bar's appearance and to
    /// Increase Contrast, where a theme accent tuned for the Hisingen canvas would not. The panel
    /// and the menu bar can therefore differ in tint — the panel follows the chosen theme, the
    /// glyph follows the system — which is the intended split, not an oversight.
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
        case .critical, .low: return semanticWarning
        case .charging, .chargingComplete: return semanticGood
        case .normal: return .secondary
        }
    }

    static func fuelColor(percentage: Double) -> Color {
        if percentage <= 12 { return semanticCritical }
        if percentage <= 25 { return semanticWarning }
        return semanticFuel
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
