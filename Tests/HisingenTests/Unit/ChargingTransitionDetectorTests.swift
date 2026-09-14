import Foundation
import Testing
@testable import Hisingen

struct ChargingTransitionDetectorTests {
    private let detector = ChargingTransitionDetector()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func testStartAndCompletionAreEmittedOnce() {
        let idle = detector.evaluate(previous: nil, current: sample(.idle, battery: 30, offset: -30),
                                     lowBatteryThreshold: 20, now: now)
        let started = detector.evaluate(previous: idle.baseline,
                                        current: sample(.charging, battery: 31, offset: -20),
                                        lowBatteryThreshold: 20, now: now)
        #expect(started.events == [.started])
        let duplicate = detector.evaluate(previous: started.baseline,
                                          current: sample(.charging, battery: 31, offset: -20),
                                          lowBatteryThreshold: 20, now: now)
        #expect(duplicate.events.isEmpty)
        let completed = detector.evaluate(previous: started.baseline,
                                          current: sample(.complete, battery: 80, offset: -10),
                                          lowBatteryThreshold: 20, now: now)
        #expect(completed.events == [.completed])
    }

    @Test
    func testInterruptedRequiresTwoSamples() {
        let first = detector.evaluate(previous: nil,
                                      current: sample(.charging, battery: 45, offset: -30),
                                      lowBatteryThreshold: 20, now: now)
        let possible = detector.evaluate(previous: first.baseline,
                                         current: sample(.idle, battery: 45, offset: -20),
                                         lowBatteryThreshold: 20, now: now)
        #expect(possible.events.isEmpty)
        let confirmed = detector.evaluate(previous: possible.baseline,
                                          current: sample(.idle, battery: 45, offset: -10),
                                          lowBatteryThreshold: 20, now: now)
        #expect(confirmed.events == [.interrupted])
    }

    @Test
    func testFaultIsImmediateAndOldEventsAreSuppressed() {
        let recent = detector.evaluate(previous: nil,
                                       current: sample(.charging, battery: 45, offset: -30),
                                       lowBatteryThreshold: 20, now: now)
        let recentFault = detector.evaluate(previous: recent.baseline,
                                            current: sample(.fault, battery: 45, offset: -20),
                                            lowBatteryThreshold: 20, now: now)
        #expect(recentFault.events == [.fault])

        let first = detector.evaluate(previous: nil,
                                      current: sample(.charging, battery: 45, offset: -1_500),
                                      lowBatteryThreshold: 20, now: now)
        let fault = detector.evaluate(previous: first.baseline,
                                      current: sample(.fault, battery: 45, offset: -1_400),
                                      lowBatteryThreshold: 20, now: now)
        #expect(fault.events.isEmpty)
    }

    @Test
    func testRefreshPolicyBoundsPollingAndBackoff() {
        #expect(RefreshPolicy.regularInterval(isCharging: true) == 120)
        #expect(RefreshPolicy.regularInterval(isCharging: false) == 600)
        #expect(RefreshPolicy.retryDelay(failureCount: 1, retryAfter: nil) == 30)
        #expect(RefreshPolicy.retryDelay(failureCount: 4, retryAfter: nil) == 240)
        #expect(RefreshPolicy.retryDelay(failureCount: 99, retryAfter: nil) == 900)
        #expect(RefreshPolicy.retryDelay(failureCount: 1, retryAfter: 5) == 30)
        #expect(RefreshPolicy.retryDelay(failureCount: 1, retryAfter: 7_200) == 3_600)
    }

    @Test
    func testLowBatteryUsesHysteresis() {
        let high = detector.evaluate(previous: nil, current: sample(.idle, battery: 30, offset: -30),
                                     lowBatteryThreshold: 20, now: now)
        let low = detector.evaluate(previous: high.baseline, current: sample(.idle, battery: 19, offset: -20),
                                    lowBatteryThreshold: 20, now: now)
        #expect(low.events == [.lowBattery(threshold: 20)])
        let stillLow = detector.evaluate(previous: low.baseline, current: sample(.idle, battery: 18, offset: -10),
                                         lowBatteryThreshold: 20, now: now)
        #expect(stillLow.events.isEmpty)
    }

    private func sample(_ state: ChargingState, battery: Double, offset: TimeInterval) -> VehicleState {
        vehicle(battery: battery, state: state,
                connection: state.isActivelyCharging ? .connected : .disconnected,
                fetchedAt: now.addingTimeInterval(offset), reportedAt: now.addingTimeInterval(offset))
    }
}

