import AppKit

/// Owns the Dock-tile badge that shows how many vehicles are reporting a warning or alarm.
///
/// Inert for menu-bar-only users (the Dock icon is hidden there anyway) and gated behind both
/// the Notifications feature and the "Show warning badge" preference. Extracted from
/// `AppDelegate`, which tracked the count and the paint rules inline.
@MainActor
final class DockWarningBadge {
    private let preferences: PreferencesStore
    private var vehicleCount = 0

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    /// Records a new warning-vehicle count and repaints.
    func update(vehicleCount: Int) {
        self.vehicleCount = vehicleCount
        refresh()
    }

    /// Repaints from the current count — call after a settings change that could flip the
    /// gating preferences.
    func refresh() {
        guard preferences.features.contains(.notifications), preferences.showWarningBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        NSApp.dockTile.badgeLabel = vehicleCount > 0 ? "\(vehicleCount)" : nil
    }
}
