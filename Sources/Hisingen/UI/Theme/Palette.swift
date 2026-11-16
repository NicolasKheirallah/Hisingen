import SwiftUI
import AppKit

/// A theme's complete token set: colours, metadata, chart tokens, and interaction states.
///
/// A single deep module defining what a theme is, replacing fragmented switches across the UI layer.
struct Palette: Sendable {
    let theme: AppTheme
    let name: String
    let subtitle: String
    let category: ThemeCategory
    let accentHex: String
    let swatches: [String]

    // Core colours
    let canvas: Color
    let ink: Color
    let inkMuted: Color
    let hairline: Color
    let accent: Color
    let accentOn: Color

    // Chart series
    let chartPositive: Color
    let chartInfo: Color
    let chartAttention: Color
    let chartHealth: Color

    // Raw RGB values for contrast auditing and verification
    let canvasLightRGB: (r: Double, g: Double, b: Double)
    let canvasDarkRGB: (r: Double, g: Double, b: Double)
    let inkLightRGB: (r: Double, g: Double, b: Double)
    let inkDarkRGB: (r: Double, g: Double, b: Double)
    let inkMutedLightRGB: (r: Double, g: Double, b: Double)
    let inkMutedDarkRGB: (r: Double, g: Double, b: Double)

    /// The card's fill: this theme's canvas lifted toward white.
    ///
    /// Both lifts are *fractions of the distance to white* applied to the canvas — 55 % in the
    /// light appearance, 16 % in the dark — so a card carries the theme's hue instead of only its
    /// lightness. The dark fill used to be one fixed blue-grey for all nine themes, which rendered
    /// Gothenburg Forest's green, Sand Dune's warmth and Nordic Night's black under the same cool
    /// card, and contradicted the note it carried about being "a lift, not a colour".
    ///
    /// The two lifts differ because perceived lightness is not linear in sRGB: the same fraction
    /// toward white reads as a large step on a black canvas and a subtle one on a near-white
    /// canvas, which is what keeps the card legible as a raised surface in both appearances.
    ///
    /// Derived from the raw canvas components rather than by mixing the dynamic ``canvas`` colour,
    /// which would resolve against whatever appearance happened to be current when the body was
    /// evaluated rather than the one the card is drawn in.
    var cardFill: Color {
        Color(
            light: Self.surface(canvasLightRGB, lift: 0.55, sink: 0),
            dark: Self.surface(canvasDarkRGB, lift: 0.16, sink: 0)
        )
    }

    /// The chip's fill: ``cardFill`` sunk toward black — 5 % in light, 28 % in dark.
    ///
    /// A chip, badge or callout sits *on* a card, so it separates from the card and not from the
    /// desktop. Derived from the same lift as the card so the inset tracks its hue: a fixed neutral
    /// inset collided with Nordic Night's lifted grey card, where the two landed at nearly the same
    /// luminance and the chip stopped reading as inset at all.
    var chipFill: Color {
        Color(
            light: Self.surface(canvasLightRGB, lift: 0.55, sink: 0.05),
            dark: Self.surface(canvasDarkRGB, lift: 0.16, sink: 0.28)
        )
    }

    // The vehicle render sits on a matte field set apart from the readings and commands.
    var studioFill: Color {
        Color(
            light: Self.surface(canvasLightRGB, lift: 0, sink: 0.063),
            dark: Self.surface(canvasDarkRGB, lift: 0.10, sink: 0)
        )
    }

    /// A canvas component lifted `lift` of the way to white, then sunk `sink` of the way to black.
    private static func surface(
        _ c: (r: Double, g: Double, b: Double),
        lift: Double,
        sink: Double
    ) -> NSColor {
        func channel(_ v: Double) -> Double {
            let raised = v + (1 - v) * lift
            return raised * (1 - sink)
        }
        return NSColor(srgbRed: channel(c.r), green: channel(c.g), blue: channel(c.b), alpha: 1)
    }

    /// The fill of anything live: an active control card and the charge line while charging. It is
    /// the theme's accent, so a running climate session or a charge reads in the colour the reader
    /// chose. Monochrome Precision's accent is ink, which would make an active card look like a
    /// pressed key, so that theme uses a warm amber instead.
    var activeFill: Color {
        theme == .polestar ? Self.polestarActive : accent
    }

    /// Text and symbols on ``activeFill``. Black on the amber measures 5.6:1 (light) and 10:1
    /// (dark). Every other theme writes in its canvas colour, the pairing the primary button uses:
    /// the contrast gate holds each accent to 4.5:1 against its canvas, and contrast is symmetric.
    var activeOn: Color {
        theme == .polestar ? Color.black : canvas
    }

