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
        // The 12 % wash is the ceiling the token's 4.5:1 guarantee covers (checked by
        // Scripts/verify-app-contrast.py); the outline the chip used to draw over it said what
        // the fill already said, and outlines are not part of the 2026 surface language.
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
