import Foundation
import Testing
@testable import Hisingen

/// Connection-lifecycle coverage for `LiveStreamEngine` with a scripted transport: the connected
/// transition, duplicate-frame suppression, a coordinator rejecting a frame, the purpose guard,
/// the failure decisions (retry, authorization recovery, open circuit), and `stop()`.
///
/// The engine's reconnect wait is a real `Task.sleep` with no injected seam, so every test here
/// either stops the engine before it wakes or uses a delay long enough that it never does. The
/// clock the engine reads for timestamps is injected, so recorded retry deadlines are exact.
@MainActor
struct LiveStreamEngineTests {
    private let vin = "YSMENGINE0000001"
    private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    /// Records everything the engine tells its coordinator, and lets a test decide the verdicts.
    @MainActor
    private final class Probe {
        var frames: [VehicleLiveUpdate] = []
        var connectedCount = 0
        var disconnectCount = 0
        var idleCount = 0
        var desired = true
        var frameVerdict = true
    }

    private func makeEngine(
        streaming: FakeLiveStreaming,
        probe: Probe,
        policy: LiveStreamPolicy = LiveStreamPolicy(retrySteps: [30])
    ) -> LiveStreamEngine {
        let instant = epoch
        return LiveStreamEngine(
            streaming: streaming,
            providerBrand: .polestar,
            policy: policy,
            jitter: { 0 },
            now: { instant },
            context: .init(
                isDesired: { _, _ in probe.desired },
                onConnected: { probe.connectedCount += 1 },
                onFrame: { update in
                    probe.frames.append(update)
                    return probe.frameVerdict
                },
                onDisconnected: { probe.disconnectCount += 1 },
                onIdle: { probe.idleCount += 1 }
            )
        )
    }

    /// Frame equality is what the engine de-duplicates on, so two frames differ only by lock state.
    private func exteriorFrame(locked: Bool) -> VehicleLiveUpdate {
        .exterior(
            ExteriorSnapshot(openings: [], isLocked: locked, alarmTriggered: false, reportedAt: epoch),
            reportedAt: epoch
        )
    }

    /// Checks `condition` up to a fixed number of passes, sleeping briefly between them. The bound
    /// is a pass count, so it is not a deadline on the wall clock.
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - Connection transitions

    @Test
    func connectedFrameMarksTheStreamConnectedAndNotifiesOnce() async throws {
        let streaming = FakeLiveStreaming()
        let probe = Probe()
        let engine = makeEngine(streaming: streaming, probe: probe)

        engine.setPurpose(.charging, vin: vin)
        #expect(engine.isRunning)
        #expect(engine.purpose == .charging)
        #expect(await settle { streaming.openCount == 1 }, "The engine never opened the stream")

        streaming.send(.connected(activeTransportStreams: 1))
        #expect(await settle { engine.isConnected }, "The connected frame never reached the engine")

        #expect(probe.connectedCount == 1)
        #expect(engine.metrics.successfulConnections == 1)
        #expect(engine.metrics.activeTransportStreams == 1)
        #expect(engine.metrics.connectedAt != nil)
        #expect(engine.retryAt == nil)
        // A connected frame is a transition, not telemetry: it must not count as a message.
        #expect(engine.metrics.messagesReceived == 0)
        #expect(probe.frames.isEmpty)

        engine.stop()
    }

    @Test
    func identicalFramesReachTheCoordinatorOnlyWhenTheyChange() async throws {
        let streaming = FakeLiveStreaming()
        let probe = Probe()
        let engine = makeEngine(streaming: streaming, probe: probe)
        engine.setPurpose(.charging, vin: vin)
        _ = await settle { streaming.openCount == 1 }

        let locked = exteriorFrame(locked: true)
        let unlocked = exteriorFrame(locked: false)
        streaming.send(.connected(activeTransportStreams: 1))
        streaming.send(locked)
        streaming.send(locked)
        streaming.send(unlocked)

        // The last frame is the one that proves the duplicate was already passed over: frames are
        // consumed in order, so once `unlocked` is delivered the second `locked` has been dropped.
        #expect(await settle { probe.frames.last == unlocked })
        #expect(probe.frames == [locked, unlocked])
        // Every telemetry frame is counted as received, including the one that was dropped.
        #expect(engine.metrics.messagesReceived == 3)

        engine.stop()
    }

    @Test
    func aCoordinatorRejectionEndsTheRunAndResetsTheConnection() async throws {
        let streaming = FakeLiveStreaming()
        let probe = Probe()
        probe.frameVerdict = false
        let engine = makeEngine(streaming: streaming, probe: probe)
        engine.setPurpose(.charging, vin: vin)
        _ = await settle { streaming.openCount == 1 }

        streaming.send(.connected(activeTransportStreams: 1))
        streaming.send(exteriorFrame(locked: true))

        #expect(await settle { probe.idleCount == 1 }, "A rejected frame must end the run")
        #expect(!engine.isRunning)
        #expect(!engine.isConnected)
        #expect(engine.purpose == nil)
        #expect(probe.frames.count == 1)
    }

    // MARK: - Guards

