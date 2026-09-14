import Foundation
import OSLog

/// Owns the live-stream connection lifecycle: the connection task, the reconnect loop with
/// the backoff policy's retry/circuit/authorization-recovery decisions, and stream metrics.
/// Its whole interface is `setPurpose` plus the events it emits, so callers never juggle
/// bare stream fields or hand-maintained reset lists.
@MainActor
final class LiveStreamEngine {
    /// What the app does with stream transitions. Frame handling and poll cadence stay with
    /// the refresh coordinator; the engine only needs yes/no answers to keep going. The
    /// closures bind to one engine run — a restart builds fresh ones against the new
    /// generation, which is what makes stale frames stop the old task.
    struct Context {
        /// Loop guard per attempt: is this purpose + VIN still what the app wants to stream?
        let isDesired: @MainActor (VehicleLiveStreamPurpose, String) -> Bool
        /// Connected transition — the coordinator re-times its polls around an open stream.
        let onConnected: @MainActor () -> Void
        /// One telemetry frame. Returns false when the stream must stop (stale vehicle or
        /// generation). `.connected` frames never reach here.
        let onFrame: @MainActor (VehicleLiveUpdate) async -> Bool
        /// Disconnected transition — the coordinator schedules its fallback poll.
        let onDisconnected: @MainActor () -> Void
        /// The task ended and the engine reset itself; the coordinator may restart it.
        let onIdle: @MainActor () -> Void
    }

    private let streaming: any VehicleLiveStreaming
    private let providerBrand: VehicleBrand
    private let policy: LiveStreamPolicy
    private let jitter: () -> Double
    private let now: () -> Date
    private let context: Context
    private let logger = AppLog.logger("live-stream")

    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private(set) var purpose: VehicleLiveStreamPurpose?
    private(set) var isConnected = false
    private(set) var retryAt: Date?
    private(set) var metrics = LiveStreamMetrics()
    private var lastAppliedFrame: VehicleLiveUpdate?

    init(streaming: any VehicleLiveStreaming,
         providerBrand: VehicleBrand,
         policy: LiveStreamPolicy,
         jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         now: @escaping () -> Date = Date.init,
         context: Context) {
        self.streaming = streaming
        self.providerBrand = providerBrand
        self.policy = policy
        self.jitter = jitter
        self.now = now
        self.context = context
    }

    var isRunning: Bool { task != nil }

    /// Starts streaming for the purpose, or stops when the purpose is `nil`. A running
    /// engine is left alone — callers stop it first if they want a different run.
    func setPurpose(_ newPurpose: VehicleLiveStreamPurpose?, vin: String) {
        guard let newPurpose else {
            stop()
            return
        }
        guard task == nil else { return }
        purpose = newPurpose
        let runningTaskID = UUID()
        taskID = runningTaskID
        task = Task { [weak self] in
            defer {
                if let self, self.taskID == runningTaskID {
                    self.resetAfterTaskEnd()
                    self.context.onIdle()
                }
            }
            var failure = 0
            var authorizationRecoveryUsed = false
            while !Task.isCancelled {
                guard let self, self.context.isDesired(newPurpose, vin) else { return }
                let streamStartedAt = now()
                var connectedAt: Date?
                do {
                    metrics.connectionAttempts += 1
                    let stream = try await streaming.liveVehicleUpdates(vin: vin, purpose: newPurpose)
                    lastAppliedFrame = nil
                    for try await update in stream {
                        try Task.checkCancellation()
                        if case .connected(let activeTransportStreams) = update {
                            connectedAt = now()
                            isConnected = true
                            retryAt = nil
                            metrics.successfulConnections += 1
                            metrics.activeTransportStreams = activeTransportStreams
                            metrics.connectedAt = connectedAt
                            metrics.circuitOpenUntil = nil
                            context.onConnected()
                            continue
                        }
                        metrics.messagesReceived += 1
                        metrics.lastFrameAt = now()
                        metrics.lastDisconnectedAt = nil
                        guard update != lastAppliedFrame else { continue }
                        lastAppliedFrame = update
                        guard await context.onFrame(update) else { return }
                    }
                    throw VehicleServiceError.temporarilyUnavailable(
                        provider: providerBrand, service: "live vehicle stream"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    let failedAt = now()
                    isConnected = false
                    metrics.activeTransportStreams = 0
                    metrics.connectedAt = nil
                    metrics.disconnects += 1
                    metrics.lastDisconnectedAt = failedAt
                    let duration = failedAt.timeIntervalSince(connectedAt ?? streamStartedAt)
                    metrics.lastConnectionDuration = max(0, duration)
                    let mapped = ServiceErrorPolicy.decision(error, provider: providerBrand).error
                    metrics.lastDisconnectReason = DiagnosticRedaction.redact(String(describing: mapped))
                    if duration >= policy.stabilityInterval {
                        failure = 0
                        authorizationRecoveryUsed = false
                    }
                    failure += 1
                    let action = policy.action(
                        for: mapped, consecutiveFailures: failure,
                        authorizationRecoveryUsed: authorizationRecoveryUsed,
                        now: failedAt, jitterUnit: jitter()
                    )
                    let delay: TimeInterval
                    switch action {
                    case .retry(let retryDelay):
                        delay = retryDelay
                    case .refreshAuthorization(let retryDelay):
                        authorizationRecoveryUsed = true
                        do {
                            try await streaming.refreshLiveStreamAuthorization()
                            metrics.authorizationRefreshes += 1
                        } catch {
                            logger.warning("Live stream token recovery failed: \(String(describing: error), privacy: .public)")
                        }
                        delay = retryDelay
                    case .openCircuit(let until):
                        metrics.circuitOpenUntil = until
                        delay = max(0, until.timeIntervalSince(failedAt))
                    }
                    retryAt = failedAt.addingTimeInterval(delay)
                    context.onDisconnected()
                    logger.warning("Live stream dropped; retrying in \(Int(delay), privacy: .public)s: \(String(describing: mapped), privacy: .public)")
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    if case .openCircuit = action {
                        failure = 0
                        authorizationRecoveryUsed = false
                        metrics.circuitOpenUntil = nil
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        taskID = nil
        purpose = nil
        resetConnectionState()
    }

    /// Counts a timer poll that had to run because the stream had not connected.
    func noteFallbackPoll() {
        if isRunning && !isConnected {
            metrics.fallbackPolls += 1
        }
    }

    private func resetConnectionState() {
        isConnected = false
        retryAt = nil
        metrics.activeTransportStreams = 0
        metrics.connectedAt = nil
    }

    /// The task ended on its own (stream exhausted, guard failed, cancelled); a fresh start
    /// becomes possible and the old run's transitional fields clear.
    private func resetAfterTaskEnd() {
        task = nil
        taskID = nil
        purpose = nil
        lastAppliedFrame = nil
        resetConnectionState()
    }
}
