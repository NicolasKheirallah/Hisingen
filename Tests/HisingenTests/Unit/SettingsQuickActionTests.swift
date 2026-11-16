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
    func runningTextTracksLikePolestarDotCom() {
        // polestar.com sets 16pt running text at -0.3pt; the ratio keeps that relationship at
        // every size from 11pt up, so 13pt body tightens by the same proportion.
        #expect(abs(HisingenTheme.tracking(forSize: 16) - -0.304) < 0.001)
        #expect(HisingenTheme.tracking(forSize: 13) < 0)
        #expect(HisingenTheme.tracking(forSize: 11) < 0)
    }

    @Test
    func smallTextGivesBackAir() {
        // Below 11pt Helvetica Neue's counters close under negative tracking.
        #expect(abs(HisingenTheme.tracking(forSize: 8) - 0.09) < 0.001)
        #expect(abs(HisingenTheme.tracking(forSize: 10) - 0.03) < 0.001)
    }

    @Test
    func displayTrackingIsTighterThanText() {
        // 30pt headings at -1.2pt on polestar.com, about -0.04em.
        #expect(HisingenTheme.displayTracking(forSize: 30) < HisingenTheme.tracking(forSize: 16))
        #expect(abs(HisingenTheme.displayTracking(forSize: 30) - -1.08) < 0.001)
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
        // missed. Sizes of 20 and above are display figures and stay deliberate one-offs — which
        // is exactly what the instrument's focal tiers are (display 28, displayLarge 44), so
        // they are exempt here and pinned separately below.
        let retired: Set<CGFloat> = [7, 8, 8.5, 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 15, 16, 17, 18]
        let focalDisplayTiers: Set<HisingenTheme.TypeTier> = [.display, .displayLarge]
        for tier in HisingenTheme.TypeTier.allCases where !focalDisplayTiers.contains(tier) {
            let nearest = retired.min { abs($0 - tier.baseSize) < abs($1 - tier.baseSize) }
            #expect(nearest != nil)
            #expect(abs((nearest ?? 0) - tier.baseSize) <= 1)
        }
    }

    @Test
    func theFocalDisplayTiersArePinnedOneOffs() {
        // The instrument's focal figures: one displayLarge per screen, display for the scene
        // headline. They replace no retired size by design, and their sizes are the contract.
        #expect(HisingenTheme.TypeTier.display.baseSize == 28)
        #expect(HisingenTheme.TypeTier.displayLarge.baseSize == 44)
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
    func thePresetTypeScaleIsStable() {
        #expect(ContentDensity.compact.typeScale == 0.92)
        #expect(ContentDensity.standard.typeScale == 1.0)
        #expect(ContentDensity.relaxed.typeScale == 1.12)
    }

    @Test
    func thePanelLaysOutAtItsRealSize() {
        // Nothing raster-scales the tree any more, so the logical frame is the physical frame.
        let layout = PanelLayout.resolve(panelSizeRaw: PanelSize.standard.rawValue,
                                         densityRaw: ContentDensity.compact.rawValue,
                                         customEnabled: false, customWidth: 0, customHeight: 0)
        #expect(layout.logicalWidth == layout.width)
        // Use an injected visible frame: reading `layout.height` asks NSScreen for the
        // active display, which a package test runner has not initialized.
        #expect(layout.clampedToVisibleFrame(1200) == layout.unclampedHeight)
    }
}
