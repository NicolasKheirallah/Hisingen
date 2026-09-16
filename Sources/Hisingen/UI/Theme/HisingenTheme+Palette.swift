import SwiftUI
import AppKit

@MainActor
extension HisingenTheme {

    // MARK: - Brand Core Colors

    /// Polestar signature Swedish Gold & Amber highlight (#E56E23).
    ///
    /// Dual-appearance like `volvoBlue` and `volvoNavy` below it, and for a measured reason: this
    /// amber is only 2.8:1 on the Polestar light canvas, yet it is used as a text colour (the
    /// climate countdown, the cabin-temperature reading, the warranty header) while failing even
    /// the 3:1 large-text bar on the surface it actually sits on. The light variant is the same
    /// hue scaled to 0.70 in sRGB, which is 5.3:1 on the canvas and 5.9:1 on white.
    /// `Scripts/verify-app-contrast.py` recomputes both appearances from this file and fails the
    /// build; the measured values are 5.25:1 (light) and 6.20:1 (dark).
    static let polestarAmber = Color(
        light: NSColor(red: 0.6275, green: 0.3020, blue: 0.0941, alpha: 1),
        dark: NSColor(red: 0.8980, green: 0.4314, blue: 0.1373, alpha: 1)
    )

    /// Official Volvo Digital / Electric Blue
    static let volvoBlue = Color(
        light: NSColor(red: 0x00/255, green: 0x5b/255, blue: 0x94/255, alpha: 1),
        dark: NSColor(red: 0x38/255, green: 0xbd/255, blue: 0xf8/255, alpha: 1)
    )

    /// Official Volvo Heritage Iron Navy (#003057)
    static let volvoNavy = Color(
        light: NSColor(red: 0x00/255, green: 0x30/255, blue: 0x57/255, alpha: 1),
        dark: NSColor(red: 0x1e/255, green: 0x3a/255, blue: 0x5f/255, alpha: 1)
    )

    // MARK: - Semantic Surface & Text Tokens

    static var canvas: Color { palette.canvas }

    static var ink: Color { palette.ink }

    static var inkMuted: Color { palette.inkMuted }

    static var hairline: Color { palette.hairline }

    /// The active theme's card fill: the canvas lifted toward white. See ``Palette/cardFill``.
    static var cardFill: Color { palette.cardFill }

    /// The active theme's chip fill: the card sunk toward black. See ``Palette/chipFill``.
    ///
    /// Opaque, not a third translucent material stacked on the card's on the panel's. §12 forbids
    /// stacking light translucent surfaces because legibility collapses, and the worst case was the
    /// hero badge over a photograph: a chip only has to separate from the card behind it, not from
    /// the desktop behind that. It is the card sunk toward black rather than the card's own fill —
    /// matching the card exactly would reproduce the "where does this end" problem the card had
    /// against the canvas.
    static var chipFill: Color { palette.chipFill }

    static var accent: Color { palette.accent }

    /// High-contrast foreground colour designed to be rendered on top of `accent`.
    /// Returns black for light accents (Swedish Gold, Aurora, Sand Dune) and white for dark accents.
    static var accentOn: Color { palette.accentOn }

    /// The accent for a specific theme rather than the active one.
    ///
    /// The appearance card previews every theme at once, and it used `AppTheme.accentColorHex` — a
    /// single fixed hex with no dark variant. Every other token in this file is a
    /// `Color(light:dark:)` pair, so the selected state of a dark theme was a dark navy border and
    /// checkmark on a near-black card: the hardest thing on the tile to see, in the card whose
    /// whole job is judging a theme.
    static func accent(for theme: AppTheme) -> Color {
        palette(for: theme).accent
    }

    /// The high-contrast foreground colour on top of the accent for a specific theme.
    static func accentOn(for theme: AppTheme) -> Color {
        palette(for: theme).accentOn
    }
}
