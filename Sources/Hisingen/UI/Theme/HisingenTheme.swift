import SwiftUI

/// Design-token namespace for the whole app. Colour resolves from the user's selected `AppTheme`;
/// geometry — radius, padding, shadow, border width, the weight ladder — is global and does **not**
/// vary by theme, because a theme is a palette and choosing one is a colour preference, not a
/// request for a different layout. The surface area is large, so it is split across focused files:
///
/// - `HisingenTheme.swift` – the type plus panel / layout geometry
/// - `Palette.swift` – the per-theme token module: colours, metadata, chart series, surface states
/// - `HisingenTheme+Palette.swift` – the active palette's token accessors
/// - `HisingenTheme+Surfaces.swift` – card and popover surface styling
/// - `HisingenTheme+Typography.swift` – font weights, tracking
/// - `HisingenTheme+StatusColors.swift` – status / chart colours and domain helpers
@MainActor
enum HisingenTheme {
    static var theme: AppTheme { PreferencesStore.shared.appTheme }


    /// The app's corner radius. One value, not nine.
    ///
    /// This used to be a nine-case switch returning 0 for Polestar, 8 for Cyan Racing, 10 for Volvo
    /// and Swedish Gold, 12, 14 and 16 for the rest — so choosing a *colour* palette silently
    /// changed the shape of every card, chip, banner and popover in the app. That inverts
    /// Simplicity and Craft: a theme is a palette, and a user picking one is expressing a colour
    /// preference, not asking for different geometry. It also multiplied the surfaces that had to be
    /// verified by nine.
    ///
    /// Theme geometry is now frozen: radius, padding, shadow, border width and the weight ladder are
    /// global, and themes vary colour only. 12 is the median of the values the themes used to carry
    /// and sits inside Apple's range for a compact utility panel.
    static var cornerRadius: CGFloat { 12 }

    /// The density preset's spacing multiplier. Type is the ramp's job; this is the other half of
    /// what density means now that the content tree is no longer raster-scaled — a denser layout is
    /// one that reflows, not one whose text a transform has shrunk.
    static var densitySpacingScale: CGFloat {
        PreferencesStore.shared.contentDensity.spacingScale
    }

    static var cardPadding: CGFloat {
        (15 * densitySpacingScale).rounded()
    }

    /// Corner radius for a progress bar or gauge. Global for the same reason as ``cornerRadius``.
    ///
    /// `EnergyGauges` carried its own `isPolestar ? 0 : 5` at three separate sites, so the energy
    /// bar, the fuel bar and the charging bar each decided the theme's shape independently and only
    /// agreed by coincidence. Tokens live here, not in the component that happens to draw them.
    static var gaugeRadius: CGFloat { 5 }

    static var sectionSpacing: CGFloat { (12 * densitySpacingScale).rounded() }
    /// Live panel geometry from the selected size preset / custom overrides /
    /// density zoom, resolved through PanelLayout so every consumer agrees.
    /// Re-evaluated on each layout pass: changing any of the three in Settings
    /// resizes the open dropdown immediately.
    static var panelLayout: PanelLayout { .resolve(from: .shared) }
    /// Content zoom factor from the density preset; <1 shows more content in the same
    /// panel, >1 enlarges it.
    static var contentScale: CGFloat { panelLayout.contentScale }
    /// Width that fixed-width views must lay out at. Identical to `width`, because nothing
    /// scales the tree any more; kept named so call sites do not silently assume the two agree.
    static var layoutWidth: CGFloat { panelLayout.logicalWidth }
}
