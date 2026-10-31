import Foundation
import Testing
@testable import Hisingen

@Suite("Sustained notification state")
@MainActor
struct NotificationAuditFixTests {
    @Test func enablingAnOngoingConditionCanDeliver() throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        var deliveries = 0
        notifier.trackSustained(condition: true, key: "car.stale", duration: 0, enabled: false) {
            deliveries += 1
        }
        #expect(deliveries == 0)
        #expect(!notifier.sustainedNotificationsDelivered.contains("car.stale"))
        notifier.trackSustained(condition: true, key: "car.stale", duration: 0, enabled: true) {
            deliveries += 1
        }
        #expect(deliveries == 1)
        notifier.trackSustained(condition: true, key: "car.stale", duration: 0, enabled: true) {
            deliveries += 1
        }
        #expect(deliveries == 1)
    }

    @Test func pendingStartSurvivesNotifierRecreation() throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        notifier.trackSustained(condition: true, key: "car.openings", duration: 600) {}
        let started = try #require(notifier.sustainedConditionStartedAt["car.openings"])
        let recreated = harness.makeNotifier()
        let restored = try #require(recreated.sustainedConditionStartedAt["car.openings"])
        #expect(abs(restored.timeIntervalSince(started)) < 0.001)
    }

    private func seedAnomalousSession(_ harness: NotificationTestHarness, vin: String, id: String) {
        let ledger = harness.store.database.charging
        for index in 0..<3 {
            let priorID = "\(id)-prior-\(index)"
            let start = Date(timeIntervalSinceNow: -Double(4 - index) * 86_400)
            ledger.startChargingSession(id: priorID, vin: vin, startSoc: 20, location: "Home", startedAt: start)
            ledger.completeChargingSession(id: priorID, endSoc: 80, energyDeliveredKwh: 30,
                                           peakPowerKw: 50, averagePowerKw: 40,
                                           endedAt: start.addingTimeInterval(3600))
        }
        ledger.startChargingSession(id: id, vin: vin, startSoc: 20, location: "Home",
                                    startedAt: Date(timeIntervalSinceNow: -300))
        ledger.completeChargingSession(id: id, endSoc: 80, energyDeliveredKwh: 30,
                                       peakPowerKw: 10, averagePowerKw: 8)
    }

    @Test func anomaliesRespectMuteQuietHoursAndPerVehicleDeduplication() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.features = FeatureSelection(enabled: [.notifications])
        let hour = Calendar.current.component(.hour, from: Date())
        harness.preferences.quietHoursEnabled = true
        harness.preferences.quietHoursStartHour = hour
        harness.preferences.quietHoursEndHour = (hour + 1) % 24
        let notifier = harness.makeNotifier()
        let vinA = NotificationTestHarness.vin
        let vinB = "YSMVSEDE6PL147229"
        seedAnomalousSession(harness, vin: vinA, id: "session-a")
        seedAnomalousSession(harness, vin: vinB, id: "session-b")
        let stateA = harness.makeState()
        var stateB = stateA
        stateB.identity.vin = vinB
        harness.preferences.setMuted(true, for: vinA)
        notifier.notifyChargingAnomalyIfNeeded(for: stateA)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.isEmpty)
        harness.preferences.setMuted(false, for: vinA)
        notifier.notifyChargingAnomalyIfNeeded(for: stateA)
        notifier.notifyChargingAnomalyIfNeeded(for: stateB)
        notifier.notifyChargingAnomalyIfNeeded(for: stateA)
        notifier.notifyChargingAnomalyIfNeeded(for: stateB)
        await harness.drainNotificationHops()
        let requests = harness.dispatcher.added
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.identifier)).count == 2)
        // Quiet hours are pinned relative to the wall clock, which this test cannot freeze. A run
        // that crosses an hour boundary turns them off between setup and the notifier's own read,
        // and an immediate post is then the correct behaviour, so only a boundary-free run can
        // prove the deferral.
        if Calendar.current.component(.hour, from: Date()) == hour {
            #expect(requests.allSatisfy { $0.trigger != nil })
        }
    }

    @Test func deniedAuthorizationDoesNotConsumeAnomaly() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.features = FeatureSelection(enabled: [.notifications])
        seedAnomalousSession(harness, vin: NotificationTestHarness.vin, id: "session")
        let denied = Notifier(stateStore: harness.store, preferences: harness.preferences,
                              defaults: harness.defaults, dispatcher: harness.dispatcher,
                              availableOverride: true, initialPermission: .denied,
                              configuresSystemIntegration: false)
        let state = harness.makeState()
        denied.notifyChargingAnomalyIfNeeded(for: state)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.isEmpty)
        let authorized = harness.makeNotifier()
        authorized.notifyChargingAnomalyIfNeeded(for: state)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.count == 1)
    }
}
