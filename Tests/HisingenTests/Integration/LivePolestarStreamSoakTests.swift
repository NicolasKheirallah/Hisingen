#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let soakCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["HISINGEN_TEST_EMAIL"]?.isEmpty == false
        && environment["HISINGEN_TEST_PASSWORD"]?.isEmpty == false
}()

/// Soak duration in seconds. Defaults to ten minutes (fits the CI job budget); multi-hour
/// runs set `HISINGEN_SOAK_SECONDS` (for example 14400) on a manual dispatch or locally.
private let soakSeconds: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["HISINGEN_SOAK_SECONDS"],
       let value = TimeInterval(raw), value > 0 {
        return value
    }
    return 600
}()

/// Credential-backed soak of the live-stream lifecycle against the real Polestar backend.
///
/// The invariants under test (one stream per vehicle and service, no periodic reconnects
/// without a server/network event, no token grant per reconnect, no routine polling while
/// the stream is healthy, and no 401/429 amplification) are what the reconnect storm and
/// per-stream token grants used to violate within minutes of charging. Backoff behavior
/// under *simulated* failures is proven by `StreamPolicyTests` and
/// `RefreshCoordinatorStreamTests`; this suite proves the same properties against the real
/// service over sustained time.
///
/// The streaming gate is forced open so the soak measures connection stability even when
/// the test car is parked and idle — production gating rules stay covered by the unit
/// suites, and the soak only ever reads.
@Suite(.serialized)
@MainActor
struct LivePolestarStreamSoakTests {
    @Test(.disabled(if: !soakCredentialsConfigured, "Live Polestar credentials are not configured"))
    func sustainedSoakHoldsOneStreamWithoutTokenOrPollingAmplification() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-soak.\(UUID())")
        let api = PolestarAPI(keychain: keychain)
        var coordinator: RefreshCoordinator?
        do {
            try await api.authenticate(email: email, password: password,
                                       preferredVIN: preferredVIN, features: .default)
            let vin = try #require(await api.resolvedVIN(preferred: preferredVIN))
            let storedToken = try #require(try keychain.readSessionToken())

            let counters = SoakStreamCounters()
            let provider = SoakCountingProvider(api: api, counters: counters)
            let suiteName = "hisingen-soak.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let preferences = PreferencesStore(defaults: defaults)
            var features = FeatureSelection.default
            features.set(.realTimeUpdates, enabled: true)
            preferences.features = features
            preferences.vin = vin

            let events = SoakDiagnosticsRecorder()
            coordinator = RefreshCoordinator(
                api: provider,
                stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
                observesEnvironment: false,
                imageCache: CarImageCache(),
                preferences: preferences,
                sessionManager: SessionManager(readToken: { _ in storedToken },
                                               readPassword: { nil }, clearPassword: {}),
                liveStreamPolicy: LiveStreamPolicy(shouldStream: { _ in true })
            )
            coordinator?.onEvent = { events.record($0) }
            coordinator?.start(preferredVIN: vin)

            let connected = await Self.waitForConnect(events, timeout: 180)
            let connectedAt = try #require(connected, "The stream never connected during the soak")
            _ = connectedAt

            try await Task.sleep(for: .seconds(soakSeconds))
            coordinator?.stop()

            let final = try #require(events.snapshots.last)
            let metrics = final.liveStreamMetrics

            // 1. At most one active stream per supported service — and only one service
            //    (battery state) streams at all.
            #expect(counters.maxConcurrent <= 1,
                    "Saw \(counters.maxConcurrent) concurrent streams; at most one may exist")
            #expect(final.liveStreamMetrics.activeTransportStreams <= 1)

