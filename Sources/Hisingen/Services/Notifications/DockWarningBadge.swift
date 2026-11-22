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

    /// The label a dock tile should carry, or nil when it should carry none. Pure so the
    /// gating order stays testable without a running app.
    nonisolated static func badgeLabel(
        vehicleCount: Int, alertsEnabled: Bool, badgeEnabled: Bool, dockIconVisible: Bool
    ) -> String? {
        guard alertsEnabled, badgeEnabled, dockIconVisible, vehicleCount > 0 else { return nil }
        return String(vehicleCount)
    }

    /// Repaints from the current count – call after a settings change that could flip the
    /// gating preferences, including the Dock icon itself.
    func refresh() {
        NSApp.dockTile.badgeLabel = Self.badgeLabel(
            vehicleCount: vehicleCount,
            alertsEnabled: preferences.features.contains(.notifications),
            badgeEnabled: preferences.showWarningBadge,
            dockIconVisible: preferences.showDockIcon
        )
    }
}
