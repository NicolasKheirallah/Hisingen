import SwiftUI
import AppKit

@MainActor
extension HisingenTheme {

    // MARK: - Card Surface

    static func liquidGlassSpecularBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.85), dark: NSColor(white: 1.0, alpha: 0.30)), location: 0.0),
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.35), dark: NSColor(white: 1.0, alpha: 0.08)), location: 0.35),
                        .init(color: Color(light: NSColor(white: 0.0, alpha: 0.04), dark: NSColor(white: 0.0, alpha: 0.30)), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }

    /// How thick a surface should read, chosen by how big the surface is rather than by its theme.
    ///
    /// `cardShadowOpacity`/`cardShadowRadius` branched on the theme and never on size, so a 220pt
    /// hero card and a one-line settings row cast the identical shadow, while the 11pt capsule
    /// badge sitting *on* the hero card was denser than the card carrying it. That inverts the one
    /// thing elevation is for: a bigger surface has to read as thicker than a smaller one on top
    /// of it.
    enum SurfaceElevation {
        /// A chip, badge or label sitting on a card. The thinnest step, because the thing it
        /// covers is already off the canvas.
        case onCard
        /// A card or panel resting on the canvas.
        case card
        /// A window-level surface over the desktop: the floating charging panel.
        case floating
    }

    /// The colour a shadow is cast in.
    ///
    /// Every shadow in the app was hardcoded `Color.black`, which on the dark canvas is a 3 to 4 %
    /// black on near-black: the entire depth system vanished in dark mode. A shadow lifts a surface
    /// off what is behind it, and behind a card on a dark canvas there is nothing darker to go to,
    /// so the token is black in light and a lifted white in dark, at a lower alpha because a light
    /// veil reads stronger.
    static var shadowColor: Color {
        Color(light: NSColor(white: 0.0, alpha: 1), dark: NSColor(white: 1.0, alpha: 1))
    }

    /// Black at `opacity` in light mode, white at 0.55 × that in dark, where a light veil reads
    /// stronger than its alpha suggests.
    static func shadowTint(_ opacity: Double) -> Color {
        Color(
            light: NSColor(white: 0.0, alpha: opacity),
            dark: NSColor(white: 1.0, alpha: opacity * 0.55)
        )
    }

    static func shadow(for elevation: SurfaceElevation) -> (color: Color, radius: CGFloat, y: CGFloat) {
        switch elevation {
        case .onCard:
            // Deliberately below `card`: a chip sits on a surface that is already off the canvas, so
            // it has less distance to cover than the card does.
            return (shadowTint(0.04), 1.5, 1)
        case .card:
            // One shadow, not two: the old pair composed to about 0.07 spread over two passes, and
            // two stacked `.shadow` modifiers mean two offscreen renders for that result.
            return (shadowTint(cardShadowOpacity), cardShadowRadius, 3)
        case .floating:
            // The one elevation that stays heavier than the rest: this is a window over an arbitrary
            // desktop, not a card over the canvas, so it has real distance to express.
            return (shadowTint(0.18), 8, 3)
        }
    }

    /// The card surface in full, for a given corner radius.
    ///
    /// `Card` used to hardcode this as a nine-way theme switch while `cardBackground` defined the
    /// same surface a second time for the one call site that used it, and the two disagreed:
    /// `.hisingen` returned a bare material from the token and a material plus a specular wash from
    /// the component, `.volvo` an opaque colour from one and a gradient from the other. A card is
    /// the most repeated surface in the app, so two answers meant editing the token changed one
    /// screen and nothing else. There is one answer now, and every card path reads it.
    ///
    /// The Polestar branch that drew a bare square `Rectangle` is gone with theme geometry: the
    /// global `cornerRadius` is 12, so drawing a square *fill* under a rounded *boundary stroke*
    /// would have left that theme's cards with filled corners and a detached outline.
    ///
    /// A card is a solid surface. It used to be a second `.regularMaterial` carrying the canvas at
    /// 60 %, which meant a card rendered a blur *on top of* the blur the popover surface had already
    /// drawn — two nested translucent materials, which §12 forbids because legibility collapses and
    /// because the result is not a material reading at all, just two blurs compositing toward grey.
    ///
    /// The hierarchy is now explicit and each step is one thing:
    ///   panel  → `.regularMaterial` over the popover backing
    ///   card   → solid `cardFill`, the canvas lifted toward white
    ///   chip   → solid `chipFill`, the card sunk toward black
    ///
    /// Separation comes from the boundary stroke and the shadow, which is what they are for. The
    /// specular rim is kept: a real edge on a real surface.
    @ViewBuilder
    static func cardSurface(cornerRadius radius: CGFloat) -> some View {
        CardSurface(cornerRadius: radius)
    }

    /// The panel's fill when the blur is dropped, under an opaque card.
    ///
    /// A neutral, deliberately *darker* than any canvas. When Reduce Transparency or Increase
    /// Contrast drops the blur the panel becomes opaque, and the card is lifted toward white rather
    /// than being the canvas — so the panel has to go down for the card to separate at all. Using
    /// the theme canvas here, as an earlier comment claimed it did, would leave a light theme whose
    /// canvas is already near-white (Swedish Gold, Sand Dune) with a card 2 % lighter than its own
    /// panel.
    static var panelFill: Color {
        Color(
            light: NSColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1),
            dark: NSColor(red: 0.045, green: 0.05, blue: 0.06, alpha: 1)
        )
    }

    /// The specular rim a glass card carries. Suppressed for opaque surfaces, which have a real
    /// edge already.
    @ViewBuilder
    static func cardRim(cornerRadius radius: CGFloat, prefersOpaque: Bool) -> some View {
        if radius > 0, !prefersOpaque {
            liquidGlassSpecularBorder(cornerRadius: radius)
        }
    }
    /// Opacity for the app's hairline separators.
    ///
    /// Six values were in use across 59 sites (0.2, 0.25, 0.3, 0.35, 0.4, 0.5) with no token
    /// between them, so two dividers inside one stack could differ for no stated reason. 0.4 was
    /// already the de facto value at 49 of them, and it is what the shell's own rules used.
    static var dividerOpacity: Double { 0.4 }

    /// The outline that separates a card from the panel behind it.
    ///
    /// `hairline` is 8 % black in the default theme, which composites to roughly 1.19:1 against the
    /// canvas: a hairline is a *divider*, and it was doing a *boundary's* job as the only thing
    /// marking where a card ends. WCAG 1.4.11 asks 3:1 of a meaningful non-text boundary, so a
    /// reader who has told the system they need more contrast gets one that clears it, in every
    /// theme, rather than a slightly thicker version of the same whisper.
    @ViewBuilder
    static func cardBoundary(increasedContrast: Bool) -> some View {
        if increasedContrast {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(cardBoundaryIncreased, lineWidth: cardBoundaryIncreasedWidth)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(hairline, lineWidth: cardBorderWidth)
        }
    }

    /// 3:1 against every theme's canvas and against every theme's card, in both appearances.
    /// `Scripts/verify-app-contrast.py` recomputes all eighteen of those pairs from this file and
    /// fails the build; the measured floor is 3.29:1.
    static let cardBoundaryIncreased = Color(
        light: NSColor(white: 0.5216, alpha: 1),
        dark: NSColor(white: 0.4118, alpha: 1)
    )

    /// A boundary drawn at the width of a boundary, not of a hairline.
    static var cardBoundaryIncreasedWidth: CGFloat { 1 }

    /// Corner radius for a full-width notice banner: one value, not a theme branch.
    ///
    /// The banner hardcoded 10 and used to keep rounded corners in a theme whose identity was sharp
    /// corners. That theme no longer exists — geometry is global and ``cornerRadius`` is 12 — so the
    /// conditional guarding against it could only ever take one branch. A banner is a slight
    /// concentric inset of the card carrying it, which is why it is 10 rather than 12.
    static var bannerRadius: CGFloat { 10 }

    /// A compact, neutral marker for keyboard focus on custom pressable buttons.
    /// It deliberately uses the foreground ink instead of the theme accent so focus never becomes
    /// a large blue outline in blue-accented themes.
    static var focusIndicator: Color { ink }
    static var focusIndicatorWidth: CGFloat { 12 }
    static var focusIndicatorHeight: CGFloat { 2 }

    /// Corner radius for the tinted status-label family (``Pill``, ``StateSummaryChip``,
    /// ``CommandReceiptChip``).
    ///
    /// These are one idea — a small tinted label carrying state — and they were built
    /// independently at radii 5, 8 and 9 with no token between them, while ``Pill`` and
    /// ``StateSummaryChip`` render side by side in the vehicle hero. One value now, and a low one:
    /// a chip is far smaller than its card, so a literal concentric inset of the card's 12 would
    /// read as a rounded rectangle rather than a label. (The formula this replaced,
    /// `cornerRadius - cardPadding + 4`, evaluated to at most 1 at every density and was clamped
    /// to this value on every path anyway.)
    static var statusChipRadius: CGFloat { 4 }

    /// A surface inset into a card: the card sunk toward black, per theme. See ``Palette/chipFill``.
    ///
    /// Derived from the card rather than fixed at one neutral, because the inset has to separate
    /// from a *per-theme* card: a value that reads as inset under Sand Dune's warm card must also
    /// read as inset under Nordic Night's lifted grey one, which sits at almost the same luminance
    /// a fixed neutral chip used to land on.
    static var cardFillInset: Color { palette.chipFill }

    /// Hairline boundary width, one value for every theme.
    ///
    /// The default theme used 0.5 and the rest used 1, so the boundary was sub-pixel in the theme
    /// most people run and crisp in the others. A boundary is a boundary.
    static var cardBorderWidth: CGFloat { 1 }

    /// Card shadow, one value for every theme.
    ///
    /// Polestar resolved to a *zero* shadow and Volvo to a weaker one, so in two of nine themes the
    /// entire elevation system was switched off and a card was separable only by its hairline.
    /// 0.04 at radius 6 is the value the other seven already used.
    static var cardShadowOpacity: Double { 0.04 }
    static var cardShadowRadius: CGFloat { 6 }

    // MARK: - Popover Surface

    /// Full-bleed popover surface: the panel's own material, over the standard `NSPopover`
    /// backing.
    ///
    /// This used to be a `.ultraThinMaterial` over a three-stop gradient whose bottom stop was an
    /// orange at 5 % alpha, drawn into a window whose backing had been cleared so the material
    /// sampled the desktop. Three separate problems came out of that:
    ///
    /// 1. The popover lost its rounded corners, its arrow and its shadow, because `NSPopover` draws
    ///    all three with the backing the window was clearing.
    /// 2. The orange stop composited over dark content into a muddy brown wash, so the panel read as
    ///    tinted rather than as glass. Apple's materials are neutral and take their colour from what
    ///    is behind them; brand warmth belongs in the accent token, on the elements that act.
    /// 3. `.ultraThinMaterial` is the substrate for thin strips — the menu bar, a toolbar. A
    ///    full-height panel is a large surface, and a large surface has to read as thicker than the
    ///    chips and cards it carries.
    ///
    /// So: `.regularMaterial` at full opacity, over AppKit's own popover backing, with the chrome
    /// intact.
    @ViewBuilder
    static var popoverSurface: some View {
        PopoverSurface()
    }
}