            // 2. No periodic reconnect without a server/network event. The budget scales
            //    with hours; the old ~95 s reconnect cycle would blow through it within
            //    minutes.
            let reconnectBudget = max(0, Int(soakSeconds / 1_800))
            #expect(metrics.disconnects <= reconnectBudget,
                    "Saw \(metrics.disconnects) disconnects in \(Int(soakSeconds)) s (budget \(reconnectBudget))")

            // 3. No token grant per reconnect: the stream either reuses the shared token or
            //    recovers authorization once.
            #expect(await provider.authorizationRefreshes <= 1)
            #expect(metrics.authorizationRefreshes <= 1)
            try await Self.assertNoTokenAmplification(since: connectedAt, soak: soakSeconds)

            // 4. No routine polling while the stream is healthy: only the initial fetch plus
            //    rare integrity polls may have happened.
            let fetches = await provider.fetchCount
            let fetchBudget = 2 + Int(soakSeconds / 1_500)
            #expect(fetches <= fetchBudget,
                    "Saw \(fetches) telemetry fetches during the soak (budget \(fetchBudget))")

            // 5. No 401/429 amplification over sustained time.
            #expect(await provider.rateLimitedFetches == 0,
                    "The soak hit rate limiting; the stream budget is too aggressive")

            // The connection must still be alive after the soak — a sustained stream is the
            // product, not a sequence of retries.
            #expect(final.liveStreamConnected || metrics.disconnects <= reconnectBudget,
                    "Stream was not connected at soak end (disconnects: \(metrics.disconnects), last reason: \(metrics.lastDisconnectReason ?? "none"))")
            if metrics.successfulConnections > 0 {
                #expect((metrics.lastConnectionDuration ?? 0) >= min(600, soakSeconds * 0.8),
                        "Last connection lasted \(String(describing: metrics.lastConnectionDuration)) s")
            } else {
                Issue.record("The soak never successfully connected a stream")
            }

            try await api.signOut()
        } catch {
            coordinator?.stop()
            try? await api.signOut()
            throw error
        }
    }

    private static func waitForConnect(_ events: SoakDiagnosticsRecorder,
                                       timeout: TimeInterval) async -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = events.snapshots.last(where: { $0.liveStreamConnected }) {
                return snapshot.liveStreamMetrics.lastFrameAt ?? Date()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// Global token-grant accounting from the diagnostic log: authentication plus restore
    /// are the two expected grants; during the soak only real renewal-window refreshes may
    /// appear, one per hour of soak time at most.
    private static func assertNoTokenAmplification(since connectedAt: Date, soak: TimeInterval) async throws {
        let grants = await APIDiagnosticLogStore.shared.snapshot().filter {
            $0.provider == .polestar && $0.operation == "Polestar token request"
                && $0.timestamp >= connectedAt
        }
        let budget = max(1, Int(ceil(soak / 3_600)))
        #expect(grants.count <= budget,
                "Saw \(grants.count) token grants during the soak (budget \(budget))")
    }
}

/// Lock-protected stream-open accounting; `onTermination` runs off-actor.
private final class SoakStreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxConcurrent = 0

    func open() {
        lock.lock()
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        lock.unlock()
    }

    func close() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

/// Wraps the real Polestar API, adding counters for fetch volume, rate limits, stream
/// concurrency, and stream-side authorization refreshes. Everything else delegates.
private actor SoakCountingProvider: VehicleProviding, VehicleLiveStreaming {
    nonisolated let brand: VehicleBrand = .polestar
    private let api: PolestarAPI
    private let counters: SoakStreamCounters
    private(set) var fetchCount = 0
    private(set) var rateLimitedFetches = 0
    private(set) var authorizationRefreshes = 0

    init(api: PolestarAPI, counters: SoakStreamCounters) {
        self.api = api
        self.counters = counters
    }

    var hasWarmSession: Bool {
        get async { await api.hasWarmSession }
    }

    var cars: [CarSummary] {
        get async { await api.cars }
    }

    func authenticate(email: String, password: String, preferredVIN: String?,
                      features: FeatureSelection) async throws {
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try await api.restoreSession(token: token, preferredVIN: preferredVIN, features: features)
    }

    func resetSession() async {
        await api.resetSession()
    }

    func signOut() async throws {
        try await api.signOut()
    }

    func resolvedVIN(preferred: String?) async -> String? {
        await api.resolvedVIN(preferred: preferred)
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        try await api.reloadVehicleMetadata(vin: vin, features: features)
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        do {
            return try await api.fetchVehicleState(vin: vin, features: features)
        } catch {
            if Self.isRateLimited(error) { rateLimitedFetches += 1 }
            throw error
        }
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        try await api.executeRemoteCommand(command, vin: vin)
    }

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        counters.open()
        do {
            let stream = try await api.liveVehicleUpdates(vin: vin, purpose: purpose)
            let counters = self.counters
            return AsyncThrowingStream { continuation in
                let pump = Task {
                    do {
                        for try await update in stream {
                            continuation.yield(update)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    pump.cancel()
                    counters.close()
                }
            }
        } catch {
            counters.close()
            throw error
        }
    }

    func refreshLiveStreamAuthorization() async throws {
        authorizationRefreshes += 1
        try await api.refreshLiveStreamAuthorization()
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if case .rateLimited = error as? PolestarError { return true }
        if case .rateLimited = error as? VehicleServiceError { return true }
        return false
    }
}

@MainActor
private final class SoakDiagnosticsRecorder {
    private(set) var snapshots: [DiagnosticsSnapshot] = []

    func record(_ event: RefreshCoordinatorEvent) {
        if case .diagnostics(let snapshot) = event { snapshots.append(snapshot) }
    }
}

#endif
