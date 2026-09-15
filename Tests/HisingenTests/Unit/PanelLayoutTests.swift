import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PanelLayoutTests {

    private func makeStore() throws -> PreferencesStore {
        let suiteName = "hisingen.tests.panel-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return PreferencesStore(defaults: defaults)
    }

    // MARK: - Persistence round trips

    @Test
    func testPanelSizeAndDensityRoundTrip() throws {
        let store = try makeStore()
        #expect(store.panelSize == .standard)
        #expect(store.contentDensity == .standard)

        for size in PanelSize.allCases {
            store.panelSize = size
            #expect(store.panelSize == size)
        }
        for density in ContentDensity.allCases {
            store.contentDensity = density
            #expect(store.contentDensity == density)
        }
    }

    @Test
    func testCustomSizePersistenceRoundTrip() throws {
        let store = try makeStore()
        #expect(!(store.customPanelSizeEnabled))

        store.customPanelSizeEnabled = true
        store.customPanelWidth = 560
        store.customPanelHeight = 720
        #expect(store.customPanelSizeEnabled)
        #expect(store.customPanelWidth == 560)
        #expect(store.customPanelHeight == 720)
    }

    @Test
    func testWideCardLayoutDefaultsToFullWidthAndRoundTrips() throws {
        let suiteName = "hisingen.tests.panel-layout.cardflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        #expect(store.wideCardLayout == .fullWidth)
        for layout in WideCardLayout.allCases {
            store.wideCardLayout = layout
            #expect(store.wideCardLayout == layout)
        }

        // A corrupt persisted value falls back to full width.
        defaults.set("bogus", forKey: "wide_card_layout")
        #expect(store.wideCardLayout == .fullWidth)
    }

    @Test
    func testUnknownRawValuesFallBackToStandard() {
        let layout = PanelLayout.resolve(
            panelSizeRaw: "bogus", densityRaw: "bogus",
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        #expect(layout.width == PanelSize.standard.width)
        #expect(layout.unclampedHeight == PanelSize.standard.idealHeight)
        // A5: the density preset no longer raster-scales the content tree. Type comes from the
        // ramp and spacing from the preset, so the tree lays out at the panel's real size.
        #expect(layout.contentScale == 1)
    }

    // MARK: - Resolution invariants

    @Test
    func testPresetResolutionMatchesEnumDimensions() {
        for size in PanelSize.allCases {
            let layout = PanelLayout.resolve(
                panelSizeRaw: size.rawValue, densityRaw: ContentDensity.standard.rawValue,
                customEnabled: false, customWidth: 0, customHeight: 0
            )
            #expect(layout.width == size.width, "\(size.rawValue) width")
            #expect(layout.unclampedHeight == size.idealHeight, "\(size.rawValue) height")
        }
    }

    @Test
    func testLogicalWidthTimesScaleEqualsPhysicalWidth() {
        for size in PanelSize.allCases {
            for density in ContentDensity.allCases {
                let layout = PanelLayout.resolve(
                    panelSizeRaw: size.rawValue, densityRaw: density.rawValue,
                    customEnabled: false, customWidth: 0, customHeight: 0
                )
                // The logical frame and the physical frame are the same frame now.
                #expect(abs(layout.logicalWidth * layout.contentScale - layout.width) <= 0.01, "\(size.rawValue) @ \(density.rawValue)")
                #expect(layout.logicalWidth == layout.width)
            }
        }
    }

    @Test
    func testCustomOverridesTakePrecedenceAndClamp() {
        // In-range values pass through.
        let inRange = PanelLayout.resolve(
            panelSizeRaw: PanelSize.compact.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: true, customWidth: 600, customHeight: 700
        )
        #expect(inRange.width == 600)
        #expect(inRange.unclampedHeight == 700)

        // Out-of-range values clamp to the documented bounds.
        let clamped = PanelLayout.resolve(
            panelSizeRaw: PanelSize.grand.rawValue, densityRaw: ContentDensity.relaxed.rawValue,
            customEnabled: true, customWidth: 100, customHeight: 5000
        )
        #expect(clamped.width == PanelLayout.minimumWidth)
        #expect(clamped.unclampedHeight == PanelLayout.maximumHeight)

        // Unseeded (zero) values fall back to the selected preset's dimensions.
        let unseeded = PanelLayout.resolve(
            panelSizeRaw: PanelSize.wide.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: true, customWidth: 0, customHeight: 0
        )
        #expect(unseeded.width == PanelSize.wide.width)
        #expect(unseeded.unclampedHeight == PanelSize.wide.idealHeight)
    }

    @Test
    func testResolvedPointsAreWholeNumbers() {
        for size in PanelSize.allCases {
            for density in ContentDensity.allCases {
                let layout = PanelLayout.resolve(
                    panelSizeRaw: size.rawValue, densityRaw: density.rawValue,
                    customEnabled: false, customWidth: 0, customHeight: 0
                )
                #expect(layout.width.rounded() == layout.width, "\(size.rawValue) width")
                #expect(layout.unclampedHeight.rounded() == layout.unclampedHeight, "\(size.rawValue) height")
            }
        }
    }

    // MARK: - Screen-fit clamp (pure, injected visible-frame height)

    @Test
    func testScreenFitClampLeavesRoomOnTallScreens() {
        let grand = PanelLayout.resolve(
            panelSizeRaw: PanelSize.grand.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        #expect(grand.clampedToVisibleFrame(1200) == grand.unclampedHeight)
    }

    @Test
    func testScreenFitClampShrinksForShortScreens() {
        let grand = PanelLayout.resolve(
            panelSizeRaw: PanelSize.grand.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        // A 600 pt visible frame must never be asked for more than fits.
        let fitted = grand.clampedToVisibleFrame(600)
        #expect(fitted <= 576) // 600 - 24 margin
        #expect(fitted >= PanelLayout.minimumHeight)
    }

    @Test
    func testScreenFitClampNeverGoesBelowMinimum() {
        let compact = PanelLayout.resolve(
            panelSizeRaw: PanelSize.compact.rawValue, densityRaw: ContentDensity.compact.rawValue,
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        #expect(compact.clampedToVisibleFrame(100) == PanelLayout.minimumHeight)
    }

    // MARK: - Dimensions label

    @Test
    func testDimensionsLabelFormat() {
        #expect(PanelSize.standard.dimensionsLabel == "430 × 580")
        #expect(PanelSize.grand.dimensionsLabel == "600 × 760")
    }
}
