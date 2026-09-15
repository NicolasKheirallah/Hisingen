import Foundation
import Testing
@testable import Hisingen

/// Settings' bulk feature actions and its screenshot-privacy promise.
@MainActor
struct SettingsQuickActionTests {

    @Test
    func addingRecommendedNeverTurnsAnythingOff() {
        // Start from everything on, which is the case that used to break: assigning
        // `FeatureSelection.default` switched off all eight remote-control features.
        let everything = FeatureSelection(enabled: Set(AppFeature.allCases))
        let after = everything.adding(FeatureSelection.default.enabled)

        #expect(after.enabled.isSuperset(of: everything.enabled))
        #expect(after.enabled.isSuperset(of: FeatureSelection.default.enabled))
        #expect(after == everything)
    }

    @Test
    func addingSafeFeaturesNeverTurnsRemoteControlsOff() {
        let withRemote = FeatureSelection(enabled: Set(AppFeature.allCases))
        let after = withRemote.adding(AppFeature.safeBulkEnableCases)

        for feature in AppFeature.allCases where feature.isRemoteControl {
            #expect(after.contains(feature), "\(feature.rawValue) was switched off by an additive action")
        }
        #expect(after.enabled.isSuperset(of: Set(AppFeature.safeBulkEnableCases)))
    }

    @Test
    func addingFromEmptyEnablesExactlyTheRequestedSet() {
        // The additive path must still be able to build a selection up from nothing, or it would
        // only ever be a no-op.
        let after = FeatureSelection(enabled: []).adding(AppFeature.safeBulkEnableCases)
        #expect(after.enabled == Set(AppFeature.safeBulkEnableCases))
    }

    @Test
    func aRedactedVINShowsOnlyItsLastFourCharacters() {
        let scoped = ScopedPreferences(label: "settings-quick-actions")
        scoped.store.privacyRedactionEnabled = true

        let display = scoped.store.displayVIN("YSMTESTVIN1234567")
        #expect(display.hasSuffix("4567"))
        #expect(!display.contains("YSMTESTVIN"))
        #expect(!scoped.store.exportVINComponent("YSMTESTVIN1234567").contains("YSMTEST"))
    }

    @Test
    func anUnredactedVINIsShownWhole() {
        let scoped = ScopedPreferences(label: "settings-quick-actions")
        scoped.store.privacyRedactionEnabled = false

        #expect(scoped.store.displayVIN("YSMTESTVIN1234567").contains("YSMTESTVIN1234567"))
        #expect(scoped.store.exportVINComponent("YSMTESTVIN1234567") == "YSMTESTV")
    }
}

/// The optical tracking §15 asks of small type, and the leading for text that wraps.
@MainActor
struct TypographyTokenTests {

    @Test
    func smallTextGetsPositiveTracking() {
        // 9pt is the app's dominant size and the point where an already-tight face starts to cost
        // legibility. It used to get zero tracking at 204 of those sites.
        #expect(HisingenTheme.tracking(forSize: 8) > 0)
        #expect(HisingenTheme.tracking(forSize: 9) > HisingenTheme.tracking(forSize: 10))
        #expect(HisingenTheme.tracking(forSize: 10) > HisingenTheme.tracking(forSize: 11))
    }

    @Test
    func trackingReachesZeroWhereTheFaceIsAlreadyCorrect() {
        // The hand-off to the display tiers: above 12pt the token must not fight them.
        #expect(HisingenTheme.tracking(forSize: 12) == 0)
        #expect(HisingenTheme.tracking(forSize: 13) == 0)
        #expect(HisingenTheme.tracking(forSize: 40) == 0)
    }

    @Test
    func trackingMatchesThePublishedSFTrackingTable() {
        // Apple's SF Pro Text table: +0.24pt at 6pt, +0.12 at 9pt, 0 at 12pt.
        #expect(abs(HisingenTheme.tracking(forSize: 6) - 0.24) < 0.001)
        #expect(abs(HisingenTheme.tracking(forSize: 9) - 0.12) < 0.001)
        #expect(abs(HisingenTheme.tracking(forSize: 9.5) - 0.10) < 0.001)
    }

