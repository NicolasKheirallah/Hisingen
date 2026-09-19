import SwiftUI

/// A section: the app's one content grouping, and the whole card grammar.
///
/// In the 2026 language a section is *not a surface*. The panel's glass is the only surface, and
/// a section is a group of content on it: header, rows, values, separated by whitespace and
/// inset dividers — the grammar of Apple's own popovers and Control Center. The boxed card this
/// replaced drew a fill, an outline, a specular rim and an inner shadow on every one of the
/// app's ~106 sections, and none of it survived contact with the question "what is the box
/// for?" — grouping is the job of spacing and typography, and it reads.
///
/// This is also why the vehicle hero needs no special case: it is a `Card` like everything
/// else, so dropping the box freed the scene onto the glass with the rest of the panel.
///
/// Increase Contrast is the one exception, drawn by ``HisingenTheme/cardBoundary(increasedContrast:)``:
/// a reader who asked for more contrast gets a defined 3:1 boundary around each group, which
/// whitespace alone cannot promise.
@MainActor
struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(HisingenTheme.cardPadding)
            .overlay {
                HisingenTheme.cardBoundary(increasedContrast: contrast == .increased)
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
