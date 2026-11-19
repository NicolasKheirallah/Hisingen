import SwiftUI

extension EnvironmentValues {
    @Entry var historyCardEmbedded = false
}

@MainActor
struct HistoryCardSurface<Content: View>: View {
    @Environment(\.historyCardEmbedded) private var embedded
    @ViewBuilder let content: () -> Content

    var body: some View {
        if embedded {
            content()
        } else {
            Card(content: content)
        }
    }
}

@MainActor
struct HistorySectionHeading: View {
    let symbol: String
    let title: String
    let color: Color

    @Environment(\.historyCardEmbedded) private var embedded

    var body: some View {
        if embedded {
            Text(title)
                .hisType(.subhead, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(2)
        } else {
            CardHeader(symbol: symbol, title: title, color: color)
        }
    }
}
