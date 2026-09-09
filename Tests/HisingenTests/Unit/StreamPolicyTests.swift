import Foundation
import Testing
@testable import Hisingen

/// Unit coverage for the live-stream decision policy: the charging-only gate, the
/// exponential backoff ladder with jitter and Retry-After, the circuit breakers, and the
/// stability rule that only resets failures after a real connection held for a while.
struct StreamPolicyTests {
    private func state(charging: Bool, available: VehicleAvailability = .available,
                       climateActive: Bool = false) -> VehicleState {
        VehicleState(
            batteryPercentage: 60, rangeKm: 300,
            chargingState: charging ? .charging : .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: charging ? .ac : .none,
            chargerConnection: charging ? .connected : .disconnected,
            availability: available,
            modelName: "Polestar 2", modelYear: nil, registrationNo: nil,
            vin: "YS2P2000000000001", ownerFirstName: nil, odometerKm: nil,
            climateStatus: climateActive
                ? VehicleClimateStatus(activity: .active, timeRemainingMinutes: nil, timerTriggered: false)
                : nil,
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: nil, dataWarnings: []
        )
    }

    // MARK: - Gate

    /// The honesty gate: the only Polestar stream is battery state, so it opens for charging
    /// alone. Climate activity must not keep a battery connection alive by itself — the
    /// two-minute poll already covers climate freshness.
    @Test
    func gateStreamsOnlyWhileChargingAndAvailable() {
        let policy = LiveStreamPolicy()
        #expect(policy.shouldStream(state(charging: true)))
        #expect(!policy.shouldStream(state(charging: false)))
        #expect(!policy.shouldStream(state(charging: false, climateActive: true)))
        // Charging is the streaming reason; concurrent climate activity changes nothing.
        #expect(policy.shouldStream(state(charging: true, climateActive: true)))
        // An asleep vehicle answers streams with stale frames; never stream it.
        #expect(!policy.shouldStream(state(charging: true, available: .unavailable(reason: nil))))
    }

    @Test
    func customGateOverridesDefault() {
        let policy = LiveStreamPolicy(shouldStream: { _ in true })
        #expect(policy.shouldStream(state(charging: false)))
    }

    // MARK: - Stability

    /// Backoff resets only after meaningful stability — ten connected minutes — not when the
    /// socket merely opens.
    @Test
    func stabilityRequiresSustainedConnection() {
        let policy = LiveStreamPolicy(stabilityInterval: 600)
        let now = Date()
        #expect(!policy.isStable(connectedAt: nil, now: now))
        #expect(!policy.isStable(connectedAt: now.addingTimeInterval(-599), now: now))
        #expect(policy.isStable(connectedAt: now.addingTimeInterval(-600), now: now))
    }

    // MARK: - Backoff

