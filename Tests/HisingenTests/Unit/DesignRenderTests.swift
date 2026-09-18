import SwiftUI
import AppKit
import Testing
@testable import Hisingen

/// Renders a reference composition so a theme change has to reach real pixels, not just a resolved
/// token. A palette can resolve correctly while the drawn composition still shows the old one, and
/// only a render catches that.
///
/// The composition is built from an explicit ``Palette`` rather than a global theme override, so
/// the render assertions are hermetic and cannot be defeated by a stale shared-defaults value. The
/// override path itself is covered separately in
/// ``themeOverrideTakesAtTheTokenTheCompositionReads()``.
@Suite(.serialized)
@MainActor
struct DesignRenderTests {

    /// The tokens a real panel stacks, in the order it stacks them: canvas, card, accent.
    private struct ReferenceComposition: View {
        let palette: Palette

        var body: some View {
            ZStack {
                palette.canvas
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius)
                        .fill(palette.cardFill)
                    RoundedRectangle(cornerRadius: HisingenTheme.gaugeRadius)
                        .fill(palette.accent)
                }
                .padding(12)
            }
            .frame(width: 120, height: 80)
        }
    }

    private func render(_ palette: Palette) throws -> CGImage {
        let renderer = ImageRenderer(content: ReferenceComposition(palette: palette))
        renderer.scale = 1
        return try #require(renderer.cgImage, "the reference composition produced no image")
    }

    private func centerPixel(_ palette: Palette) throws -> Pixel {
        try #require(try render(palette).centerPixel(), "could not sample the rendered image")
    }

    @Test
    func rendersTheReferenceCompositionForEveryTheme() throws {
        for theme in AppTheme.allCases {
            let image = try render(HisingenTheme.palette(for: theme))
            #expect(image.width == 120 && image.height == 80,
                    "\(theme.rawValue) rendered at \(image.width)×\(image.height)")
        }
    }

    @Test
    func distinctThemesReachTheRenderedPixels() throws {
        // The failure this exists to catch: the override resolves to the right token while the
        // composition is still drawn from the old palette.
        let gold = try centerPixel(HisingenTheme.palette(for: .polestar))
        let forest = try centerPixel(HisingenTheme.palette(for: .forest))
        #expect(gold != forest, "two different palettes rendered identical pixels")
    }

    @Test
    func themeOverrideTakesAtTheTokenTheCompositionReads() throws {
        usingTheme(.volvo) {
            #expect(HisingenTheme.palette.theme == .volvo, "theme override did not take")
            #expect(HisingenTheme.accent == HisingenTheme.palette(for: .volvo).accent,
                    "theme override did not take: accent still resolves to another palette")
        }
    }

    @Test
    func rendersPolestarDataPortalSettings() throws {
        let suite = "io.kheirallah.hisingen.render.dataportal.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.polestarConnectionMode = .dataPortal
        preferences.polestarDataPortalClientID = "client-id-sample"
        preferences.polestarDataPortalAccountID = "0a7f033f-..."

        let view = AccountCredentialsForm(style: .welcoming, onSettingsChanged: { _ in })
            .environment(\.preferencesStore, preferences)
            .frame(width: 440)
            .padding()
            .background(HisingenTheme.palette(for: .polestar).canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        let cgImage = try #require(renderer.cgImage, "ImageRenderer produced no image; the test must not vacuously pass")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let dest = URL(fileURLWithPath: "docs/design/renders/settings-polestar-dataportal.png")
        try pngData.write(to: dest)
        let written = try #require(NSImage(contentsOf: dest))
        #expect(written.size.width > 0)
    }

    /// Applies `theme` through the global the views read, then restores what was there. The
    /// restore runs on the way out even if the body fails, so a failing assertion cannot leave the
    /// owner's chosen theme replaced.
    private func usingTheme(_ theme: AppTheme, _ body: () throws -> Void) rethrows {
        let previous = PreferencesStore.shared.appTheme
        PreferencesStore.shared.appTheme = theme
        defer { PreferencesStore.shared.appTheme = previous }
        try body()
    }
}

private struct Pixel: Equatable {
    let r: Double
    let g: Double
    let b: Double
}

private extension CGImage {
    /// The image's centre pixel as sRGB components in 0...1. Drawn into a 1×1 context placed so the
    /// image's centre lands on that single pixel.
    func centerPixel() -> Pixel? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let width = Double(self.width)
        let height = Double(self.height)
        context.draw(self, in: CGRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height))
        return Pixel(r: Double(bytes[0]) / 255, g: Double(bytes[1]) / 255, b: Double(bytes[2]) / 255)
    }
}
