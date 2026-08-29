import SwiftUI
import AppKit

extension Color {

    /// Resolves to `light` or `dark` at draw time based on the view's effective
    /// appearance, so a single token adapts to macOS Light / Dark mode.
    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            let isDark: Bool
            if let match = appearance.bestMatch(from: [.darkAqua, .aqua]) {
                isDark = (match == .darkAqua)
            } else {
                isDark = appearance.name.rawValue.lowercased().contains("dark")
            }
            return isDark ? dark : light
        }))
    }

    /// Parses a 6-digit `RRGGBB` hex string (a leading `#` is optional).
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexSanitized.hasPrefix("#") {
            hexSanitized.remove(at: hexSanitized.startIndex)
        }
        guard hexSanitized.count == 6, let rgbValue = UInt64(hexSanitized, radix: 16) else { return nil }
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