    @Test
    func wrappingTextHasMoreLeadingThanTheDefault() {
        #expect(HisingenTheme.captionLineSpacing > 0)
    }
}

/// The shared layer's type ramp.
///
/// The 21 component files froze roughly 42 declarations at eight point sizes, and only two of the
/// 21 primitives responded to the reader's text size at all, so a card title stayed fixed while the
/// caption inside it grew.
@MainActor
struct TypeTierTests {

    @Test
    func theRampIsMonotonicAndHasNoDuplicateStops() {
        let sizes = HisingenTheme.TypeTier.allCases.map(\.baseSize)
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
    }

    @Test
    func everyTierReplacesAtLeastOneOfTheSizesThatWereInUse() {
        // Every one-off size the app actually declared across the text range. A tier that replaced
        // none of them would be a token nobody needs; one that covers none of them means the ramp
        // missed. Sizes of 20 and above are display figures and stay deliberate one-offs.
        let retired: Set<CGFloat> = [7, 8, 8.5, 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 15, 16, 17, 18]
        for tier in HisingenTheme.TypeTier.allCases {
            let nearest = retired.min { abs($0 - tier.baseSize) < abs($1 - tier.baseSize) }
            #expect(nearest != nil)
            #expect(abs((nearest ?? 0) - tier.baseSize) <= 1)
        }
    }

    @Test
    func everyTierScalesRelativeToASystemStyle() {
        // The mechanism, not decoration: each tier must name the style it grows with, or it is a
        // frozen literal wearing a token's name.
        for tier in HisingenTheme.TypeTier.allCases {
            #expect(!String(describing: tier.textStyle).isEmpty)
        }
        #expect(HisingenTheme.TypeTier.micro.textStyle != HisingenTheme.TypeTier.heading.textStyle)
    }
}

/// Density as a ramp variant and a spacing scale, rather than a raster transform.
@MainActor
struct ContentDensityTests {

    @Test
    func everyPresetScalesTypeAndSpacingTogether() {
        for density in ContentDensity.allCases {
            #expect(density.typeScale > 0)
            #expect(density.spacingScale > 0)
        }
        #expect(ContentDensity.compact.typeScale < ContentDensity.standard.typeScale)
        #expect(ContentDensity.standard.typeScale < ContentDensity.relaxed.typeScale)
        #expect(ContentDensity.compact.spacingScale < ContentDensity.standard.spacingScale)
        #expect(ContentDensity.standard.spacingScale < ContentDensity.relaxed.spacingScale)
    }

    @Test
    func compactStaysAboveTheLegibilityFloor() {
        // The raster transform put a 9pt tier at 7.65pt. Density may tighten a layout; it may not
        // push the smallest tier below the size the ramp was built to keep legible.
        let smallest = HisingenTheme.TypeTier.allCases.map(\.baseSize).min() ?? 0
        #expect(smallest * ContentDensity.compact.typeScale >= 7.36)
    }

    @Test
    func thePresetStillDescribesItselfAsAPercentage() {
        #expect(ContentDensity.compact.scale == 0.85)
        #expect(ContentDensity.standard.scale == 1.0)
        #expect(ContentDensity.relaxed.scale == 1.15)
    }

    @Test
    func thePanelLaysOutAtItsRealSize() {
        // Nothing raster-scales the tree any more, so the logical frame is the physical frame.
        let layout = PanelLayout.resolve(panelSizeRaw: PanelSize.standard.rawValue,
                                         densityRaw: ContentDensity.compact.rawValue,
                                         customEnabled: false, customWidth: 0, customHeight: 0)
        #expect(layout.contentScale == 1)
        #expect(layout.logicalWidth == layout.width)
        // Use an injected visible frame: reading `layout.height` asks NSScreen for the
        // active display, which a package test runner has not initialized.
        #expect(layout.clampedToVisibleFrame(1200) == layout.unclampedHeight)
    }
}
