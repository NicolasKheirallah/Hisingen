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

    /// This colour lifted toward `other` by `amount`. See `NSColor.mixed(with:amount:)`.
    func mixed(with other: NSColor, amount: CGFloat) -> Color {
        Color(NSColor(self).mixed(with: other, amount: amount))
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

extension NSColor {
    /// This colour lifted toward `other` by `amount`, component by component in sRGB.
    ///
    /// Used for elevation: a raised surface in a dark appearance is the canvas moved *toward
    /// white*, and writing that as a mix keeps the relationship visible in the token instead of
    /// hiding it in nine sets of hand-tuned numbers that can drift apart.
    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        guard let base = usingColorSpace(.sRGB), let target = other.usingColorSpace(.sRGB) else { return self }
        let t = min(max(amount, 0), 1)
        return NSColor(
            srgbRed: base.redComponent + (target.redComponent - base.redComponent) * t,
            green: base.greenComponent + (target.greenComponent - base.greenComponent) * t,
            blue: base.blueComponent + (target.blueComponent - base.blueComponent) * t,
            alpha: base.alphaComponent
        )
    }
}
