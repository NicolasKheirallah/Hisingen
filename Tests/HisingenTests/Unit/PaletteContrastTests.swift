import Foundation
import Testing
@testable import Hisingen

struct PaletteContrastTests {

    private struct RGB: Sendable {
        let r: Double
        let g: Double
        let b: Double

        func linearise(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }

        var luminance: Double {
            0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
        }

        func contrast(with other: RGB) -> Double {
            let l1 = luminance
            let l2 = other.luminance
            let lighter = max(l1, l2)
            let darker = min(l1, l2)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }

    /// The card fill is derived from the canvas in `Palette.cardFill`, so the test derives it the
    /// same way rather than asserting one fixed neutral: the fill is per-theme now, and a fixed
    /// fixture disagreed with the palette the moment that happened.
    private func cardFill(_ palette: Palette, dark: Bool) -> RGB {
        let canvas = dark ? palette.canvasDarkRGB : palette.canvasLightRGB
        let lift = dark ? 0.16 : 0.55
        func raised(_ channel: Double) -> Double { channel + (1 - channel) * lift }
        return RGB(r: raised(canvas.r), g: raised(canvas.g), b: raised(canvas.b))
    }

    private let cardBoundaryLight = RGB(r: 0.5216, g: 0.5216, b: 0.5216)
    private let cardBoundaryDark = RGB(r: 0.4118, g: 0.4118, b: 0.4118)

    @Test
    func testAllThemesDefinedAndCountMatches() {
        #expect(AppTheme.allCases.count == 9)
        for theme in AppTheme.allCases {
            let palette = HisingenTheme.palette(for: theme)
            #expect(palette.theme == theme)
            #expect(!palette.name.isEmpty)
            #expect(!palette.subtitle.isEmpty)
            #expect(!palette.accentHex.isEmpty)
            #expect(palette.swatches.count == 3)
        }
    }

    @Test
    func testTextContrastFloorsAgainstCanvasAndCard() {
        for theme in AppTheme.allCases {
            let palette = HisingenTheme.palette(for: theme)

            let canvasLight = RGB(r: palette.canvasLightRGB.r, g: palette.canvasLightRGB.g, b: palette.canvasLightRGB.b)
            let canvasDark = RGB(r: palette.canvasDarkRGB.r, g: palette.canvasDarkRGB.g, b: palette.canvasDarkRGB.b)

            let inkLight = RGB(r: palette.inkLightRGB.r, g: palette.inkLightRGB.g, b: palette.inkLightRGB.b)
            let inkDark = RGB(r: palette.inkDarkRGB.r, g: palette.inkDarkRGB.g, b: palette.inkDarkRGB.b)

            let inkMutedLight = RGB(r: palette.inkMutedLightRGB.r, g: palette.inkMutedLightRGB.g, b: palette.inkMutedLightRGB.b)
            let inkMutedDark = RGB(r: palette.inkMutedDarkRGB.r, g: palette.inkMutedDarkRGB.g, b: palette.inkMutedDarkRGB.b)

            // WCAG AA regular text floor is 4.5:1
            #expect(inkLight.contrast(with: canvasLight) >= 4.5, "Theme \(theme.rawValue) ink light on canvas must be >= 4.5")
            #expect(inkDark.contrast(with: canvasDark) >= 4.5, "Theme \(theme.rawValue) ink dark on canvas must be >= 4.5")

            #expect(inkMutedLight.contrast(with: canvasLight) >= 4.5, "Theme \(theme.rawValue) inkMuted light on canvas must be >= 4.5")
            #expect(inkMutedDark.contrast(with: canvasDark) >= 4.5, "Theme \(theme.rawValue) inkMuted dark on canvas must be >= 4.5")

            // On card fill
            let cardLight = cardFill(palette, dark: false)
            let cardDark = cardFill(palette, dark: true)
            #expect(inkLight.contrast(with: cardLight) >= 4.5, "Theme \(theme.rawValue) ink light on card must be >= 4.5")
            #expect(inkDark.contrast(with: cardDark) >= 4.5, "Theme \(theme.rawValue) ink dark on card must be >= 4.5")

            #expect(inkMutedLight.contrast(with: cardLight) >= 4.5, "Theme \(theme.rawValue) inkMuted light on card must be >= 4.5")
            #expect(inkMutedDark.contrast(with: cardDark) >= 4.5, "Theme \(theme.rawValue) inkMuted dark on card must be >= 4.5")
        }
    }

