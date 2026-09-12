import SwiftUI

struct UnavailableFeatureCard: View {
    let symbol: String
    let title: String
    let color: Color
    let badge: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: symbol, title: title, color: color)
                CapabilityBadge(title: badge, state: .unavailable)
            }
        }
    }

    static func make(
        state: VehicleState,
        feature: AppFeature?,
        symbol: String,
        title: String,
        color: Color,
        badge: String
    ) -> AnyView? {
        let reportedUnavailable = feature.map {
            state.freshness.unavailableFeatures.contains($0)
        } ?? false
        guard state.freshness.isCached || reportedUnavailable else { return nil }
        return AnyView(Self(symbol: symbol, title: title, color: color, badge: badge))
    }
}
