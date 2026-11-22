import Foundation
import Testing
@testable import Hisingen

/// The dock badge used to be offerable while the Dock icon itself stayed hidden, so a reader
/// could turn on a switch that painted nothing. The gating order now names the Dock icon
/// explicitly, and this suite pins that order.
struct DockWarningBadgeTests {

    @Test("A visible count needs the feature, the preference, the icon and a warning")
    func fullGateShowsCount() {
        let label = DockWarningBadge.badgeLabel(
            vehicleCount: 2, alertsEnabled: true, badgeEnabled: true, dockIconVisible: true
        )
        #expect(label == "2")
    }

    @Test("A hidden Dock tile never carries a badge, whatever the other gates say")
    func hiddenDockIconSuppressesBadge() {
        let label = DockWarningBadge.badgeLabel(
            vehicleCount: 2, alertsEnabled: true, badgeEnabled: true, dockIconVisible: false
        )
        #expect(label == nil)
    }

    @Test("Turning the icon back on restores the count without a new telemetry pass")
    func iconReturnRestoresCount() {
        let label = DockWarningBadge.badgeLabel(
            vehicleCount: 3, alertsEnabled: true, badgeEnabled: true, dockIconVisible: true
        )
        #expect(label == "3")
    }

    @Test("The feature switch and the badge switch each gate on their own")
    func eachGateSuppressesAlone() {
        #expect(DockWarningBadge.badgeLabel(
            vehicleCount: 2, alertsEnabled: false, badgeEnabled: true, dockIconVisible: true
        ) == nil)
        #expect(DockWarningBadge.badgeLabel(
            vehicleCount: 2, alertsEnabled: true, badgeEnabled: false, dockIconVisible: true
        ) == nil)
    }

    @Test("No warnings means no badge even with everything enabled")
    func zeroCountShowsNothing() {
        let label = DockWarningBadge.badgeLabel(
            vehicleCount: 0, alertsEnabled: true, badgeEnabled: true, dockIconVisible: true
        )
        #expect(label == nil)
    }
}
