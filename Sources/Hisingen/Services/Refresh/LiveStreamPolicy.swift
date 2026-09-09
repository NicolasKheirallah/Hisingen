import Foundation

enum LiveStreamFailureAction: Equatable, Sendable {
    case retry(after: TimeInterval)
    case refreshAuthorization(after: TimeInterval)
    case openCircuit(until: Date)
}

struct LiveStreamPolicy: Sendable {
    let stabilityInterval: TimeInterval
    let integrityPollInterval: TimeInterval
    let unsupportedCircuitInterval: TimeInterval
    let repeatedFailureCircuitInterval: TimeInterval
    let maximumFailuresBeforeCircuit: Int
    private let retrySteps: [TimeInterval]
    private let customGate: (@Sendable (VehicleState) -> Bool)?

    init(
        stabilityInterval: TimeInterval = 10 * 60,
        integrityPollInterval: TimeInterval = 30 * 60,
        unsupportedCircuitInterval: TimeInterval = 6 * 60 * 60,
        repeatedFailureCircuitInterval: TimeInterval = 30 * 60,
        maximumFailuresBeforeCircuit: Int = 6,
        retrySteps: [TimeInterval] = [5, 15, 30, 60, 120, 300],
        shouldStream: (@Sendable (VehicleState) -> Bool)? = nil
    ) {
        self.stabilityInterval = stabilityInterval
        self.integrityPollInterval = integrityPollInterval
        self.unsupportedCircuitInterval = unsupportedCircuitInterval
        self.repeatedFailureCircuitInterval = repeatedFailureCircuitInterval
        self.maximumFailuresBeforeCircuit = maximumFailuresBeforeCircuit
        self.retrySteps = retrySteps
        self.customGate = shouldStream
    }

    /// Only the available-car charging gate streams by default: the Polestar battery stream
    /// carries charging and battery readings, so an open connection while climate runs adds
    /// traffic without making climate fresher — the normal two-minute poll covers it.
    /// An asleep vehicle answers every stream with the same stale frames, so it never streams.
    func shouldStream(_ state: VehicleState) -> Bool {
        if let customGate { return customGate(state) }
        guard case .unavailable = state.availability else {
            return state.isCharging
        }
        return false
    }

    func isStable(connectedAt: Date?, now: Date) -> Bool {
        guard let connectedAt else { return false }
        return now.timeIntervalSince(connectedAt) >= stabilityInterval
    }

    func action(
        for error: VehicleServiceError,
        consecutiveFailures: Int,
        authorizationRecoveryUsed: Bool,
        now: Date,
        jitterUnit: Double
    ) -> LiveStreamFailureAction {
        switch error {
        case .unsupported, .permissionDenied, .incompatibleAPI:
            return .openCircuit(until: now.addingTimeInterval(unsupportedCircuitInterval))
        case .authenticationRequired where !authorizationRecoveryUsed:
            return .refreshAuthorization(after: retryDelay(
                consecutiveFailures: consecutiveFailures, retryAfter: nil, jitterUnit: jitterUnit
            ))
        case .authenticationRequired:
            return .openCircuit(until: now.addingTimeInterval(repeatedFailureCircuitInterval))
        case .rateLimited(let retryAfter):
            return .retry(after: retryDelay(
                consecutiveFailures: consecutiveFailures, retryAfter: retryAfter, jitterUnit: jitterUnit
            ))
        default:
            if consecutiveFailures >= maximumFailuresBeforeCircuit {
                return .openCircuit(until: now.addingTimeInterval(repeatedFailureCircuitInterval))
            }
            return .retry(after: retryDelay(
                consecutiveFailures: consecutiveFailures, retryAfter: nil, jitterUnit: jitterUnit
            ))
        }
    }

    func retryDelay(
        consecutiveFailures: Int,
        retryAfter: TimeInterval?,
        jitterUnit: Double
    ) -> TimeInterval {
        if let retryAfter {
            return min(max(retryAfter, 5), 3_600)
        }
        let index = min(max(consecutiveFailures - 1, 0), retrySteps.count - 1)
        let base = retrySteps[index]
        return base + base * 0.2 * min(max(jitterUnit, 0), 1)
    }
}

struct LiveStreamMetrics: Sendable {
    var connectionAttempts = 0
    var successfulConnections = 0
    var disconnects = 0
    var messagesReceived = 0
    var authorizationRefreshes = 0
    var fallbackPolls = 0
    var activeTransportStreams = 0
    var connectedAt: Date?
    var lastFrameAt: Date?
    var lastDisconnectedAt: Date?
    var lastConnectionDuration: TimeInterval?
    var lastDisconnectReason: String?
    var circuitOpenUntil: Date?
}
