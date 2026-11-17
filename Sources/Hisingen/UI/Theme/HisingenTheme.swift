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


    // Square, as on every Polestar surface from the website to the centre display. The macOS
    // window keeps its own corners; nothing inside it rounds.
    static var cornerRadius: CGFloat { 0 }
    static var keyRadius: CGFloat { 0 }

    /// The density preset's spacing multiplier. Type is the ramp's job; this is the other half of
    /// what density means now that the content tree is no longer raster-scaled — a denser layout is
    /// one that reflows, not one whose text a transform has shrunk.
    static var densitySpacingScale: CGFloat {
        PreferencesStore.shared.contentDensity.spacingScale
    }

    static var cardPadding: CGFloat {
        (16 * densitySpacingScale).rounded()
    }

    /// Corner radius for a progress bar or gauge. Global for the same reason as ``cornerRadius``.
    ///
    /// `EnergyGauges` carried its own `isPolestar ? 0 : 5` at three separate sites, so the energy
    /// bar, the fuel bar and the charging bar each decided the theme's shape independently and only
    /// agreed by coincidence. Tokens live here, not in the component that happens to draw them.
    static var gaugeRadius: CGFloat { 0 }

    static var sectionSpacing: CGFloat { (16 * densitySpacingScale).rounded() }
    /// Live panel geometry from the selected size preset or custom overrides, resolved through
    /// PanelLayout so every consumer agrees. Re-evaluated on each layout pass: changing either
    /// in Settings resizes the open dropdown immediately.
    static var panelLayout: PanelLayout { .resolve(from: .shared) }
    /// Width that fixed-width views must lay out at: the panel's own width.
    static var layoutWidth: CGFloat { panelLayout.width }
}
