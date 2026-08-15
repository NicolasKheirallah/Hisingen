import AppKit


enum Theme {
    static let cornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12

    static func symbol(_ name: String, pointSize: CGFloat = 13,
                       weight: NSFont.Weight = .medium, color: NSColor? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        guard let color else {
            image.isTemplate = true
            return image
        }
        image.isTemplate = false
        return image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
    }

    @MainActor
    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}


