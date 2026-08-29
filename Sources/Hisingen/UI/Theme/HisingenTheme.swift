import SwiftUI

/// Design-token namespace for the whole app. Every visual constant is resolved
/// from the user's selected `AppTheme`, so a single Settings toggle restyles the
/// panel. The surface area is large, so it is split across focused files:
///
/// - `HisingenTheme.swift` — the type plus panel / layout geometry
/// - `HisingenTheme+Palette.swift` — brand and semantic colour tokens
/// - `HisingenTheme+Surfaces.swift` — card and popover surface styling
/// - `HisingenTheme+Typography.swift` — font weights, tracking, decorative tint
/// - `HisingenTheme+StatusColors.swift` — status / chart colours and domain helpers
@MainActor
enum HisingenTheme {
    static var theme: AppTheme { PreferencesStore.shared.appTheme }
    static var isPolestar: Bool { theme == .polestar }


    static var cornerRadius: CGFloat {
        switch theme {
        case .polestar: return 0
        case .cyanRacing: return 8
        case .volvo, .swedishGold: return 10
        case .nordicNight, .sandDune: return 12
        case .hisingen, .forest: return 14
        case .aurora: return 16
        }
    }
    static var cardPadding: CGFloat {
        switch theme {
        case .hisingen, .cyanRacing: return 14
        case .nordicNight, .aurora, .forest: return 15
        case .polestar, .volvo, .swedishGold, .sandDune: return 16
        }
    }
    static let sectionSpacing: CGFloat = 12
    static let smallSpacing: CGFloat = 8
    /// Live panel geometry from the selected size preset / custom overrides /
    /// density zoom, resolved through PanelLayout so every consumer agrees.
    /// Re-evaluated on each layout pass: changing any of the three in Settings
    /// resizes the open dropdown immediately.
    static var panelLayout: PanelLayout { .resolve(from: .shared) }
    static var popoverWidth: CGFloat { panelLayout.width }
    static var popoverIdealHeight: CGFloat { panelLayout.height }
    /// Content zoom factor from the density preset; <1 shows more content in the same
    /// panel, >1 enlarges it.
    static var contentScale: CGFloat { panelLayout.contentScale }
    /// Width that fixed-width views must lay out at *inside* the zoom wrapper: the tree
    /// is laid out at panelWidth / scale and then scaled by `contentScale`, so this —
    /// not `popoverWidth` — keeps those views exactly filling the visible panel.
    static var layoutWidth: CGFloat { panelLayout.logicalWidth }
}
