import SwiftUI

struct Pill: View {
    let text: String
    let color: Color
    let symbol: String?
    init(text: String, color: Color, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }
    var body: some View {
        let radius = HisingenTheme.statusChipRadius
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .hisType(.micro, weight: .semibold)
                    .accessibilityHidden(true)
            }
            Text(text)
                .hisType(.caption, weight: HisingenTheme.valueWeight)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
