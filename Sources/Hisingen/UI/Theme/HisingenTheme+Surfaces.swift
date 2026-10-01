import SwiftUI
import AppKit

@MainActor
extension HisingenTheme {

    /// Opacity for a tinted wash that carries text on the glass. Increase Contrast asks
    /// surfaces to stop being translucent, and a 10–12 % hue is exactly that, so the wash
    /// doubles under it (capped at the accent-wash ceiling's neighbour). Value bindings,
    /// pickers and materials have their own paths; this is only for wash-as-fill call sites.
    static func tintedWashOpacity(_ base: Double, increasedContrast: Bool) -> Double {
        increasedContrast ? min(base * 2, 0.24) : base
    }

    /// Opacity for the app's hairline separators.
    ///
    /// Six values were in use across 59 sites (0.2, 0.25, 0.3, 0.35, 0.4, 0.5) with no token
    /// between them, so two dividers inside one stack could differ for no stated reason. 0.4 was
    /// already the de facto value at 49 of them, and it is what the shell's own rules used.
    static var dividerOpacity: Double { 0.4 }

    /// The neutral fill a selectable chip lifts to while the pointer is over it.
    ///
    /// The hover step of the tinted-fill ladder: louder than any chip's resting 4–6 %, the
    /// same 8 % the accent washes use for hover, and still below the 12 % ceiling the
    /// accent's 4.5:1 guarantee covers. A chip is clickable, and on this platform clickable
    /// means the pointer gets an answer before the click.
    static var chipHoverFill: Double { 0.08 }

    /// The outline a section draws *only* under Increase Contrast.
    ///
    /// In the 2026 language a section is separated by its fill and the whitespace around it, so
    /// the default surface draws no outline at all. But WCAG 1.4.11 still asks 3:1 of a meaningful
    /// non-text boundary for a reader who has asked for more contrast, and a fill step does not
    /// clear that bar — so the one boundary the app draws is this one, and it clears 3:1 against
    /// every theme's canvas and every theme's card in both appearances.
    /// `Scripts/verify-app-contrast.py` recomputes all eighteen of those pairs from this file and
    /// fails the build; the measured floor is 3.29:1.
    @ViewBuilder
    static func cardBoundary(increasedContrast: Bool) -> some View {
        if increasedContrast {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(cardBoundaryIncreased, lineWidth: cardBoundaryIncreasedWidth)
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
    /// A banner is a slight concentric inset of the section carrying it, which is why it is 10
    /// rather than the card's 12.
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
    /// a chip is far smaller than its section, so a literal concentric inset of the card's 12 would
    /// read as a rounded rectangle rather than a label.
    static var statusChipRadius: CGFloat { 4 }

    // MARK: - Popover Surface

    /// Full-bleed popover surface: the panel's own material, over the standard `NSPopover`
    /// backing.
    ///
    /// `.regularMaterial` at full opacity, over AppKit's own popover backing, with the popover's
    /// corners, arrow and shadow intact. It stays the one translucent surface in any stack: in the
    /// 2026 language the material is also what the glass layer samples, so a second blur anywhere
    /// under a glass control would be two blurs compositing toward grey.
    @ViewBuilder
    static var popoverSurface: some View {
        PopoverSurface()
    }
}

/// The popover's own surface, as a view rather than a token, because the decision
/// depends on the environment: Reduce Transparency and Increase Contrast both ask for
/// an opaque surface, and a static token cannot see either.
@MainActor
struct PopoverSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    /// Under either setting the blur is dropped entirely and ``panelFill`` — a neutral, darker than
    /// any canvas — supplies the panel, so the lifted card still separates from it. In light
    /// appearance, `.thinMaterial` reveals more of the desktop through the panel; dark appearance
    /// keeps `.regularMaterial` for a steadier text surface.
    private var prefersOpaqueSurface: Bool {
        reduceTransparency || contrast == .increased
    }

    var body: some View {
        if prefersOpaqueSurface {
            // The panel goes *down*, not the cards going up: an opaque card on an opaque canvas
            // panel would have been invisible, which is exactly the defect the lifted `cardFill`
            // exists to fix, arriving by a different route.
            Rectangle().fill(HisingenTheme.panelFill)
        } else if colorScheme == .light {
            Rectangle().fill(.thinMaterial)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

extension HisingenTheme {

    /// The tint a *transient* overlay's shadow is cast in: black in light mode, a lifted white in
    /// dark, where a light veil reads stronger than its alpha suggests. The only consumers are the
    /// two overlays that float above scrolling content mid-gesture (the pull-to-refresh capsule);
    /// sections and chips draw no shadow at all — elevation inside the panel belongs to the
    /// window.
    static func shadowTint(_ opacity: Double) -> Color {
        Color(
            light: NSColor(white: 0.0, alpha: opacity),
            dark: NSColor(white: 1.0, alpha: opacity * 0.55)
        )
    }

    /// The panel's fill when the blur is dropped, under an opaque section.
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
}

// MARK: - Liquid Glass (the functional layer)

extension View {

    /// The app's one glass treatment for a control: the 2026 functional layer.
    ///
    /// Glass marks what the reader *operates* — the selected tab, a command control, a pressed
    /// target — and it is drawn nowhere else but through this modifier, so the language cannot
    /// drift into glass-as-decoration: a second `glassEffect` call site is a design regression,
    /// not a styling choice. On macOS 26 the system supplies the lensing, the hover and press
    /// responses and the Reduce Transparency / Increase Contrast adaptations; on macOS 15 the
    /// same shape draws `fallback`, a tinted fill from the palette, so the hierarchy survives
    /// without the material.
    ///
    /// The fallback is a parameter, not a hidden default, because what a control falls back to
    /// depends on what sits behind it: a selected tab needs the palette's selected fill, a command
    /// chip needs its own tint.
    @ViewBuilder
    func hisControlGlass<S: Shape>(in shape: S, fallback: Color) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// Window-level glass for the one surface that floats over the desktop: the charging mini
    /// panel. The window itself supplies the shadow; the glass supplies the material, sampling
    /// whatever is behind it. On macOS 15 it falls back to the panel material, and under Reduce
    /// Transparency or Increase Contrast both paths go opaque with ``HisingenTheme/panelFill``,
    /// the same contract ``PopoverSurface`` keeps for the main panel.
    @ViewBuilder
    func hisFloatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlassModifier(shape: shape))
    }
}

/// The body of ``View/hisFloatingGlass(in:)``, split out so the fallback can read the
/// accessibility environment; a plain `View` extension cannot.
private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // The system adapts glass to the appearance, but Reduce Transparency and Increase
            // Contrast are app-honored promises here: the mini panel goes opaque like the
            // macOS 15 path below instead of staying translucent.
            if reduceTransparency || contrast == .increased {
                content.background(HisingenTheme.panelFill, in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else if reduceTransparency || contrast == .increased {
            content.background(HisingenTheme.panelFill, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}