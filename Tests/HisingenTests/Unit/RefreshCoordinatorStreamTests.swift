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
        commandWindow: TimeInterval = 5 * 60,
        commandInitialPollDelay: TimeInterval = 2,
        commandPollInterval: TimeInterval = 5
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
            commandConfirmationWindow: commandWindow,
            commandConfirmationInitialPollDelay: commandInitialPollDelay,
            commandConfirmationPollInterval: commandPollInterval
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

        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date(),
            command: .lock
        ))
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

    @Test
    func matchingExteriorFrameEndsConfirmationBeforeTheSafetyCap() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(
            script: [.healthy(frames: 1), .exteriorLocked, .healthy(frames: 1)],
            recorder: recorder
        )
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider, defaults: defaults, commandWindow: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date().addingTimeInterval(-1),
            command: .lock
        ))

        let resumed = await waitUntil(events, timeout: 2) { _ in
            recorder.purposes == [.charging, .exteriorConfirmation, .charging]
        }
        _ = try #require(resumed, "Expected fresh lock telemetry to end confirmation immediately")
        #expect(events.states.contains { $0.commandState.receipt?.status.isConfirmed == true })
        #expect(recorder.maxConcurrent == 1)
        coordinator.stop()
    }

    @Test
    func optimisticStateAndReceiptPublishAsOneCoordinatorState() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandInitialPollDelay: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        var optimisticState = try #require(coordinator.latest)
        optimisticState.energy.targetPercentage = 90
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(90).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(90)
        )

        coordinator.beginCommandConfirmation(receipt, optimisticState: optimisticState)
        let persistedReceipts = VehicleStateStore(defaults: defaults, database: .inMemory())

        let published = try #require(events.states.last)
        #expect(published.energy.targetPercentage == 90)
        #expect(published.commandState.receipt == receipt)
        #expect(coordinator.latest?.energy.targetPercentage == 90)
        #expect(coordinator.latest?.commandState.receipt == nil)

        let diagnostics = try #require(events.snapshots.last)
        #expect(diagnostics.commandConfirmationIdentifier == receipt.commandIdentifier)
        #expect(diagnostics.commandConfirmationStatus == .awaiting)
        #expect(diagnostics.commandConfirmationDeadline != nil)
        #expect(diagnostics.commandConfirmationFeatures == [.remoteCharging])
        #expect(diagnostics.commandReceiptVisible)
        #expect(persistedReceipts.commandReceipt(for: StreamingMockProvider.vinA)?.receipt == receipt)

        coordinator.dismissCommandReceipt(issuedAt: receipt.issuedAt)
        #expect(events.states.last?.commandState.receipt == nil)
        #expect(events.snapshots.last?.commandReceiptVisible == false)
        #expect(persistedReceipts.commandReceipt(for: StreamingMockProvider.vinA) == nil)

        coordinator.refreshNow()
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 2 })
        #expect(events.states.last?.commandState.receipt == nil)
        #expect(events.snapshots.last?.commandConfirmationStatus == .awaiting)
        coordinator.stop()
    }

    @Test
    func disconnectedConfirmationStreamUsesFastFallbackPollAndReconnects() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let transient = VehicleServiceError.temporarilyUnavailable(
            provider: .polestar, service: "exterior"
        )
        let provider = StreamingMockProvider(
            script: [.healthy(frames: 1), .fail(transient), .healthy(frames: 1)],
            recorder: recorder
        )
        let events = DiagnosticsRecorder()
        let policy = LiveStreamPolicy(retrySteps: [0.2])
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            policy: policy,
            commandWindow: 3,
            commandPollInterval: 0.1
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date(),
            command: .lock
        ))

        let retrying = await waitUntil(events, timeout: 2) {
            !$0.liveStreamConnected && $0.liveStreamRetryAt != nil
        }
        let snapshot = try #require(retrying, "Expected the failed confirmation stream to retry")
        let fallbackDelay = snapshot.nextRefresh?.timeIntervalSinceNow ?? .infinity
        #expect(fallbackDelay < 1.2, "Expected a targeted confirmation poll, got \(fallbackDelay) s")
        let reconnected = try #require(await waitUntil(events, timeout: 3) { diagnostics in
            recorder.purposes.filter { $0 == .exteriorConfirmation }.count >= 1
                && recorder.opened >= 2 && diagnostics.liveStreamConnected
        })
        let fetchCountAtReconnect = await provider.fetchCount
        if fetchCountAtReconnect == 1,
           let fallbackDeadline = snapshot.nextRefresh,
           let reconnectedDeadline = reconnected.nextRefresh {
            #expect(reconnectedDeadline <= fallbackDeadline.addingTimeInterval(0.05),
                    "Reconnect must not postpone an already scheduled confirmation poll")
        }
        let pollDeadline = Date().addingTimeInterval(2)
        while await provider.fetchCount < 2, Date() < pollDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await provider.fetchCount >= 2, "Expected a confirmation poll before the normal cadence")
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
        let coordinator = makeCoordinator(
            provider: provider, defaults: defaults, commandInitialPollDelay: 0.1
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        // Wait for the baseline charging stream before issuing the climate command, so the
        // comparison is against a settled state.
        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        let before = recorder.purposes.count
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: Date(),
            command: .stopClimate
        ))
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.purposes.count == before, "Climate commands must not open any stream")
        #expect(recorder.purposes == [.charging])
        let pollDeadline = Date().addingTimeInterval(2)
        while await provider.fetchCount < 2, Date() < pollDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await provider.fetchCount == 2, "Climate commands retain one authoritative follow-up poll")
        coordinator.stop()
    }

    @Test(arguments: [
        RemoteCommand.setChargeTarget(80),
        RemoteCommand.setAmpLimit(16)
    ])
    func pollOnlyChargingSettingConfirmationRepeatsWithoutOpeningAStream(
        command: RemoteCommand
    ) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandWindow: 3,
            commandInitialPollDelay: 0.05,
            commandPollInterval: 0.05
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: command.identifier,
            issuedAt: Date(),
            command: command
        ))

        let firstPoll = try #require(await waitUntil(events, timeout: 2) {
            $0.refreshSuccesses >= 2
        })
        let nextDelay = firstPoll.nextRefresh?.timeIntervalSinceNow ?? .infinity
        #expect(nextDelay < 1.2, "Poll-only confirmation must retain its short repeat cadence")
        #expect(recorder.purposes.isEmpty, "Charging-setting confirmation must not open the battery stream")
        _ = try #require(await waitUntil(events, timeout: 2) {
            $0.refreshSuccesses >= 3
        }, "Expected poll-only confirmation to fetch repeatedly")
        coordinator.stop()
    }

    @Test
    func chargingOverrideConfirmationStillUsesTheBatteryStream() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.startChargingOverride.identifier,
            issuedAt: Date(),
            command: .startChargingOverride
        ))

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        #expect(!recorder.purposes.isEmpty)
        #expect(recorder.purposes.allSatisfy { $0 == .charging })
        coordinator.stop()
    }

    @Test
    func confirmationUsesTheFastProductionInitialPollDelay() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(80).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(80)
        ))

        let scheduled = try #require(await waitUntil(events) {
            guard let delay = $0.nextRefresh?.timeIntervalSinceNow else { return false }
            return delay > 1.5 && delay < 3.1
        })
        #expect(scheduled.nextRefresh != nil)
        coordinator.stop()
    }

    @Test
    func confirmationPollFetchesOnlyCommandTelemetry() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandInitialPollDelay: 0.05,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(80).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(80)
        ))

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 2 })
        let selections = await provider.fetchSelections
        #expect(selections.first == FeatureSelection.default)
        #expect(selections.last?.enabled == [.remoteCharging])
        coordinator.stop()
    }

    @Test
    func manualRefreshDuringConfirmationStillFetchesFullSelection() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandInitialPollDelay: 5,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(80).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(80)
        ))
        coordinator.refreshNow()

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 2 })
        let selections = await provider.fetchSelections
        #expect(selections.last == FeatureSelection.default)
        coordinator.stop()
    }

    @Test
    func commandConfirmationDoesNotBypassRateLimit() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let rateLimitFloor = Date().addingTimeInterval(29.8)
        await provider.failNextFetch(.rateLimited(retryAfter: 30))
        coordinator.refreshNow()
        _ = try #require(await waitUntil(events) {
            $0.refreshFailures == 1 && $0.nextRefresh != nil
        })

        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date(),
            command: .lock
        ))

        let confirmationDeadline = try #require(events.snapshots.last?.nextRefresh)
        #expect(
            confirmationDeadline >= rateLimitFloor,
            "Confirmation polling must respect the provider's retry deadline"
        )
        coordinator.stop()
    }

    @Test
    func networkLossPreservesConfirmationAndItsRemainingWindow() async throws {
        try await verifyTemporarySuspensionPreservesConfirmation { coordinator in
            coordinator.networkDidChange(false)
        } resume: { coordinator in
            coordinator.networkDidChange(true)
        }
    }

    @Test
    func systemSleepPreservesConfirmationAndItsRemainingWindow() async throws {
        try await verifyTemporarySuspensionPreservesConfirmation { coordinator in
            coordinator.systemWillSleep()
        } resume: { coordinator in
            coordinator.systemDidWake()
        }
    }

    @Test(arguments: [RemoteCommand.lock, .stopClimate])
    func confirmationWatchdogPublishesTheTimedOutTerminalStatus(
        command: RemoteCommand
    ) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(
            script: [.healthy(frames: 1), .healthy(frames: 1)],
            recorder: recorder
        )
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandWindow: 0.1,
            commandInitialPollDelay: 5,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: command.identifier,
            issuedAt: Date(),
            command: command
        ))

        _ = try #require(await waitUntil(events) { _ in
            events.states.contains {
                guard $0.commandState.receipt?.command == command,
                      case .timedOut = $0.commandState.receipt?.status else { return false }
                return true
            }
        }, "Expected the watchdog to publish the timed-out receipt")
        coordinator.stop()
    }

    @Test
    func terminalReceiptSurvivesLaterRefreshes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandWindow: 0.1,
            commandInitialPollDelay: 5,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: Date(),
            command: .stopClimate
        )
        coordinator.beginCommandConfirmation(receipt)
        _ = try #require(await waitUntil(events) { _ in
            events.states.contains {
                guard $0.commandState.receipt?.commandIdentifier == receipt.commandIdentifier,
                      case .timedOut = $0.commandState.receipt?.status else { return false }
                return true
            }
        })

        coordinator.refreshNow()

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 2 })
        let refreshed = try #require(events.states.last)
        #expect(refreshed.commandState.receipt?.commandIdentifier == receipt.commandIdentifier)
        let retainedTimedOut: Bool
        if case .timedOut = refreshed.commandState.receipt?.status {
            retainedTimedOut = true
        } else {
            retainedTimedOut = false
        }
        #expect(retainedTimedOut, "Expected the coordinator to retain the timed-out receipt")
        coordinator.stop()
    }

    @Test
    func relaunchRestoresAwaitingReceiptWithoutReissuingCommand() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstEvents = DiagnosticsRecorder()
        let firstProvider = StreamingMockProvider(script: [], recorder: StreamRecorder())
        let first = makeCoordinator(provider: firstProvider, defaults: defaults)
        first.onEvent = { firstEvents.record($0) }
        first.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(firstEvents) { $0.refreshSuccesses == 1 })

        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(90).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(90)
        )
        first.beginCommandConfirmation(receipt)
        let originalDeadline = try #require(firstEvents.snapshots.last?.commandConfirmationDeadline)
        first.stop()

        let secondEvents = DiagnosticsRecorder()
        let secondProvider = StreamingMockProvider(script: [], recorder: StreamRecorder())
        let second = makeCoordinator(provider: secondProvider, defaults: defaults)
        second.onEvent = { secondEvents.record($0) }
        second.start(preferredVIN: nil)
        _ = try #require(await waitUntil(secondEvents) {
            $0.refreshSuccesses == 1
                && $0.commandConfirmationIdentifier == receipt.commandIdentifier
        })

        #expect(secondEvents.states.last?.commandState.receipt?.status == .awaiting)
        #expect(secondEvents.snapshots.last?.commandConfirmationDeadline == originalDeadline)
        #expect(await secondProvider.fetchCount >= 1)
        #expect(await secondProvider.remoteCommandCount == 0)
        second.stop()
    }

    @Test
    func relaunchTurnsAnExpiredAwaitingReceiptIntoATimeout() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deadline = Date().addingTimeInterval(-1)
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: deadline.addingTimeInterval(-30),
            command: .lock
        )
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        store.saveCommandReceipt(
            StoredCommandReceipt(receipt: receipt, confirmationDeadline: deadline),
            for: StreamingMockProvider.vinA
        )

        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) {
            $0.refreshSuccesses == 1
                && $0.commandConfirmationIdentifier == receipt.commandIdentifier
        })

        #expect(events.snapshots.last?.commandConfirmationDeadline == nil)
        #expect(events.states.last?.commandState.receipt?.status == .timedOut(at: deadline))
        #expect(store.commandReceipt(for: StreamingMockProvider.vinA)?.receipt.status == .timedOut(at: deadline))
        coordinator.stop()
    }

    @Test
    func dismissedAwaitingReceiptDoesNotReappearInStorageWhenItTimesOut() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            commandWindow: 0.1,
            commandInitialPollDelay: 5,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: Date(),
            command: .stopClimate
        )
        coordinator.beginCommandConfirmation(receipt)
        coordinator.dismissCommandReceipt(issuedAt: receipt.issuedAt)
        _ = try #require(await waitUntil(events) { $0.commandConfirmationStatus?.isTerminal == true })

        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        #expect(store.commandReceipt(for: StreamingMockProvider.vinA) == nil)
        #expect(events.snapshots.last?.commandReceiptVisible == false)
        coordinator.stop()
    }

    private func verifyTemporarySuspensionPreservesConfirmation(
        suspend: (RefreshCoordinator) -> Void,
        resume: (RefreshCoordinator) -> Void
    ) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(
            script: [
                .healthy(frames: 1),
                .healthy(frames: 1),
                .healthy(frames: 1)
            ],
            recorder: recorder
        )
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandWindow: 0.1,
            commandInitialPollDelay: 5,
            commandPollInterval: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date(),
            command: .lock
        ))
        _ = try #require(await waitUntil(events) { _ in
            recorder.purposes.filter { $0 == .exteriorConfirmation }.count == 1
        })

        suspend(coordinator)
        try await Task.sleep(for: .milliseconds(200))
        resume(coordinator)

        _ = try #require(await waitUntil(events) { diagnostics in
            diagnostics.liveStreamConnected
                && recorder.purposes.filter { $0 == .exteriorConfirmation }.count == 2
        }, "Expected confirmation streaming to resume after temporary suspension")
        #expect(recorder.purposes.last == .exteriorConfirmation)
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
    case exteriorLocked
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
    private(set) var states: [VehicleState] = []

    func record(_ event: RefreshCoordinatorEvent) {
        if case .diagnostics(let snapshot) = event { snapshots.append(snapshot) }
        if case .state(let state) = event { states.append(state) }
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
    private(set) var fetchSelections: [FeatureSelection] = []
    private(set) var authorizationRefreshCount = 0
    private(set) var remoteCommandCount = 0
    private var charging = true
    private var nextFetchFailure: VehicleServiceError?
    private var script: [StreamBehavior]
    private let recorder: StreamRecorder

    init(script: [StreamBehavior], recorder: StreamRecorder) {
        self.script = script
        self.recorder = recorder
    }

    func setCharging(_ enabled: Bool) { charging = enabled }
    func failNextFetch(_ error: VehicleServiceError) { nextFetchFailure = error }

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
        fetchSelections.append(features)
        if let nextFetchFailure {
            self.nextFetchFailure = nil
            throw nextFetchFailure
        }
        return Self.makeMockState(vin: vin, charging: charging)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        remoteCommandCount += 1
        return RemoteCommandResult(outcome: .completed, message: nil)
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
        case .exteriorLocked:
            recorder.open(purpose: purpose, vin: vin)
            let recorder = self.recorder
            return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
                continuation.yield(.connected(activeTransportStreams: 1))
                continuation.yield(.exterior(
                    ExteriorSnapshot(
                        openings: [], isLocked: true, alarmTriggered: false,
                        reportedAt: Date()
                    ),
                    reportedAt: Date()
                ))
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