    @Test
    func backoffLadderClimbsAndCapsAtFiveMinutes() {
        let policy = LiveStreamPolicy()
        for (index, expected) in [5.0, 15.0, 30.0, 60.0, 120.0, 300.0].enumerated() {
            #expect(policy.retryDelay(consecutiveFailures: index + 1,
                                      retryAfter: nil, jitterUnit: 0) == expected)
        }
        #expect(policy.retryDelay(consecutiveFailures: 40, retryAfter: nil, jitterUnit: 0) == 300)
        #expect(policy.retryDelay(consecutiveFailures: 0, retryAfter: nil, jitterUnit: 0) == 5)
    }

    /// Jitter adds at most 20 % and never goes negative — still bounded, so bursts stay tame.
    @Test
    func jitterStaysWithinTwentyPercent() {
        let policy = LiveStreamPolicy()
        for unit in [0.0, 0.25, 0.5, 0.75, 1.0, 2.0, -1.0] {
            let delay = policy.retryDelay(consecutiveFailures: 1, retryAfter: nil, jitterUnit: unit)
            #expect(delay >= 5 && delay <= 6)
        }
    }

    /// A server Retry-After is honored, floored at 5 s, and capped at one hour.
    @Test
    func retryAfterIsRespectedAndClamped() {
        let policy = LiveStreamPolicy()
        #expect(policy.retryDelay(consecutiveFailures: 3, retryAfter: 42, jitterUnit: 0) == 42)
        #expect(policy.retryDelay(consecutiveFailures: 3, retryAfter: 1, jitterUnit: 0) == 5)
        #expect(policy.retryDelay(consecutiveFailures: 3, retryAfter: 10_000, jitterUnit: 0) == 3_600)
    }

    // MARK: - Circuit breakers

    /// Authorization, unsupported-method, and incompatible-schema failures open a multi-hour
    /// circuit instead of reconnecting forever.
    @Test
    func hardFailuresOpenCircuitForHours() {
        let policy = LiveStreamPolicy(unsupportedCircuitInterval: 6 * 3_600)
        let now = Date()
        let unsupported = VehicleServiceError.unsupported(provider: .polestar, service: "battery")
        let denied = VehicleServiceError.permissionDenied(provider: .polestar, operation: "battery")
        let incompatible = VehicleServiceError.incompatibleAPI(provider: .polestar, operation: "battery")
        for error in [unsupported, denied, incompatible] {
            guard case .openCircuit(let until) = policy.action(
                for: error, consecutiveFailures: 1, authorizationRecoveryUsed: false,
                now: now, jitterUnit: 0
            ) else {
                Issue.record("Expected an open circuit for \(error)")
                continue
            }
            #expect(until.timeIntervalSince(now) >= 6 * 3_600 - 1)
        }
    }

    /// First authentication failure is an authorization refresh; a second one means the
    /// shared refresh is not helping and the circuit opens instead of looping 401s.
    @Test
    func authenticationFailureRecoversOnceThenOpensCircuit() {
        let policy = LiveStreamPolicy(repeatedFailureCircuitInterval: 1_800)
        let now = Date()
        let auth = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        #expect(policy.action(for: auth, consecutiveFailures: 1,
                              authorizationRecoveryUsed: false, now: now, jitterUnit: 0)
            == .refreshAuthorization(after: 5))
        guard case .openCircuit(let until) = policy.action(
            for: auth, consecutiveFailures: 2, authorizationRecoveryUsed: true,
            now: now, jitterUnit: 0
        ) else {
            Issue.record("Expected a circuit after a failed authorization recovery")
            return
        }
        #expect(until.timeIntervalSince(now) >= 1_800 - 1)
    }

    /// A rate limit is a plain retry on the server's own schedule, never a circuit.
    @Test
    func rateLimitRetriesOnServerSchedule() {
        let policy = LiveStreamPolicy()
        let now = Date()
        let action = policy.action(
            for: .rateLimited(retryAfter: 90), consecutiveFailures: 4,
            authorizationRecoveryUsed: false, now: now, jitterUnit: 0
        )
        #expect(action == .retry(after: 90))
    }

    /// Generic transient failures retry with the ladder until the consecutive-failure budget
    /// is spent; only then does the repeated-failure circuit open.
    @Test
    func transientFailuresRetryThenOpenCircuit() {
        let policy = LiveStreamPolicy(repeatedFailureCircuitInterval: 1_800,
                                      maximumFailuresBeforeCircuit: 6)
        let now = Date()
        let transient = VehicleServiceError.temporarilyUnavailable(provider: .polestar, service: "battery")
        for failure in 1...5 {
            #expect({
                if case .retry = policy.action(for: transient, consecutiveFailures: failure,
                                               authorizationRecoveryUsed: false, now: now,
                                               jitterUnit: 0) { return true }
                return false
            }())
        }
        guard case .openCircuit = policy.action(
            for: transient, consecutiveFailures: 6, authorizationRecoveryUsed: false,
            now: now, jitterUnit: 0
        ) else {
            Issue.record("Expected a circuit at the failure budget")
            return
        }
    }
}
