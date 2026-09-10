import Foundation
import Testing
@testable import Hisingen

/// Behavioral coverage for the coordinator's live-stream lifecycle: one stream per vehicle
/// and purpose, reconnects that carry no token grants, the authorization-recovery-then-circuit
/// rule, the command-confirmation window, and healthy-stream polling suppression.
///
/// Serialized because every test drives real timers and stream tasks; interleaving them
/// would only measure scheduler noise.
@Suite(.serialized)
@MainActor
struct RefreshCoordinatorStreamTests {
    // MARK: - Harness

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func makeCoordinator(
        provider: StreamingMockProvider, defaults: UserDefaults,
        policy: LiveStreamPolicy = LiveStreamPolicy(retrySteps: [0.1, 0.2]),
        commandWindow: TimeInterval = 2 * 60
    ) -> RefreshCoordinator {
        let preferences = PreferencesStore(defaults: defaults)
        var features = FeatureSelection.default
        features.set(.realTimeUpdates, enabled: true)
        preferences.features = features
        preferences.vin = StreamingMockProvider.vinA
        return RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readToken: { _ in "test-session" },
                                           readPassword: { nil }, clearPassword: {}),
            liveStreamPolicy: policy,
            commandConfirmationWindow: commandWindow
        )
    }

    /// Polls until the recorded diagnostics satisfy `condition`, with a timeout that fails
    /// the test rather than hanging it.
    private func waitUntil(
        _ recorder: DiagnosticsRecorder, timeout: TimeInterval = 5,
        _ condition: (DiagnosticsSnapshot) -> Bool
    ) async -> DiagnosticsSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = recorder.snapshots.last(where: condition) {
                return snapshot
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: - Healthy stream

    /// A healthy stream must suppress the routine two-minute telemetry poll: with no
    /// integrity tick due, nothing else may fetch.
    @Test
    func healthyChargingStreamSuppressesRoutinePolling() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 2)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        let connected = await waitUntil(events) { $0.liveStreamConnected }
        let snapshot = try #require(connected, "Expected the charging stream to connect")
        // Integrity poll interval is 30 minutes; a routine charging poll would be 120 s.
        let lead = snapshot.nextRefresh.map { $0.timeIntervalSinceNow } ?? 0
        #expect(lead > 1_500, "Expected the integrity poll (~30 min) to be the only scheduled refresh, got \(lead) s")
        #expect(snapshot.liveStreamMetrics.activeTransportStreams == 1)
        #expect(recorder.purposes == [.charging])
        #expect(recorder.maxConcurrent == 1)

        // Far shorter than the routine charging cadence: a routine poll would have fired.
        try await Task.sleep(for: .seconds(1.5))
        let fetches = await provider.fetchCount
        #expect(fetches == 1, "Healthy stream must suppress routine polling, saw \(fetches) fetches")
        coordinator.stop()
    }

    /// The slow integrity poll still runs while the stream is healthy — that is the drift
    /// check the design keeps, and it is the only thing that fetches.
    @Test
    func integrityPollStillFetchesWhileStreamIsHealthy() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let policy = LiveStreamPolicy(integrityPollInterval: 0.3, retrySteps: [0.1])
        let coordinator = makeCoordinator(provider: provider, defaults: defaults,
                                          policy: policy)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        // Several integrity ticks elapse (tick period 0.3–1.3 s with jitter); each may
        // fetch exactly once, and no stream churn may accompany them.
        try await Task.sleep(for: .seconds(3))
        let fetches = await provider.fetchCount
        #expect(fetches >= 2, "Integrity ticks should fetch while healthy, saw \(fetches)")
        #expect(recorder.purposes == [.charging], "Integrity polling must not restart the stream")
        #expect(recorder.maxConcurrent == 1)
        coordinator.stop()
    }

    // MARK: - Reconnect behavior

    /// Transient disconnects reconnect with the collapsed backoff ladder and never touch the
    /// token endpoints — and never run two streams at once.
    @Test
    func transientReconnectsCarryNoTokenGrantsAndNeverOverlap() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let transient = VehicleServiceError.temporarilyUnavailable(provider: .polestar, service: "battery")
        let provider = StreamingMockProvider(
            script: [.fail(transient), .fail(transient), .healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        let connected = await waitUntil(events) { $0.liveStreamConnected }
        let snapshot = try #require(connected, "Expected the stream to recover after two transient failures")
        #expect(await provider.authorizationRefreshCount == 0,
                "A transient reconnect must not acquire a token grant")
        #expect(snapshot.liveStreamMetrics.connectionAttempts >= 3,
                "Expected two refused attempts plus the healthy connection")
        #expect(recorder.opened == 1, "Only the successful connection counts as an opened stream")
        #expect(recorder.maxConcurrent == 1, "Streams must never overlap")
        // While disconnected, the fallback poll is the charging cadence (120 s), not the
        // integrity cadence.
        let fallback = events.snapshots.last(where: {
            !$0.liveStreamConnected && $0.liveStreamRetryAt != nil
        })?.nextRefresh?.timeIntervalSinceNow
        #expect(fallback == nil || (fallback! > 90 && fallback! < 150),
                "Expected the slow fallback poll (~120 s) while reconnecting, got \(String(describing: fallback)) s")
        coordinator.stop()
    }

    /// An authentication failure on the stream uses the shared single-flight refresh exactly
    /// once; a repeat failure opens the circuit instead of looping 401s forever.
    @Test
    func streamAuthFailureRefreshesOnceThenOpensCircuit() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let auth = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        let provider = StreamingMockProvider(
            script: [.fail(auth), .fail(auth), .healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let policy = LiveStreamPolicy(repeatedFailureCircuitInterval: 0.2, retrySteps: [0.05])
        let coordinator = makeCoordinator(provider: provider, defaults: defaults,
                                          policy: policy)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        let connected = await waitUntil(events, timeout: 8) { $0.liveStreamConnected }
        _ = try #require(connected, "Expected recovery: one token refresh, one circuit pause, then a healthy stream")
        #expect(await provider.authorizationRefreshCount == 1,
                "Exactly one authorization recovery is allowed before the circuit opens")
        #expect(recorder.maxConcurrent == 1)
        coordinator.stop()
    }

    // MARK: - Purpose gating

    /// When charging ends, the battery stream closes — it has nothing fresh to say about an
    /// idle car — and the regular poll cadence returns.
    @Test
    func endingChargingStopsTheStreamAndRestoresPolling() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected }, "Expected the charging stream to connect")

        await provider.setCharging(false)
        coordinator.refreshNow()
        let stopped = await waitUntil(events, timeout: 8) { snapshot in
            !snapshot.liveStreamConnected && snapshot.liveStreamMetrics.activeTransportStreams == 0
        }
        _ = try #require(stopped, "Expected the stream to stop once charging ended")
        try await Task.sleep(for: .milliseconds(200))
        if let next = events.snapshots.last?.nextRefresh?.timeIntervalSinceNow {
            #expect(next > 550, "Expected the idle-vehicle poll cadence (~10 min) after the stream stopped, got \(next) s")
        }
        #expect(await provider.fetchCount == 2, "Expected exactly one confirmation fetch after charging ended")
        coordinator.stop()
    }

    /// A lock command opens a short exterior-confirmation stream in place of the battery
    /// stream; when the window lapses the watchdog closes it and the charging gate decides
    /// again — an expired confirmation stream must never linger as "the live stream".
    @Test
    func commandConfirmationWindowOpensAndClosesTheExteriorStream() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults,
                                          commandWindow: 0.2)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected }, "Expected the charging stream to connect")

        coordinator.beginCommandConfirmation(.lock)
        _ = try #require(
            await waitUntil(events) { _ in recorder.purposes.last == .exteriorConfirmation },
            "Expected the exterior confirmation stream to replace the battery stream"
        )

        // The window lapses while the car is still charging: the battery stream returns.
        let resumed = await waitUntil(events, timeout: 8) { _ in
            recorder.purposes.suffix(1) == [.charging] && events.snapshots.last?.liveStreamConnected == true
        }
        _ = try #require(resumed, "Expected the battery stream to resume after the confirmation window closed")
        #expect(recorder.purposes == [.charging, .exteriorConfirmation, .charging])
        #expect(recorder.maxConcurrent == 1)
        coordinator.stop()
    }

    /// Climate commands open no stream at all: the provider's only stream is battery state,
    /// and a battery connection cannot make climate fresher.
    @Test
    func climateCommandOpensNoStream() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        // Wait for the baseline charging stream before issuing the climate command, so the
        // comparison is against a settled state.
        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        let before = recorder.purposes.count
        coordinator.beginCommandConfirmation(.stopClimate)
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.purposes.count == before, "Climate commands must not open any stream")
        #expect(recorder.purposes == [.charging])
        coordinator.stop()
    }

    /// Switching vehicles cancels the old stream and opens at most one stream for the new
    /// VIN — the expired task's cleanup must not resurrect state for a car we left.
    @Test
    func vehicleSwitchCancelsTheOldStreamBeforeStartingTheNew() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected }, "Expected the stream for car A")

        coordinator.selectCar(vin: StreamingMockProvider.vinB)
        let switched = await waitUntil(events, timeout: 8) { snapshot in
            snapshot.liveStreamConnected && recorder.vins.last == StreamingMockProvider.vinB
        }
        _ = try #require(switched, "Expected a stream for car B after the switch")
        #expect(recorder.vins == [StreamingMockProvider.vinA, StreamingMockProvider.vinB])
        #expect(recorder.maxConcurrent == 1, "The old stream must be closed before the new one opens")
        coordinator.stop()
    }
}