    static let polestarActive = Color(
        light: NSColor(red: 0.7098, green: 0.4667, blue: 0.0588, alpha: 1),
        dark: NSColor(red: 0.9098, green: 0.6627, blue: 0.2275, alpha: 1)
    )

    /// Fill style for a surface in an interactive state.
    ///
    /// Selection and hover are held at or below 12 % accent, because an accent-tinted surface that
    /// carries accent-coloured text is only covered by ``accent``'s 4.5:1 guarantee up to that
    /// opacity — see the note on that token.
    func fill(_ state: SurfaceState) -> Color {
        switch state {
        case .ghost:
            return Color(light: NSColor(white: 0.0, alpha: 0.04), dark: NSColor(white: 1.0, alpha: 0.06))
        case .inset:
            return chipFill
        case .selected:
            return accent.opacity(0.12)
        case .hovered:
            return accent.opacity(0.08)
        case .active:
            return accent.opacity(0.12)
        }
    }

    /// Boundary stroke for a surface in an interactive state.
    func stroke(_ state: SurfaceState) -> Color {
        switch state {
        case .ghost, .inset:
            return hairline
        case .selected, .active:
            return accent
        case .hovered:
            return accent.opacity(0.50)
        }
    }
}

// MARK: - Per-Theme Definitions