    @Test
    func aPurposeThatIsNoLongerDesiredNeverOpensAStream() async throws {
        let streaming = FakeLiveStreaming()
        let probe = Probe()
        probe.desired = false
        let engine = makeEngine(streaming: streaming, probe: probe)

        engine.setPurpose(.charging, vin: vin)

        #expect(await settle { probe.idleCount == 1 }, "The guard must end the run before any attempt")
        #expect(streaming.openCount == 0)
        #expect(engine.metrics.connectionAttempts == 0)
        #expect(!engine.isRunning)
    }

    // MARK: - Failure decisions

    @Test
    func aTransientFailureDisconnectsAndSchedulesTheRetryFromThePolicy() async throws {
        let streaming = FakeLiveStreaming(failures: [
            VehicleServiceError.temporarilyUnavailable(provider: .polestar, service: "battery")
        ])
        let probe = Probe()
        let engine = makeEngine(streaming: streaming, probe: probe, policy: LiveStreamPolicy(retrySteps: [30]))

        engine.setPurpose(.charging, vin: vin)

        #expect(await settle { engine.retryAt != nil }, "The failed attempt never set a retry")
        #expect(probe.disconnectCount == 1)
        #expect(engine.metrics.disconnects == 1)
        #expect(engine.metrics.authorizationRefreshes == 0)
        #expect(engine.metrics.lastDisconnectReason != nil)
        // First failure, zero jitter: the first retry step, measured from the injected clock.
        #expect(engine.retryAt == epoch.addingTimeInterval(30))
        #expect(!engine.isConnected)

        engine.stop()
    }

    @Test
    func anExpiredSessionRefreshesAuthorizationOnceBeforeRetrying() async throws {
        let streaming = FakeLiveStreaming(failures: [
            VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        ])
        let probe = Probe()
        let engine = makeEngine(streaming: streaming, probe: probe, policy: LiveStreamPolicy(retrySteps: [30]))

        engine.setPurpose(.charging, vin: vin)

        #expect(await settle { engine.retryAt != nil })
        #expect(streaming.refreshCount == 1, "Exactly one authorization recovery before the retry")
        #expect(engine.metrics.authorizationRefreshes == 1)
        #expect(engine.retryAt == epoch.addingTimeInterval(30))

        engine.stop()
    }

    @Test
    func anUnsupportedStreamOpensTheCircuitForTheUnsupportedInterval() async throws {
        let streaming = FakeLiveStreaming(failures: [
            VehicleServiceError.unsupported(provider: .polestar, service: "battery")
        ])
        let probe = Probe()
        let policy = LiveStreamPolicy()
        let engine = makeEngine(streaming: streaming, probe: probe, policy: policy)

        engine.setPurpose(.charging, vin: vin)

        #expect(await settle { engine.retryAt != nil })
        let until = epoch.addingTimeInterval(policy.unsupportedCircuitInterval)
        #expect(engine.metrics.circuitOpenUntil == until)
        #expect(engine.retryAt == until, "The retry must wait out the whole circuit interval")
        #expect(probe.disconnectCount == 1)

        engine.stop()
    }

    // MARK: - Stop

    @Test
    func stopClearsThePurposeAndTheConnectionState() async throws {
        let streaming = FakeLiveStreaming()
        let probe = Probe()
        let engine = makeEngine(streaming: streaming, probe: probe)
        engine.setPurpose(.exteriorConfirmation, vin: vin)
        _ = await settle { streaming.openCount == 1 }
        streaming.send(.connected(activeTransportStreams: 1))
        #expect(await settle { engine.isConnected })

        engine.stop()

        #expect(!engine.isRunning)
        #expect(!engine.isConnected)
        #expect(engine.purpose == nil)
        #expect(engine.metrics.activeTransportStreams == 0)
        #expect(engine.metrics.connectedAt == nil)
    }
}

// MARK: - Scripted transport

/// Each open either throws the next scripted failure or returns a stream the test feeds one update
/// at a time, so the test decides exactly when each frame arrives. The lock is only taken in the
/// synchronous helpers below: `NSLock` is unavailable directly inside an async context.
private final class FakeLiveStreaming: VehicleLiveStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error]
    private var opens = 0
    private var refreshes = 0
    private var continuation: AsyncThrowingStream<VehicleLiveUpdate, Error>.Continuation?

    init(failures: [Error] = []) {
        self.failures = failures
    }

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return opens
    }

    var refreshCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshes
    }

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        if let failure = nextFailure() {
            throw failure
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            self.keep(continuation)
        }
    }

    func refreshLiveStreamAuthorization() async throws {
        countRefresh()
    }

    /// Delivers one update on the most recently opened stream.
    func send(_ update: VehicleLiveUpdate) {
        let target = currentContinuation()
        _ = target?.yield(update)
    }

    private func nextFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if failures.isEmpty { opens += 1; return nil }
        return failures.removeFirst()
    }

    private func keep(_ continuation: AsyncThrowingStream<VehicleLiveUpdate, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func currentContinuation() -> AsyncThrowingStream<VehicleLiveUpdate, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func countRefresh() {
        lock.lock()
        refreshes += 1
        lock.unlock()
    }
}