// MARK: - Recorders

private enum StreamBehavior: Sendable {
    case fail(Error)
    case healthy(frames: Int)
}

/// Lock-protected record of stream opens. `onTermination` runs on an arbitrary executor, so
/// actor isolation cannot protect this state — and test closures read it synchronously.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var opened = 0
    var active = 0
    var maxConcurrent = 0
    var purposes: [VehicleLiveStreamPurpose] = []
    var vins: [String] = []

    func open(purpose: VehicleLiveStreamPurpose, vin: String) {
        lock.lock()
        opened += 1
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        purposes.append(purpose)
        vins.append(vin)
        lock.unlock()
    }

    func close() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

/// Per-test diagnostics capture; instances never share state across tests.
@MainActor
private final class DiagnosticsRecorder {
    private(set) var snapshots: [DiagnosticsSnapshot] = []

    func record(_ event: RefreshCoordinatorEvent) {
        if case .diagnostics(let snapshot) = event { snapshots.append(snapshot) }
    }
}

// MARK: - Scripted streaming provider

/// Vehicle provider whose telemetry is charging/idle and whose live stream follows a
/// scripted behavior list, so tests can simulate disconnects, auth failures, and recovery
/// deterministically.
private actor StreamingMockProvider: VehicleProviding, VehicleLiveStreaming {
    nonisolated static let vinA = "YS2P2AAAA00000001"
    nonisolated static let vinB = "YS2P2BBBB00000002"

    nonisolated let brand: VehicleBrand = .polestar
    private(set) var fetchCount = 0
    private(set) var authorizationRefreshCount = 0
    private var charging = true
    private var script: [StreamBehavior]
    private let recorder: StreamRecorder

    init(script: [StreamBehavior], recorder: StreamRecorder) {
        self.script = script
        self.recorder = recorder
    }

    func setCharging(_ enabled: Bool) { charging = enabled }

    // VehicleProviding

    var hasWarmSession: Bool { true }
    var cars: [CarSummary] {
        [CarSummary(vin: Self.vinA, title: "Car A"), CarSummary(vin: Self.vinB, title: "Car B")]
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? Self.vinA }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        return Self.makeMockState(vin: vin, charging: charging)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }

    // VehicleLiveStreaming

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        let behavior = script.isEmpty ? StreamBehavior.healthy(frames: 1) : script.removeFirst()
        switch behavior {
        case .fail(let error):
            // A refused connection never opened; only healthy returns count as streams.
            throw error
        case .healthy(let frames):
            recorder.open(purpose: purpose, vin: vin)
            let recorder = self.recorder
            return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
                continuation.yield(.connected(activeTransportStreams: 1))
                for index in 0..<frames {
                    continuation.yield(.battery(Self.frame(percent: Double(55 + index))))
                }
                // No finish: the connection holds open until cancelled, like the real
                // server-streaming gRPC endpoint.
                continuation.onTermination = { _ in recorder.close() }
            }
        }
    }

    func refreshLiveStreamAuthorization() async throws {
        authorizationRefreshCount += 1
    }

    private static func makeMockState(vin: String, charging: Bool) -> VehicleState {
        VehicleState(
            batteryPercentage: 55, rangeKm: 280,
            chargingState: charging ? .charging : .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: charging ? .ac : .none,
            chargerConnection: charging ? .connected : .disconnected,
            availability: .available,
            modelName: "Polestar 2", modelYear: nil, registrationNo: nil,
            vin: vin, ownerFirstName: nil, odometerKm: nil,
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: nil, dataWarnings: []
        )
    }

    private static func frame(percent: Double) -> GrpcBatteryExtras {
        GrpcBatteryExtras(
            reportedAt: Date(), batteryPercentage: percent, rangeKm: 278,
            estimatedChargingTimeToFullMinutes: 40, chargingState: .charging,
            chargerConnection: .connected, chargingType: .ac, chargingPowerWatts: 6_900,
            chargingCurrentAmps: 30, chargingVoltageVolts: 230,
            diagnostics: BatteryDiagnostics(
                timeToTargetMinutes: nil, timeToMinimumSOCMinutes: nil,
                chargerPowerState: .available, averageConsumption: nil,
                averageConsumptionSinceCharge: nil, energyUsedSinceChargeWh: nil
            ),
            reportedBatteryCapacityKwh: nil, unknownFields: []
        )
    }
}
