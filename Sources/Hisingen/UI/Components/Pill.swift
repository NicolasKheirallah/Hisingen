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
        // The 12 % wash is the ceiling the token's 4.5:1 guarantee covers (checked by
        // Scripts/verify-app-contrast.py); the outline the chip used to draw over it said what
        // the fill already said, and outlines are not part of the 2026 surface language.
        .statusChipSurface(tint: color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
