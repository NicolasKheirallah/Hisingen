import Foundation
import AppKit

/// Single source of truth for the menu-bar dropdown's geometry. Every consumer
/// (StatusItemController's popover sizing, the SwiftUI frames, tests) resolves
/// dimensions through here instead of re-doing preset/custom/clamp arithmetic,
/// so the physical window size and the screen-fit clamp can never disagree.
///
/// All emitted points are whole numbers: non-integral widths force text into
/// fractional glyph positions, which visibly softens rendering on non-Retina
/// displays.
struct PanelLayout: Equatable {
    /// Physical panel width in points.
    let width: CGFloat
    /// Physical ideal height in points, before the screen-fit clamp.
    let unclampedHeight: CGFloat

    /// Height after clamping to what fits below the menu bar on the current
    /// screen. Popovers taller than this get shifted by AppKit and silently
    /// clip their bottom edge, so we never ask for more than fits.
    var height: CGFloat {
        clampedToVisibleFrame(Self.availablePanelHeight)
    }

    /// Pure clamp with an injected available height, so the screen-fit rule is
    /// unit-testable without depending on NSScreen.main.
    func clampedToVisibleFrame(_ availableHeight: CGFloat) -> CGFloat {
        min(unclampedHeight, max(Self.minimumHeight, availableHeight - 24))
    }

    /// Compact "430 × 580" style summary for readouts and menu items.
    var dimensionsLabel: String { "\(Int(width)) × \(Int(unclampedHeight))" }

    // MARK: - Bounds

    static let minimumWidth: CGFloat = 460
    static let maximumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 420
    static let maximumHeight: CGFloat = 860

    /// Room the popover can actually occupy: the screen's visible frame
    /// already excludes the menu bar and Dock; the remainder buys a little
    /// breathing room under the status item and above any Dock edge cases.
    ///
    /// Only the bundled app asks AppKit. `NSScreen.main` does not return nil in a process
    /// with no window-server connection — it trips an assertion inside `CGSConnectionByID`
    /// and takes the whole test runner down with it, so a package test reading this by
    /// accident aborts instead of reporting a failure. Being a bundle is the same
    /// precondition `StatusItemController` already uses to decide whether it may install a
    /// status item, and the unbundled fallback is the same value a nil screen would give.
    static var availablePanelHeight: CGFloat {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return maximumHeight }
        guard let visible = NSScreen.main?.visibleFrame.height else { return maximumHeight }
        return max(minimumHeight, visible - 24)
    }

    // MARK: - Resolution

    /// Resolves the persisted raw preference values into concrete geometry.
    /// Pure so views holding `@AppStorage` mirrors can call it directly and
    /// get SwiftUI-native invalidation, without going through a store.
    static func resolve(
        panelSizeRaw: String?,
        densityRaw: String?,
        customEnabled: Bool,
        customWidth: Double,
        customHeight: Double
    ) -> PanelLayout {
        let size = PanelSize(rawValue: panelSizeRaw ?? "") ?? .standard
        // Density is applied as spacing, not folded into the physical window.
        _ = densityRaw

        let width: CGFloat
        let height: CGFloat
        if customEnabled {
            width = clampDimension(customWidth, fallback: size.width,
                                   min: minimumWidth, max: maximumWidth)
            height = clampDimension(customHeight, fallback: size.idealHeight,
                                    min: minimumHeight, max: maximumHeight)
        } else {
            width = size.width
            height = size.idealHeight
        }
        return PanelLayout(
            width: round(width),
            unclampedHeight: round(height)
        )
    }

    /// Convenience for non-view call sites that talk to a store directly.
    /// MainActor because PreferencesStore's properties are.
    @MainActor
    static func resolve(from preferences: PreferencesStore) -> PanelLayout {
        resolve(
            panelSizeRaw: preferences.panelSize.rawValue,
            densityRaw: preferences.contentDensity.rawValue,
            customEnabled: preferences.customPanelSizeEnabled,
            customWidth: preferences.customPanelWidth,
            customHeight: preferences.customPanelHeight
        )
    }

    private static func clampDimension(_ value: Double, fallback: CGFloat,
                                       min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard value > 0 else { return fallback }
        return min(max(CGFloat(value), lower), upper)
    }
}