extension Palette {
    /// The default instrument uses neutral grey in both appearances and a functional orange.
    /// The lighter appearance needs a deeper signal colour where it also carries small text.
    static let hisingen = Palette(
        theme: .hisingen,
        name: L10n.text("Hisingen"),
        subtitle: L10n.text("Monochrome panels, high-contrast type, Scandinavian minimalism"),
        category: .brand,
        accentHex: "#FFAA7A",
        swatches: ["#FFAA7A", "#F7F7F7", "#151515"],
        canvas: Color(light: NSColor(red: 0.969, green: 0.969, blue: 0.969, alpha: 1), dark: NSColor(red: 0.082, green: 0.082, blue: 0.082, alpha: 1)),
        ink: Color(light: NSColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1), dark: NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)),
        inkMuted: Color(light: NSColor(red: 0.33, green: 0.33, blue: 0.33, alpha: 1), dark: NSColor(red: 0.69, green: 0.69, blue: 0.69, alpha: 1)),
        hairline: Color(light: NSColor(white: 0.0, alpha: 0.16), dark: NSColor(white: 1.0, alpha: 0.18)),
        accent: Color(light: NSColor(red: 0.64, green: 0.225, blue: 0.040, alpha: 1), dark: NSColor(red: 1.0, green: 0.667, blue: 0.478, alpha: 1)),
        accentOn: Color(light: .white, dark: .black),
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.969, 0.969, 0.969), canvasDarkRGB: (0.082, 0.082, 0.082),
        inkLightRGB: (0.075, 0.075, 0.075), inkDarkRGB: (0.93, 0.93, 0.93),
        inkMutedLightRGB: (0.33, 0.33, 0.33), inkMutedDarkRGB: (0.69, 0.69, 0.69)
    )

    /// Polestar's own surfaces, as polestar.com renders them: white and black, a #666 secondary,
    /// a #E5E5E5 hairline and a #EFEFEF studio stage. Black carries selection, the charge fill and
    /// the primary action, so the screen stays monochrome. Gold is reserved for live state (see
    /// ``HisingenTheme/liveSignal``); it is never a decoration.
    static let polestar = Palette(
        theme: .polestar,
        name: L10n.text("Monochrome Precision"),
        subtitle: L10n.text("Monochrome panels, high-contrast type, Scandinavian minimalism"),
        category: .brand,
        accentHex: "#000000",
        swatches: ["#FFFFFF", "#EFEFEF", "#000000"],
        canvas: Color(light: NSColor(white: 1.0, alpha: 1), dark: NSColor(white: 0.0, alpha: 1)),
        ink: Color(light: NSColor(white: 0.0, alpha: 1), dark: NSColor(white: 1.0, alpha: 1)),
        inkMuted: Color(light: NSColor(white: 0.40, alpha: 1), dark: NSColor(white: 0.62, alpha: 1)),
        hairline: Color(light: NSColor(white: 0.0, alpha: 0.12), dark: NSColor(white: 1.0, alpha: 0.16)),
        accent: Color(light: NSColor(white: 0.0, alpha: 1), dark: NSColor(white: 1.0, alpha: 1)),
        accentOn: Color(light: .white, dark: .black),
        chartPositive: monoPos, chartInfo: monoInf, chartAttention: monoAtt, chartHealth: monoHlt,
        canvasLightRGB: (1.0, 1.0, 1.0), canvasDarkRGB: (0.0, 0.0, 0.0),
        inkLightRGB: (0.0, 0.0, 0.0), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.40, 0.40, 0.40), inkMutedDarkRGB: (0.62, 0.62, 0.62)
    )

    static let volvo = Palette(
        theme: .volvo,
        name: L10n.text("Heritage Blue"),
        subtitle: L10n.text("Blue accents, calm surfaces, clear typographic contrast"),
        category: .brand,
        accentHex: "#005B94",
        swatches: ["#005B94", "#003057", "#F4F6F9"],
        canvas: Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)),
        ink: Color(light: NSColor(red: 0.06, green: 0.09, blue: 0.15, alpha: 1), dark: NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1)),
        inkMuted: Color(light: NSColor(red: 0.35, green: 0.42, blue: 0.50, alpha: 1), dark: NSColor(red: 0.60, green: 0.68, blue: 0.76, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.86, green: 0.89, blue: 0.93, alpha: 1), dark: NSColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1)),
        accent: Color(light: NSColor(red: 0.0000, green: 0.3600, blue: 0.5800, alpha: 1), dark: NSColor(red: 0.2984, green: 0.7661, blue: 0.9730, alpha: 1)),
        accentOn: .white,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.96, 0.97, 0.98), canvasDarkRGB: (0.04, 0.05, 0.08),
        inkLightRGB: (0.06, 0.09, 0.15), inkDarkRGB: (0.97, 0.98, 1.0),
        inkMutedLightRGB: (0.35, 0.42, 0.50), inkMutedDarkRGB: (0.60, 0.68, 0.76)
    )

    static let nordicNight = Palette(
        theme: .nordicNight,
        name: L10n.text("Nordic Night"),
        subtitle: L10n.text("Pitch OLED black, electric cyan glow, modern dark style"),
        category: .dark,
        accentHex: "#00E5FF",
        swatches: ["#00E5FF", "#0A192F", "#000000"],
        canvas: Color(light: NSColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1)),
        ink: Color(light: NSColor(red: 0.02, green: 0.12, blue: 0.20, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.0, green: 0.60, blue: 0.80, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.25)),
        accent: Color(light: NSColor(red: 0.0000, green: 0.4337, blue: 0.5914, alpha: 1), dark: NSColor(red: 0.0000, green: 0.9000, blue: 1.0000, alpha: 1)),
        accentOn: .black,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.95, 0.98, 1.0), canvasDarkRGB: (0.00, 0.00, 0.00),
        inkLightRGB: (0.02, 0.12, 0.20), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.08, 0.42, 0.58), inkMutedDarkRGB: (0.30, 0.75, 0.95)
    )

    static let aurora = Palette(
        theme: .aurora,
        name: L10n.text("Aurora Borealis"),
        subtitle: L10n.text("Deep midnight slate with radiant northern lights emerald"),
        category: .nature,
        accentHex: "#00E676",
        swatches: ["#00E676", "#1DE9B6", "#0B132B"],
        canvas: Color(light: NSColor(red: 0.95, green: 0.99, blue: 0.97, alpha: 1), dark: NSColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1)),
        ink: Color(light: NSColor(red: 0.02, green: 0.18, blue: 0.12, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.06, green: 0.45, blue: 0.32, alpha: 1), dark: NSColor(red: 0.28, green: 0.82, blue: 0.60, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.0, green: 0.65, blue: 0.35, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 0.46, alpha: 0.25)),
        accent: Color(light: NSColor(red: 0.0000, green: 0.4645, blue: 0.2710, alpha: 1), dark: NSColor(red: 0.0000, green: 0.9200, blue: 0.5000, alpha: 1)),
        accentOn: .black,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.95, 0.99, 0.97), canvasDarkRGB: (0.04, 0.07, 0.12),
        inkLightRGB: (0.02, 0.18, 0.12), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.06, 0.45, 0.32), inkMutedDarkRGB: (0.28, 0.82, 0.60)
    )

    static let charcoalGold = Palette(
        theme: .charcoalGold,
        name: L10n.text("Charcoal Gold"),
        subtitle: L10n.text("Dark charcoal surfaces with a gold accent"),
        category: .sport,
        accentHex: "#D4AF37",
        swatches: ["#D4AF37", "#E5A93C", "#1E1E24"],
        canvas: Color(light: NSColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)),
        ink: Color(light: NSColor(red: 0.14, green: 0.11, blue: 0.04, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.48, green: 0.36, blue: 0.10, alpha: 1), dark: NSColor(red: 0.90, green: 0.82, blue: 0.55, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.72, green: 0.52, blue: 0.05, alpha: 0.35), dark: NSColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 0.30)),
        accent: Color(light: NSColor(red: 0.5269, green: 0.3805, blue: 0.0366, alpha: 1), dark: NSColor(red: 0.8800, green: 0.7200, blue: 0.2200, alpha: 1)),
        accentOn: .black,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.99, 0.98, 0.95), canvasDarkRGB: (0.08, 0.08, 0.09),
        inkLightRGB: (0.14, 0.11, 0.04), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.48, 0.36, 0.10), inkMutedDarkRGB: (0.90, 0.82, 0.55)
    )

    static let circuitBlue = Palette(
        theme: .circuitBlue,
        name: L10n.text("Circuit Blue"),
        subtitle: L10n.text("Championship blue, crisp track geometry"),
        category: .sport,
        accentHex: "#0090D0",
        swatches: ["#0090D0", "#00B4D8", "#0A0F1A"],
        canvas: Color(light: NSColor(red: 0.94, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1)),
        ink: Color(light: NSColor(red: 0.03, green: 0.12, blue: 0.22, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.45, green: 0.80, blue: 0.98, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.0, green: 0.48, blue: 0.78, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.56, blue: 0.82, alpha: 0.30)),
        accent: Color(light: NSColor(red: 0.0000, green: 0.4184, blue: 0.6800, alpha: 1), dark: NSColor(red: 0.3287, green: 0.7651, blue: 0.9664, alpha: 1)),
        accentOn: .white,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.94, 0.98, 1.0), canvasDarkRGB: (0.04, 0.06, 0.10),
        inkLightRGB: (0.03, 0.12, 0.22), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.08, 0.42, 0.58), inkMutedDarkRGB: (0.45, 0.80, 0.98)
    )

    static let forest = Palette(
        theme: .forest,
        name: L10n.text("Gothenburg Forest"),
        subtitle: L10n.text("Swedish pine and eucalyptus earth tones, organic soft feel"),
        category: .nature,
        accentHex: "#4CAF50",
        swatches: ["#2E7D32", "#4CAF50", "#0D1F0F"],
        canvas: Color(light: NSColor(red: 0.95, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.04, green: 0.09, blue: 0.05, alpha: 1)),
        ink: Color(light: NSColor(red: 0.06, green: 0.16, blue: 0.08, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.18, green: 0.42, blue: 0.22, alpha: 1), dark: NSColor(red: 0.52, green: 0.88, blue: 0.65, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.14, green: 0.48, blue: 0.18, alpha: 0.35), dark: NSColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 0.25)),
        accent: Color(light: NSColor(red: 0.1355, green: 0.4646, blue: 0.1742, alpha: 1), dark: NSColor(red: 0.3849, green: 0.8067, blue: 0.4288, alpha: 1)),
        accentOn: .white,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.95, 0.98, 0.95), canvasDarkRGB: (0.04, 0.09, 0.05),
        inkLightRGB: (0.06, 0.16, 0.08), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.18, 0.42, 0.22), inkMutedDarkRGB: (0.52, 0.88, 0.65)
    )

    static let sandDune = Palette(
        theme: .sandDune,
        name: L10n.text("Sand Dune"),
        subtitle: L10n.text("Warm desert sand and titanium champagne minimalism"),
        category: .brand,
        accentHex: "#C5A059",
        swatches: ["#C5A059", "#E0C097", "#1E1B18"],
        canvas: Color(light: NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1), dark: NSColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1)),
        ink: Color(light: NSColor(red: 0.14, green: 0.12, blue: 0.09, alpha: 1), dark: NSColor.white),
        inkMuted: Color(light: NSColor(red: 0.42, green: 0.36, blue: 0.30, alpha: 1), dark: NSColor(red: 0.82, green: 0.76, blue: 0.70, alpha: 1)),
        hairline: Color(light: NSColor(red: 0.65, green: 0.50, blue: 0.25, alpha: 0.35), dark: NSColor(red: 0.77, green: 0.63, blue: 0.35, alpha: 0.30)),
        accent: Color(light: NSColor(red: 0.4936, green: 0.3797, blue: 0.1899, alpha: 1), dark: NSColor(red: 0.8355, green: 0.7076, blue: 0.4700, alpha: 1)),
        accentOn: .black,
        chartPositive: chartPos, chartInfo: chartInf, chartAttention: chartAtt, chartHealth: chartHlt,
        canvasLightRGB: (0.98, 0.97, 0.94), canvasDarkRGB: (0.09, 0.08, 0.07),
        inkLightRGB: (0.14, 0.12, 0.09), inkDarkRGB: (1.0, 1.0, 1.0),
        inkMutedLightRGB: (0.42, 0.36, 0.30), inkMutedDarkRGB: (0.82, 0.76, 0.70)
    )

    // Chart series are *data*, so they are checked as graphics against the surface they are
    // actually plotted on — the card, not the canvas — and `chartInfo`/`chartAttention` are also
    // checked against each other, because they share axes in the voltage/current and particulate
    // charts. Those two constraints pull against each other in the dark appearance: both must clear
    // 3:1 on the lifted card, which forces both above ~0.23 luminance, and then one must be three
    // times brighter than the other. The palette keeps the blue mid-bright and pushes the amber
    // toward white, which is the only pairing that satisfies both. The light variants are
    // unchanged. Re-run `Scripts/verify-app-contrast.py` before touching any of these.
    // Polestar charts: ink for the primary series, greys for supporting ones, and a deep gold for
    // the series that marks attention. Ink and that gold clear 3:1 against each other (5.6:1 on
    // black ink, 3.7:1 on white ink) and against the card in both appearances.
    private static let monoPos = Color(light: NSColor(red: 0.4196, green: 0.4196, blue: 0.4196, alpha: 1), dark: NSColor(red: 0.6392, green: 0.6392, blue: 0.6392, alpha: 1))
    private static let monoInf = Color(light: NSColor(red: 0.0000, green: 0.0000, blue: 0.0000, alpha: 1), dark: NSColor(red: 1.0000, green: 1.0000, blue: 1.0000, alpha: 1))
    private static let monoAtt = Color(light: NSColor(red: 0.7098, green: 0.4667, blue: 0.0588, alpha: 1), dark: NSColor(red: 0.7098, green: 0.4667, blue: 0.0588, alpha: 1))
    private static let monoHlt = Color(light: NSColor(red: 0.5412, green: 0.5412, blue: 0.5412, alpha: 1), dark: NSColor(red: 0.4784, green: 0.4784, blue: 0.4784, alpha: 1))
    private static let chartPos = Color(light: NSColor(red: 0.0824, green: 0.5569, blue: 0.2824, alpha: 1), dark: NSColor(red: 0.2157, green: 0.7216, blue: 0.3843, alpha: 1))
    private static let chartInf = Color(light: NSColor(red: 0.0235, green: 0.1961, blue: 0.4392, alpha: 1), dark: NSColor(red: 0.2800, green: 0.5400, blue: 0.9200, alpha: 1))
    private static let chartAtt = Color(light: NSColor(red: 0.8392, green: 0.4118, blue: 0.0431, alpha: 1), dark: NSColor(red: 1.0000, green: 0.9800, blue: 0.5500, alpha: 1))
    private static let chartHlt = Color(light: NSColor(red: 0.6863, green: 0.1725, blue: 0.4275, alpha: 1), dark: NSColor(red: 0.9647, green: 0.3882, blue: 0.7255, alpha: 1))
}

// MARK: - Theme Integration

extension HisingenTheme {
    /// Returns the complete palette for a given theme.
    nonisolated static func palette(for theme: AppTheme) -> Palette {
        switch theme {
        case .hisingen: return .hisingen
        case .polestar: return .polestar
        case .volvo: return .volvo
        case .nordicNight: return .nordicNight
        case .aurora: return .aurora
        case .charcoalGold: return .charcoalGold
        case .circuitBlue: return .circuitBlue
        case .forest: return .forest
        case .sandDune: return .sandDune
        case .custom(let id):
            // A deleted theme can still be named by an old vehicle mapping; it reads as the
            // default palette until the reader picks another.
            guard let definition = CustomThemeStore.definition(id: id) else { return .hisingen }
            return CustomThemeStore.palette(for: definition)
        }
    }
}

@MainActor
extension HisingenTheme {
    /// The active theme's palette.
    static var palette: Palette {
        palette(for: theme)
    }
}
