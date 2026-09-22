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

        let view = AccountCredentialsForm(style: .welcoming, onSettingsChanged: { _ in },
                                            model: AccountConnectionModel(preferences: preferences))
            .environment(\.preferencesStore, preferences)
            .frame(width: 440)
            .padding()
            .background(HisingenTheme.palette(for: .polestar).canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        let cgImage = try #require(renderer.cgImage, "ImageRenderer produced no image; the test must not vacuously pass")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        // The renders refresh the local design docs, and docs/ is gitignored — a fresh checkout
        // has no renders directory. Anchor to the source tree rather than the runner's cwd and
        // create the directory instead of assuming it.
        let dest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Unit
            .deletingLastPathComponent()   // .../HisingenTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("docs/design/renders/settings-polestar-dataportal.png")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try pngData.write(to: dest)
        let written = try #require(NSImage(contentsOf: dest))
        #expect(written.size.width > 0)
    }

    /// The 2026 dashboard grammar as the panel actually composes it: the glass tab selection,
    /// the idle charging row (one line, not a titled section), two instrument rows, and the
    /// boxless planner group. The opaque panel is pinned directly: the accessibility
    /// environment values that steer PopoverSurface are read-only in the SDK, and a snapshot
    /// must not depend on the host process appearance anyway.
    private struct RedesignSnapshot: View {
        var body: some View {
            VStack(spacing: HisingenTheme.sectionSpacing) {
                HStack(spacing: 4) {
                    tab("Vehicle", symbol: "car.fill", selected: true)
                    tab("History", symbol: "clock.arrow.circlepath", selected: false)
                    tab("Settings", symbol: "gearshape", selected: false)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                HStack(spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .hisType(.subhead, weight: .semibold)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .accessibilityHidden(true)
                    Text("Not connected")
                        .hisType(.subhead, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                }

                VStack(spacing: 6) {
                    DashboardRow(symbol: "lock.fill", value: "Locked",
                                 label: "Doors & Openings", tint: HisingenTheme.semanticGood)
                    DashboardRow(symbol: "fuelpump.fill", value: "42% · 214 km",
                                 label: "Fuel & Engine", tint: HisingenTheme.ink)
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(symbol: "clock.badge.checkmark", title: "Charging Planner",
                                   color: HisingenTheme.accent)
                        Text("Tomorrow 01:45 to 13:45")
                            .hisType(.title)
                            .foregroundStyle(HisingenTheme.ink)
                        Text("Charge 43.7 kWh over 12 h to reach 90%: average 0.01 kr/kWh, now 0.02 kr/kWh")
                            .hisType(.body)
                            .foregroundStyle(.secondary)
                            .hisCaptionLeading()
                            .fixedSize(horizontal: false, vertical: true)
                        StateSummaryChip(message: "Cheapest window before Friday", severity: .good)
                    }
                }
            }
            .padding(HisingenTheme.sectionSpacing)
            .frame(width: 380, alignment: .top)
            .background { Rectangle().fill(HisingenTheme.panelFill) }
        }

        private func tab(_ title: String, symbol: String, selected: Bool) -> some View {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .hisType(.caption, weight: selected ? .semibold : .regular)
                Text(title)
                    .hisType(.caption, weight: selected ? .semibold : .medium)
            }
            .foregroundStyle(selected ? HisingenTheme.ink : HisingenTheme.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                if selected {
                    Color.clear
                        .hisControlGlass(in: Capsule(), fallback: HisingenTheme.fill(.selected))
                }
            }
        }

        private func row(_ title: String, detail: String? = nil) -> some View {
            HStack(spacing: 6) {
                Text(title)
                    .hisType(.subhead)
                    .foregroundStyle(HisingenTheme.ink)
                Spacer()
                if let detail {
                    Text(detail)
                        .hisType(.caption, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
        }
    }

    /// Renders the redesign snapshot in `appearanceName` and writes the PNG the visual review reads.
    private func renderRedesignSnapshot(appearanceName: NSAppearance.Name, name: String) throws -> Data {
        let scheme: ColorScheme = name == "dark" ? .dark : .light
        let view = RedesignSnapshot()
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        // Color tokens are NSColor dynamic providers, resolved against the current appearance at
        // draw time, so the appearance is pinned around the render as well as in the environment.
        let appearance = try #require(NSAppearance(named: appearanceName), "no such appearance")
        var rendered: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = renderer.cgImage
        }
        let cgImage = try #require(
            rendered,
            "ImageRenderer produced no image; the snapshot must not vacuously pass"
        )
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let dest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Unit
            .deletingLastPathComponent()   // .../HisingenTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("docs/design/renders/redesign-panel-\(name).png")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try pngData.write(to: dest)
        // The two appearances must actually differ; identical bytes would mean the appearance
        // pin never reached the renderer and one of the files lies.
        return pngData
    }

    @Test
    func rendersTheRedesignSnapshotInBothAppearancesDifferently() throws {
        let dark = try renderRedesignSnapshot(appearanceName: .darkAqua, name: "dark")
        let light = try renderRedesignSnapshot(appearanceName: .aqua, name: "light")
        #expect(dark != light, "dark and light snapshots rendered identical bytes")
    }

    @Test
    func expandedChargingCurveReservesEnoughVerticalSpaceForItsPlotAndCaptions() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = [
            ChargingSample(timestamp: start, batteryPercentage: 25, powerWatts: 11_000),
            ChargingSample(timestamp: start.addingTimeInterval(300), batteryPercentage: 44, powerWatts: 10_200),
            ChargingSample(timestamp: start.addingTimeInterval(600), batteryPercentage: 66, powerWatts: 8_700),
        ]
        let view = ChargingCurveView(
            samples: samples,
            targetPercentage: nil,
            readyDate: nil,
            isLive: false,
            energySource: .legacyEstimate,
            confidence: .low,
            sampleCoverage: 0.62
        )
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let appearance = try #require(NSAppearance(named: .darkAqua), "dark appearance unavailable")
        var rendered: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = renderer.cgImage
        }
        let image = try #require(rendered, "expanded charging curve produced no image")

        #expect(image.width == 560)
        #expect(image.height >= 190,
                "the expanded curve collapsed to \(image.height) pt and can clip its plot or captions")

        let bitmap = NSBitmapImageRep(cgImage: image)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/design/renders/charging-curve-expanded.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: destination)
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
