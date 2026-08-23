import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PanelLayoutTests {

    private func makeStore() throws -> PreferencesStore {
        let suiteName = "hisingen.tests.panel-layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return PreferencesStore(defaults: defaults)
    }

    // MARK: - Persistence round trips

    @Test
    func testPanelSizeAndDensityRoundTrip() throws {
        let store = try makeStore()
        XCTAssertEqual(store.panelSize, .standard)
        XCTAssertEqual(store.contentDensity, .standard)

        for size in PanelSize.allCases {
            store.panelSize = size
            XCTAssertEqual(store.panelSize, size)
        }
        for density in ContentDensity.allCases {
            store.contentDensity = density
            XCTAssertEqual(store.contentDensity, density)
        }
    }

    @Test
    func testCustomSizePersistenceRoundTrip() throws {
        let store = try makeStore()
        XCTAssertFalse(store.customPanelSizeEnabled)

        store.customPanelSizeEnabled = true
        store.customPanelWidth = 560
        store.customPanelHeight = 720
        XCTAssertTrue(store.customPanelSizeEnabled)
        XCTAssertEqual(store.customPanelWidth, 560)
        XCTAssertEqual(store.customPanelHeight, 720)
    }

    @Test
    func testWideCardLayoutDefaultsToFullWidthAndRoundTrips() throws {
        let suiteName = "hisingen.tests.panel-layout.cardflow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.wideCardLayout, .fullWidth)
        for layout in WideCardLayout.allCases {
            store.wideCardLayout = layout
            XCTAssertEqual(store.wideCardLayout, layout)
        }

        // A corrupt persisted value falls back to full width.
        defaults.set("bogus", forKey: "wide_card_layout")
        XCTAssertEqual(store.wideCardLayout, .fullWidth)
    }

    @Test
    func testUnknownRawValuesFallBackToStandard() {
        let layout = PanelLayout.resolve(
            panelSizeRaw: "bogus", densityRaw: "bogus",
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        XCTAssertEqual(layout.width, PanelSize.standard.width)
        XCTAssertEqual(layout.unclampedHeight, PanelSize.standard.idealHeight)
        XCTAssertEqual(layout.contentScale, ContentDensity.standard.scale)
    }

    // MARK: - Resolution invariants

    @Test
    func testPresetResolutionMatchesEnumDimensions() {
        for size in PanelSize.allCases {
            let layout = PanelLayout.resolve(
                panelSizeRaw: size.rawValue, densityRaw: ContentDensity.standard.rawValue,
                customEnabled: false, customWidth: 0, customHeight: 0
            )
            XCTAssertEqual(layout.width, size.width, "\(size.rawValue) width")
            XCTAssertEqual(layout.unclampedHeight, size.idealHeight, "\(size.rawValue) height")
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
                XCTAssertEqual(layout.logicalWidth * layout.contentScale, layout.width,
                               accuracy: 0.01,
                               "\(size.rawValue) @ \(density.rawValue)")
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
        XCTAssertEqual(inRange.width, 600)
        XCTAssertEqual(inRange.unclampedHeight, 700)

        // Out-of-range values clamp to the documented bounds.
        let clamped = PanelLayout.resolve(
            panelSizeRaw: PanelSize.grand.rawValue, densityRaw: ContentDensity.relaxed.rawValue,
            customEnabled: true, customWidth: 100, customHeight: 5000
        )
        XCTAssertEqual(clamped.width, PanelLayout.minimumWidth)
        XCTAssertEqual(clamped.unclampedHeight, PanelLayout.maximumHeight)

        // Unseeded (zero) values fall back to the selected preset's dimensions.
        let unseeded = PanelLayout.resolve(
            panelSizeRaw: PanelSize.wide.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: true, customWidth: 0, customHeight: 0
        )
        XCTAssertEqual(unseeded.width, PanelSize.wide.width)
        XCTAssertEqual(unseeded.unclampedHeight, PanelSize.wide.idealHeight)
    }

    @Test
    func testResolvedPointsAreWholeNumbers() {
        for size in PanelSize.allCases {
            for density in ContentDensity.allCases {
                let layout = PanelLayout.resolve(
                    panelSizeRaw: size.rawValue, densityRaw: density.rawValue,
                    customEnabled: false, customWidth: 0, customHeight: 0
                )
                XCTAssertEqual(layout.width.rounded(), layout.width, "\(size.rawValue) width")
                XCTAssertEqual(layout.unclampedHeight.rounded(), layout.unclampedHeight,
                               "\(size.rawValue) height")
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
        XCTAssertEqual(grand.clampedToVisibleFrame(1200), grand.unclampedHeight)
    }

    @Test
    func testScreenFitClampShrinksForShortScreens() {
        let grand = PanelLayout.resolve(
            panelSizeRaw: PanelSize.grand.rawValue, densityRaw: ContentDensity.standard.rawValue,
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        // A 600 pt visible frame must never be asked for more than fits.
        let fitted = grand.clampedToVisibleFrame(600)
        XCTAssertLessThanOrEqual(fitted, 576) // 600 - 24 margin
        XCTAssertTrue(fitted >= PanelLayout.minimumHeight)
    }

    @Test
    func testScreenFitClampNeverGoesBelowMinimum() {
        let compact = PanelLayout.resolve(
            panelSizeRaw: PanelSize.compact.rawValue, densityRaw: ContentDensity.compact.rawValue,
            customEnabled: false, customWidth: 0, customHeight: 0
        )
        XCTAssertEqual(compact.clampedToVisibleFrame(100), PanelLayout.minimumHeight)
    }

    // MARK: - Dimensions label

    @Test
    func testDimensionsLabelFormat() {
        XCTAssertEqual(PanelSize.standard.dimensionsLabel, "430 × 580")
        XCTAssertEqual(PanelSize.grand.dimensionsLabel, "600 × 760")
    }
}
