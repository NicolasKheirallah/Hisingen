import SwiftUI

@MainActor
struct SettingsConnectedServiceCard<Content: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: symbol, title: L10n.text(title), color: HisingenTheme.semanticGood)
                Text(L10n.text(detail))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}