    @Test
    func testCardBoundaryContrastAgainstCanvas() {
        for theme in AppTheme.allCases {
            let palette = HisingenTheme.palette(for: theme)
            let canvasLight = RGB(r: palette.canvasLightRGB.r, g: palette.canvasLightRGB.g, b: palette.canvasLightRGB.b)
            let canvasDark = RGB(r: palette.canvasDarkRGB.r, g: palette.canvasDarkRGB.g, b: palette.canvasDarkRGB.b)

            // WCAG 1.4.11 UI boundary floor is 3.0:1
            #expect(cardBoundaryLight.contrast(with: canvasLight) >= 3.0, "Theme \(theme.rawValue) card boundary light on canvas must be >= 3.0")
            #expect(cardBoundaryDark.contrast(with: canvasDark) >= 3.0, "Theme \(theme.rawValue) card boundary dark on canvas must be >= 3.0")
        }
    }

    @Test
    func testPolestarAmberContrastOnPolestarCanvas() {
        let amberLight = RGB(r: 0.6275, g: 0.3020, b: 0.0941)
        let amberDark = RGB(r: 0.8980, g: 0.4314, b: 0.1373)
        let polestar = HisingenTheme.palette(for: .polestar)
        let canvasLight = RGB(r: polestar.canvasLightRGB.r, g: polestar.canvasLightRGB.g, b: polestar.canvasLightRGB.b)
        let canvasDark = RGB(r: polestar.canvasDarkRGB.r, g: polestar.canvasDarkRGB.g, b: polestar.canvasDarkRGB.b)

        #expect(amberLight.contrast(with: canvasLight) >= 3.0, "Polestar amber light must be >= 3.0 on Polestar canvas")
        #expect(amberDark.contrast(with: canvasDark) >= 3.0, "Polestar amber dark must be >= 3.0 on Polestar canvas")
    }

    @Test
    func testChartSeriesContrastAgainstCardAndEachOther() {
        // The palette's chart tokens as sRGB. `Scripts/verify-app-contrast.py` parses these straight
        // out of `Palette.swift` and is the authoritative gate; this is the in-process backstop, so
        // the values are repeated deliberately but must move with the palette. They were stale here:
        // the dark pair still held the pre-tuning `chartInf`, which measured 2.49:1 on the card while
        // the palette claimed the pair had been verified.
        let chartPositiveLight = RGB(r: 0.0824, g: 0.5569, b: 0.2824)
        let chartPositiveDark = RGB(r: 0.2157, g: 0.7216, b: 0.3843)
        let chartInfoLight = RGB(r: 0.0235, g: 0.1961, b: 0.4392)
        let chartInfoDark = RGB(r: 0.2800, g: 0.5400, b: 0.9200)
        let chartAttentionLight = RGB(r: 0.8392, g: 0.4118, b: 0.0431)
        let chartAttentionDark = RGB(r: 1.0000, g: 0.9800, b: 0.5500)
        let chartHealthLight = RGB(r: 0.6863, g: 0.1725, b: 0.4275)
        let chartHealthDark = RGB(r: 0.9647, g: 0.3882, b: 0.7255)

        // The card is per-theme now, so every series is measured on every theme's card, not on one
        // fixed neutral.
        for theme in AppTheme.allCases {
            let palette = HisingenTheme.palette(for: theme)
            let cardLight = cardFill(palette, dark: false)
            let cardDark = cardFill(palette, dark: true)

            #expect(chartPositiveLight.contrast(with: cardLight) >= 3.0, "Theme \(theme.rawValue) chartPositive light on card")
            #expect(chartPositiveDark.contrast(with: cardDark) >= 3.0, "Theme \(theme.rawValue) chartPositive dark on card")
            #expect(chartInfoLight.contrast(with: cardLight) >= 3.0, "Theme \(theme.rawValue) chartInfo light on card")
            #expect(chartInfoDark.contrast(with: cardDark) >= 3.0, "Theme \(theme.rawValue) chartInfo dark on card")
            #expect(chartAttentionLight.contrast(with: cardLight) >= 3.0, "Theme \(theme.rawValue) chartAttention light on card")
            #expect(chartAttentionDark.contrast(with: cardDark) >= 3.0, "Theme \(theme.rawValue) chartAttention dark on card")
            #expect(chartHealthLight.contrast(with: cardLight) >= 3.0, "Theme \(theme.rawValue) chartHealth light on card")
            #expect(chartHealthDark.contrast(with: cardDark) >= 3.0, "Theme \(theme.rawValue) chartHealth dark on card")
        }

        // chartInfo and chartAttention clear 3:1 against each other
        #expect(chartInfoLight.contrast(with: chartAttentionLight) >= 3.0)
        #expect(chartInfoDark.contrast(with: chartAttentionDark) >= 3.0)
    }
}
