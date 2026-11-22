import Foundation
import Testing
@testable import Hisingen

/// Banner buttons are the only place a command can be sent without opening the app, so the
/// identifier-to-command map is worth pinning: a typo here silently turns a button into a no-op.
struct NotificationQuickActionTests {
    @Test
    func everyRegisteredActionMapsToACommand() {
        let expected: [(String, Notifier.QuickAction)] = [
            ("lock-vehicle", .lockVehicle),
            (Notifier.unlockVehicleActionID, .unlockVehicle),
            (Notifier.startClimateActionID, .startClimate),
            ("resume-charge", .resumeChargeSchedule),
            (Notifier.viewDetailsActionID, .viewDetails),
        ]
        for (identifier, _) in expected {
            #expect(Notifier.quickAction(forActionIdentifier: identifier) != nil, "\(identifier)")
        }
        #expect(Notifier.unlockVehicleActionID == "unlock-vehicle")
        #expect(Notifier.startClimateActionID == "start-climate")
        #expect(Notifier.viewDetailsActionID == "view-details")
    }

    @Test
    func mutingIsNotACommand() {
        // Mute is a local preference, so it must never come back as a QuickAction.
        #expect(Notifier.quickAction(forActionIdentifier: Notifier.muteVehicleActionID) == nil)
    }

    @Test
    func unknownIdentifiersAreIgnored() {
        #expect(Notifier.quickAction(forActionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
    }
}
