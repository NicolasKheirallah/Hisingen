import SwiftUI

@MainActor
struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// Reduce Transparency asks for the specular rim to be dropped, because the rim exists to sell a
    /// glass edge and there is no glass edge once the surface is solid. Increase Contrast is handled
    /// separately, by `borderWidth`/`cardBoundary`, since it wants a *defined* edge rather than no
    /// edge. The card fill itself is opaque in every case — see `cardSurface`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var prefersOpaqueSurfaces: Bool {
        reduceTransparency || contrast == .increased
    }

    /// A defined boundary is the other half of Increase Contrast: a hairline that reads
    /// as a hairline is not an edge for someone who asked for more contrast.
    private var borderWidth: CGFloat {
        contrast == .increased ? max(1, HisingenTheme.cardBorderWidth) : HisingenTheme.cardBorderWidth
    }

    var body: some View {
        let radius = HisingenTheme.cornerRadius
        // The surface, the rim and the shadow all come from the theme, which is the only place
        // that knows what a card looks like for this appearance.
        let shadow = HisingenTheme.shadow(for: .card)
        content
            .padding(HisingenTheme.cardPadding)
            .background {
                HisingenTheme.cardSurface(cornerRadius: radius)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                ZStack {
                    HisingenTheme.cardRim(cornerRadius: radius, prefersOpaque: prefersOpaqueSurfaces)
                    HisingenTheme.cardBoundary(increasedContrast: contrast == .increased)
                }
            )
            // The shadow is attached through a modifier that drops it when there is nothing to draw.
            // Every theme used to resolve to a shadow except Polestar, which resolved to a clear one
            // at radius 0 — and `.shadow` still cost a compositing pass on each of the app's 94
            // cards for that nothing. Shadow is a global token now, so the modifier always draws,
            // but it stays as the single place that would change if a flat theme returned.
            .modifier(CardShadow(color: shadow.color, radius: shadow.radius, y: shadow.y))
    }
}

/// Attaches a layer shadow only when there is one to attach.
///
/// `Color.clear` at radius 0 is not free: `.shadow` still asks the renderer to prepare the layer.
/// That used to matter for one theme, whose flat identity resolved to a clear shadow at radius 0 on
/// every card in the app. Radius is a global token now and is never 0, so this always draws; the
/// guard remains as the single place a flat treatment would be reintroduced.
private struct CardShadow: ViewModifier {
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    private var isVisible: Bool { radius > 0 }

    func body(content: Content) -> some View {
        if isVisible {
            content.shadow(color: color, radius: radius, x: 0, y: y)
        } else {
            content
        }
    }
}

struct CardHeader: View {
    let symbol: String
    let title: String
    let color: Color
    var isSemantic: Bool = false
    var isPulsing: Bool = false
    /// Optional trailing detail, e.g. how many rows a warning card holds. A bare title made the
    /// card the same shape whether it held one row or ten.
    var detail: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(isSemantic ? color : HisingenTheme.decorativeTint(color))
                .hisType(.heading, weight: HisingenTheme.headingWeight)
                // A quiet breath, not a throb: a ~6 % swell on a slow cycle.
                .scaleEffect(isPulsing && pulse ? 1.06 : 1.0)
                .shadow(color: isPulsing && pulse ? color.opacity(0.45) : .clear, radius: 3)
                .animation(
                    Motion.resolve(isPulsing ? Motion.breath : nil),
                    value: pulse
                )
                .onAppear {
                    if isPulsing && !reduceMotion {
                        pulse = true
                    }
                }
            Text(title)
                .hisType(.heading, weight: HisingenTheme.headingWeight)
                .foregroundStyle(HisingenTheme.ink)
            if let detail {
                Text(detail)
                    .hisType(.caption, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        // A card's heading is read first whatever order the body was built in. Without a priority
        // the reading order is construction order, which put a footnote before a headline in the
        // composite cards that build their rows conditionally.
        .accessibilitySortPriority(2)
    }
}
