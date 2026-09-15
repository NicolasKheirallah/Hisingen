import SwiftUI

@MainActor
struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// Reduce Transparency and Increase Contrast both ask for the same thing at this
    /// layer: stop compositing the card out of a blur, and let it be a surface. Apple
    /// answers both by making the material frostier or solid, so the two are handled
    /// together here rather than each being half-implemented.
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
        // that knows what a card looks like for this theme and this appearance.
        let shadow = HisingenTheme.shadow(for: .card)
        content
            .padding(HisingenTheme.cardPadding)
            .background {
                HisingenTheme.cardSurface(cornerRadius: radius, prefersOpaque: prefersOpaqueSurfaces)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                ZStack {
                    HisingenTheme.cardRim(cornerRadius: radius, prefersOpaque: prefersOpaqueSurfaces)
                    HisingenTheme.cardBoundary(increasedContrast: contrast == .increased)
                }
            )
            // The flat theme resolves to a clear shadow at radius 0, and applying `.shadow`
            // anyway still costs a compositing pass on every one of the app's 94 cards. The
            // modifier is only attached when there is a shadow to draw.
            .modifier(CardShadow(color: shadow.color, radius: shadow.radius, y: shadow.y))
    }
}

/// Attaches a layer shadow only when there is one to attach.
///
/// `Color.clear` at radius 0 is not free: `.shadow` still asks the renderer to prepare the layer,
/// and the theme whose identity is flat resolved to exactly that on every card in the app.
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
