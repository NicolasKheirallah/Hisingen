import SwiftUI

/// A section that cannot show its data, and why.
///
/// The card used to say only "Temporarily unavailable" for every cause, so a cached snapshot
/// and a vehicle that will never report the capability looked identical, and neither explained
/// itself or offered a route out. §16 wayfinding asks a dead end to say what happened.
struct UnavailableFeatureCard: View {
    let symbol: String
    let title: String
    let color: Color
    let badge: String
    /// Why this section has no data. Nil only if the caller genuinely has nothing to add.
    var message: String? = nil
    /// Derived from the cause by `make`, not fixed: a cached snapshot is temporary, a capability
    /// the provider never reported is not.
    var state: CapabilityState = .unavailable

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: symbol, title: title, color: color)
                CapabilityBadge(title: badge, state: state)
                if let message {
                    Text(message)
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func make(
        state: VehicleState,
        feature: AppFeature?,
        symbol: String,
        title: String,
        color: Color,
        badge: String,
        message: String? = nil
    ) -> AnyView? {
        let reportedUnavailable = feature.map {
            state.freshness.unavailableFeatures.contains($0)
        } ?? false
        // A caller that supplies a reason is asserting there is one, so the card renders even
        // when the snapshot is live. Without that, a live snapshot with no rows produced no
        // section at all: not a placeholder, not an explanation, nothing.
        guard state.freshness.isCached || reportedUnavailable || message != nil else { return nil }
        let capability: CapabilityState = reportedUnavailable ? .unsupported : .unavailable
        let explanation = message ?? (reportedUnavailable
            ? L10n.text("This vehicle did not report this capability on the last refresh.")
            : L10n.text("Showing cached data. This section returns when the next refresh succeeds."))
        return AnyView(Self(
            symbol: symbol, title: title, color: color, badge: badge,
            message: explanation, state: capability
        ))
    }
}
