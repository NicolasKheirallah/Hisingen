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
            // Deliberately below `card`. It used to be 0.08 against the card's combined 0.07.
            return (shadowTint(isPolestar ? 0 : 0.04), 1.5, 1)
        case .card:
            // One shadow, not two: the old pair composed to about 0.07 spread over two passes, and
            // two stacked `.shadow` modifiers mean two offscreen renders for that result.
            return (shadowTint(cardShadowOpacity), cardShadowRadius, 3)
        case .floating:
            // Not theme-flattened: this is a window over an arbitrary desktop, not a card over the
            // canvas, so Polestar's flat-card language does not apply to it.
            return (shadowTint(0.18), 8, 3)
        }
    }

    /// The card surface in full: material, wash and specular rim, for a given corner radius and
    /// opacity preference.
    ///
    /// `Card` used to hardcode this as a nine-way theme switch while `cardBackground` defined the
    /// same surface a second time for the one call site that used it, and the two disagreed:
    /// `.hisingen` returned a bare material from the token and a material plus a specular wash from
    /// the component, `.volvo` an opaque colour from one and a gradient from the other. A card is
    /// the most repeated surface in the app, so two answers meant editing the token changed one
    /// screen and nothing else. There is one answer now, and every card path reads it.
    @ViewBuilder
    static func cardSurface(cornerRadius radius: CGFloat, prefersOpaque: Bool) -> some View {
        ZStack {
            if theme == .hisingen, !prefersOpaque {
                // Apple Liquid Glass dynamic material, plus a specular light wash.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(light: NSColor(white: 1.0, alpha: 0.45), dark: NSColor(white: 1.0, alpha: 0.05)),
                                Color(light: NSColor(white: 1.0, alpha: 0.10), dark: NSColor(white: 0.0, alpha: 0.12))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else if theme == .polestar {
                // Polestar stark minimalist architectural panel: square, opaque, no wash.
                // No `.continuous` on a zero radius: the curve has nothing to round, and asking
                // for it costs the renderer work on every one of the app's 94 cards.
                Rectangle()
                    .fill(Color(light: NSColor.white, dark: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)))
            } else if theme == .volvo, !prefersOpaque {
                // Volvo frosted glass with a subtle iron navy wash.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(light: NSColor(white: 1.0, alpha: 0.75), dark: NSColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.65)),
                                Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 0.45), dark: NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 0.45))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                // Frosted glass tinted with the theme canvas, or an opaque canvas surface when the
                // user has asked for one.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(canvas.opacity(prefersOpaque ? 1.0 : 0.60))
            }
        }
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
    /// `verify-app-contrast.py` recomputes all thirty-six of those ratios from this file.
    static let cardBoundaryIncreased = Color(
        light: NSColor(white: 0.5216, alpha: 1),
        dark: NSColor(white: 0.4118, alpha: 1)
    )

    /// A boundary drawn at the width of a boundary, not of a hairline.
    static var cardBoundaryIncreasedWidth: CGFloat { 1 }

    /// Corner radius for a full-width notice banner.
    ///
    /// The banner hardcoded 10, so it kept rounded corners in the theme whose entire identity is
    /// sharp corners — on the most prominent element a new reader sees, since the banner sits at
    /// the top of the Controls tab.
    static var bannerRadius: CGFloat { cornerRadius == 0 ? 0 : 10 }

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
    /// ``StateSummaryChip`` render side by side in the vehicle hero. A theme with square
    /// corners still gets square chips.
    static var statusChipRadius: CGFloat { cornerRadius == 0 ? 0 : 8 }

    /// Fill for a chip, badge or callout that sits on top of a card.
    ///
    /// These were a third translucent material stacked on the card's material on the panel's
    /// material. §12 forbids stacking light translucent surfaces because legibility collapses,
    /// and the worst case was the hero badge over a photograph. A chip only has to separate
    /// from the card behind it, not from the desktop behind that, so it is opaque.
    static var chipFill: AnyShapeStyle { AnyShapeStyle(canvas) }

    static var cardBorderWidth: CGFloat {
        switch theme {
        case .hisingen: return 0.5
        default: return 1
        }
    }
    static var cardShadowOpacity: Double {
        switch theme {
        case .polestar: return 0
        case .volvo: return 0.03
        default: return 0.04
        }
    }
    static var cardShadowRadius: CGFloat {
        switch theme {
        case .polestar: return 0
        case .volvo: return 4
        default: return 6
        }
    }

    // MARK: - Popover Surface

    /// Full-bleed popover surface. The Hisingen glass theme layers Apple's translucent
    /// material with a specular light wash and a soft vignette so the window reads as
    /// clear Liquid Glass over the desktop (the popover backing itself is cleared in
    /// StatusItemController.showPopover). Other themes keep their opaque canvas.
    @ViewBuilder
    static var popoverSurface: some View {
        PopoverSurface()
    }
}

/// The popover's own surface, as a view rather than a token, because the decision
/// depends on the environment: Reduce Transparency and Increase Contrast both ask for
/// an opaque surface, and a static token cannot see either. Glass is the app's identity;
/// it is not worth someone's legibility.
@MainActor
struct PopoverSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var prefersOpaqueSurface: Bool {
        reduceTransparency || contrast == .increased || HisingenTheme.theme != .hisingen
    }

    var body: some View {
        if prefersOpaqueSurface {
            Rectangle().fill(HisingenTheme.canvas)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    stops: [
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.50), dark: NSColor(white: 1.0, alpha: 0.07)), location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Color(light: NSColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 0.05), dark: NSColor(white: 0.0, alpha: 0.16)), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}