/// A card's fill: a raised surface, never the canvas.
///
/// A card is *elevated* — it sits on the panel, and that elevation is the whole reason the shadow,
/// the rim and the boundary stroke exist. Filling it with `canvas` made it the panel's exact colour,
/// so in dark mode (where the canvas is already near-black) cards, panel and desktop composited into
/// one black field and only a whisper of a hairline said where a card ended.
///
/// The fill is the canvas lifted toward white by a fixed *fraction*, per theme and per appearance —
/// see ``Palette/cardFill``. The fraction keeps the lift proportionate (a fixed luminance step would
/// be invisible on a black canvas and glaring on a white one, because perceived lightness is not
/// linear in sRGB), and deriving it from the canvas keeps the theme's hue. It was one fixed blue-grey
/// in the dark appearance, which dropped the hue of every theme but the default.
@MainActor
private struct CardSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(HisingenTheme.cardFill)
    }
}

/// The popover's own surface, as a view rather than a token, because the decision
/// depends on the environment: Reduce Transparency and Increase Contrast both ask for
/// an opaque surface, and a static token cannot see either.
@MainActor
struct PopoverSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Under either setting the blur is dropped entirely and ``panelFill`` — a neutral, darker than
    /// any canvas — supplies the panel, so the lifted card still separates from it. Otherwise
    /// `.regularMaterial` supplies the panel, which already adapts to the appearance and to the
    /// desktop behind the window.
    private var prefersOpaqueSurface: Bool {
        reduceTransparency || contrast == .increased
    }

    var body: some View {
        if prefersOpaqueSurface {
            // The panel goes *down*, not the cards going up: an opaque card on an opaque canvas
            // panel would have been invisible, which is exactly the defect the lifted `cardFill`
            // exists to fix, arriving by a different route.
            Rectangle().fill(HisingenTheme.panelFill)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}
