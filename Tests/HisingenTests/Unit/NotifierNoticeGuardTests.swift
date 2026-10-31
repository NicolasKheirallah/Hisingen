import Foundation
import Testing
import UserNotifications
@testable import Hisingen

@Suite("Notifier notice guards")
@MainActor
struct NotifierNoticeGuardTests {

    @Test func commandNoticeIsSuppressedWhenNotificationsAreOff() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.features = FeatureSelection(enabled: [])
        let notifier = harness.makeNotifier()

        notifier.notifyCommandNotice(title: "Vehicle Switch Paused", body: "Slow down.")
        await harness.drainNotificationHops()

        #expect(harness.dispatcher.added.isEmpty)
    }

    @Test func chargingAnomalyIsSuppressedWhenNotificationsAreOff() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.features = FeatureSelection(enabled: [])
        let notifier = harness.makeNotifier()

        notifier.notifyChargingAnomaly(locationName: "Home", vin: NotificationTestHarness.vin)
        await harness.drainNotificationHops()

        #expect(harness.dispatcher.added.isEmpty)
    }

    @Test func commandNoticePostsWhenNotificationsAreOn() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()

        notifier.notifyCommandNotice(title: "Vehicle Switch Paused", body: "Slow down.")
        await harness.drainNotificationHops()

        #expect(harness.dispatcher.added.count == 1)
    }

    @Test func repeatedCommandNoticeReusesIdentifierSoItReplacesTheBanner() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()

        notifier.notifyCommandNotice(title: "Vehicle Switch Paused", body: "Slow down.")
        notifier.notifyCommandNotice(title: "Vehicle Switch Paused", body: "Slow down.")
        await harness.drainNotificationHops()

        let identifiers = harness.dispatcher.added.map(\.identifier)
        #expect(identifiers.count == 2)
        #expect(Set(identifiers).count == 1)
    }

    @Test func repeatedChargingAnomalyReusesIdentifierPerVehicle() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()

        notifier.notifyChargingAnomaly(locationName: "Home", vin: NotificationTestHarness.vin)
        notifier.notifyChargingAnomaly(locationName: "Work", vin: NotificationTestHarness.vin)
        await harness.drainNotificationHops()

        let identifiers = harness.dispatcher.added.map(\.identifier)
        #expect(identifiers.count == 2)
        #expect(Set(identifiers).count == 1)
    }
}
