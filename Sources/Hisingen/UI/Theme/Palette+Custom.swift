import AppKit
import SwiftUI

/// sRGB components in 0...1, with the WCAG arithmetic a reader-made theme is held to.
struct ThemeRGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static let white = ThemeRGB(r: 1, g: 1, b: 1)
    static let black = ThemeRGB(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", locale: L10n.displayLocale,
               Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func contrast(with other: ThemeRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `t` of the way from self to `other`.
    func mixed(with other: ThemeRGB, _ t: Double) -> ThemeRGB {
        ThemeRGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// The surface arithmetic ``Palette/cardFill`` and ``Palette/chipFill`` use.
    func surface(lift: Double, sink: Double) -> ThemeRGB {
        func channel(_ v: Double) -> Double { (v + (1 - v) * lift) * (1 - sink) }
        return ThemeRGB(r: channel(r), g: channel(g), b: channel(b))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// The colours a reader-made theme resolves to, before they become a ``Palette``. Split out so
/// the contrast guarantees can be tested without SwiftUI.
struct CustomThemeColors: Sendable, Equatable {
    var canvasLight: ThemeRGB
    var canvasDark: ThemeRGB
    var inkLight: ThemeRGB
    var inkDark: ThemeRGB
    var mutedLight: ThemeRGB
    var mutedDark: ThemeRGB
    var accentLight: ThemeRGB
    var accentDark: ThemeRGB
    /// Whether any picked colour had to move to stay readable.
    var adjusted: Bool

    /// The text floor plus a margin, so rounding in the stored hex never drops a pair below 4.5:1.
    static let textFloor = 4.7

    static func resolve(_ definition: CustomThemeDefinition) -> CustomThemeColors {
        let pickedAccent = ThemeRGB(hex: definition.accentHex) ?? ThemeRGB(r: 0.71, g: 0.47, b: 0.06)
        let pickedLight = ThemeRGB(hex: definition.lightBackgroundHex) ?? .white
        let pickedDark = ThemeRGB(hex: definition.darkBackgroundHex) ?? .black

        // Backgrounds stay backgrounds: a light canvas at least as bright as a pale tint, a dark
        // canvas at most a deep tint. A colour outside that band moves toward white or black.
        let canvasLight = step(pickedLight, toward: .white, until: { $0.luminance >= 0.80 })
        let canvasDark = step(pickedDark, toward: .black, until: { $0.luminance <= 0.03 })

        let inkLight = ThemeRGB(r: 0.07, g: 0.07, b: 0.07)
        let inkDark = ThemeRGB(r: 0.94, g: 0.94, b: 0.94)

        let lightSurfaces = surfaces(canvas: canvasLight, cardLift: 0.55, chipSink: 0.05)
        let darkSurfaces = surfaces(canvas: canvasDark, cardLift: 0.16, chipSink: 0.28)

        // Muted text starts as a soft mix of ink into the canvas and firms up until it reads on
        // every surface it can sit on.
        let mutedLight = firmest(from: inkLight.mixed(with: canvasLight, 0.5), toward: inkLight, on: lightSurfaces)
        let mutedDark = firmest(from: inkDark.mixed(with: canvasDark, 0.5), toward: inkDark, on: darkSurfaces)

        // The accent is also text (links, selected labels), including on its own 12 % wash.
        let accentLight = step(pickedAccent, toward: .black) { accent in
            (lightSurfaces + [canvasLight.mixed(with: accent, 0.12)]).allSatisfy { accent.contrast(with: $0) >= textFloor }
        }
        let accentDark = step(pickedAccent, toward: .white) { accent in
            (darkSurfaces + [canvasDark.mixed(with: accent, 0.12)]).allSatisfy { accent.contrast(with: $0) >= textFloor }
        }

        let adjusted = canvasLight != pickedLight || canvasDark != pickedDark
            || accentLight != pickedAccent || accentDark != pickedAccent
        return CustomThemeColors(canvasLight: canvasLight, canvasDark: canvasDark,
                                 inkLight: inkLight, inkDark: inkDark,
                                 mutedLight: mutedLight, mutedDark: mutedDark,
                                 accentLight: accentLight, accentDark: accentDark, adjusted: adjusted)
    }

    private static func surfaces(canvas: ThemeRGB, cardLift: Double, chipSink: Double) -> [ThemeRGB] {
        [canvas, canvas.surface(lift: cardLift, sink: 0), canvas.surface(lift: cardLift, sink: chipSink)]
    }

    /// Moves `color` toward `target` in small steps until `done`, or reaches the target.
    private static func step(_ color: ThemeRGB, toward target: ThemeRGB, until done: (ThemeRGB) -> Bool) -> ThemeRGB {
        var current = color
        for _ in 0..<40 where !done(current) {
            current = current.mixed(with: target, 0.08)
        }
        return done(current) ? current : target
    }

    private static func firmest(from start: ThemeRGB, toward ink: ThemeRGB, on surfaces: [ThemeRGB]) -> ThemeRGB {
        step(start, toward: ink) { muted in surfaces.allSatisfy { muted.contrast(with: $0) >= textFloor } }
    }
}

extension Palette {
    /// A reader-made theme's palette. The picked colours set its character; ``CustomThemeColors``
    /// decides the exact values so every text pair clears 4.5:1 in both appearances.
    static func custom(_ definition: CustomThemeDefinition) -> Palette {
        let c = CustomThemeColors.resolve(definition)
        func tuple(_ rgb: ThemeRGB) -> (r: Double, g: Double, b: Double) { (rgb.r, rgb.g, rgb.b) }
        func on(_ fill: ThemeRGB) -> NSColor {
            fill.contrast(with: .white) >= fill.contrast(with: .black) ? .white : .black
        }
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Palette(
            theme: .custom(definition.id),
            name: name.isEmpty ? L10n.text("My Theme") : name,
            subtitle: L10n.text("Your colours, adjusted to stay readable in light and dark."),
            category: .custom,
            accentHex: c.accentLight.hex,
            swatches: [c.accentLight.hex, c.canvasLight.hex, c.canvasDark.hex],
            canvas: Color(light: c.canvasLight.nsColor, dark: c.canvasDark.nsColor),
            ink: Color(light: c.inkLight.nsColor, dark: c.inkDark.nsColor),
            inkMuted: Color(light: c.mutedLight.nsColor, dark: c.mutedDark.nsColor),
            hairline: Color(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.16)),
            accent: Color(light: c.accentLight.nsColor, dark: c.accentDark.nsColor),
            accentOn: Color(light: on(c.accentLight), dark: on(c.accentDark)),
            chartPositive: Palette.hisingen.chartPositive,
            chartInfo: Palette.hisingen.chartInfo,
            chartAttention: Palette.hisingen.chartAttention,
            chartHealth: Palette.hisingen.chartHealth,
            canvasLightRGB: tuple(c.canvasLight), canvasDarkRGB: tuple(c.canvasDark),
            inkLightRGB: tuple(c.inkLight), inkDarkRGB: tuple(c.inkDark),
            inkMutedLightRGB: tuple(c.mutedLight), inkMutedDarkRGB: tuple(c.mutedDark)
        )
    }
}
