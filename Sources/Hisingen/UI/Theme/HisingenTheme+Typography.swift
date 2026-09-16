import SwiftUI

@MainActor
extension HisingenTheme {

    /// The global weight ladder: heading, the reading under it, and small print.
    ///
    /// Frozen alongside geometry so that choosing a palette alters colour only, and never
    /// re-proportions the app's type hierarchy.
    private static var weightLadder: (heading: Font.Weight, value: Font.Weight, caption: Font.Weight) {
        (.semibold, .bold, .semibold)
    }

    static var headingWeight: Font.Weight { weightLadder.heading }

    static var valueWeight: Font.Weight { weightLadder.value }

    /// Optical tracking for small text, from Apple's SF Pro Text table: about +0.24pt at 6pt,
    /// falling linearly to zero at 12pt, where the face's own spacing is already correct.
    ///
    /// §15's compensating mechanism for small type was applied at three sites in the whole app while
    /// 207 of 713 font call sites sat at 9.5pt or below — the app's dominant text size, not an edge
    /// case — and zero tracking on an already-tight face at 9pt is where legibility actually
    /// degrades. Above 12pt this returns 0; the display tiers use ``displayTracking(forSize:)``,
    /// which is negative for the same reason.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        guard size < 12 else { return 0 }
        return (12 - size) * 0.04
    }

    /// Extra leading for text that wraps.
    ///
    /// The app had exactly one leading — SwiftUI's ≈1.19× default — for a 40pt hero number and a
    /// 9.5pt explanatory paragraph alike, because `.lineSpacing(` appeared zero times. The damage is
    /// at the small end, and in a localized app: Swedish and German strings carry taller ascenders
    /// and descenders than English at the same point size.
    static var captionLineSpacing: CGFloat { 2 }

    /// Weight for text below 10pt.
    ///
    /// The shared layer has thirteen sites at 9.5pt or smaller and several of them were lighter
    /// than the body they sat under, which is backwards: less size has to be paid for with more
    /// weight, not less.
    static var captionWeight: Font.Weight { weightLadder.caption }

    /// Global display weight for large figures and titles.
    static var displayWeight: Font.Weight { .bold }

    /// Display tracking, expressed as a ratio of the type size.
    ///
    /// A ratio keeps the optical relationship constant: `size * ratio` is a fixed em value, so a
    /// 34pt figure tracks 15% tighter in points than a 40pt one and identically in proportion.
    static var displayTrackingRatio: CGFloat { -0.011 }

    /// Tracking in points for a given size. Use this rather than a raw value so the relationship
    /// to size cannot be lost at the call site.
    static func displayTracking(forSize size: CGFloat) -> CGFloat {
        size * displayTrackingRatio
    }

    // MARK: - Shared-layer type ramp

    /// The shared layer's type tiers.
    ///
    /// The 21 component files froze roughly 42 font declarations at eight different point sizes —
    /// 8.5, 9, 9.5, 10, 10.5, 11, 12, 13 — and only two of the 21 primitives responded to the
    /// reader's text size at all, so a card title stayed fixed while the caption inside it grew.
    /// Five tiers replace the eight one-off sizes, and every one of them scales.
    enum TypeTier: CaseIterable {
        /// The smallest annotations. Was 7, 8 and 8.5.
        case nano
        /// Badges, counters, axis labels. Was 9 and 9.5.
        case micro
        /// A secondary line under a value. Was 10 and 10.5.
        case caption
        /// Row labels and banner titles. Was 11 and 11.5.
        case label
        /// Card prose. Was 12 and 12.5.
        case body
        /// Card headings.
        case heading
        /// A subheading inside a card.
        case subhead
        /// A card's own title line. Was 15 and 16.
        case title
        /// A section title on a data surface. Was 17 and 18.
        case displaySmall

        var baseSize: CGFloat {
            switch self {
            case .nano: return 8
            case .micro: return 9
            case .caption: return 10
            case .label: return 11
            case .body: return 12
            case .heading: return 13
            case .subhead: return 14
            case .title: return 15
            case .displaySmall: return 17
            }
        }

        /// The system style each tier scales relative to, so a reader who raises their text size
        /// gets proportionally larger type rather than a frozen 9pt.
        var textStyle: Font.TextStyle {
            switch self {
            case .nano, .micro: return .caption2
            case .caption: return .caption
            case .label: return .subheadline
            case .body: return .body
            case .heading: return .headline
            case .subhead: return .subheadline
            case .title: return .title3
            case .displaySmall: return .title2
            }
        }
    }
}

/// Applies a shared-layer type tier, scaled to the reader's text size.
///
/// A `ViewModifier` rather than a function because `@ScaledMetric` needs a view's lifetime to
/// observe the setting; that is also why the tier is a token rather than a literal at each site.
struct HisingenScaledType: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @Environment(\.preferencesStore) private var preferences
    private let weight: Font.Weight
    private let design: Font.Design

    init(tier: HisingenTheme.TypeTier, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: tier.baseSize, relativeTo: tier.textStyle)
        self.weight = weight
        self.design = design
    }

    /// The reader's text-size setting first, then the density preset on top of it. The order
    /// matters: density is a layout preference and must not undo a text-size choice, so it is a
    /// modest multiplier on an already-scaled value rather than a replacement for it.
    private var renderedSize: CGFloat {
        size * preferences.contentDensity.typeScale
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: renderedSize, weight: weight, design: design))
            // Tracking follows the *rendered* size, so a reader who enlarges their text gets the
            // same optical relationship the fixed sizes were tuned for instead of a 9pt tracking
            // value applied to 13pt type.
            .tracking(HisingenTheme.tracking(forSize: renderedSize))
    }
}

extension View {
    /// Sets a shared-layer type tier, scaled to the reader's text size.
    @MainActor
    func hisType(
        _ tier: HisingenTheme.TypeTier,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(HisingenScaledType(tier: tier, weight: weight, design: design))
    }
}
