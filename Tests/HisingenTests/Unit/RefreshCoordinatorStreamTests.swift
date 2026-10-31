import Foundation
import Testing
@testable import Hisingen

/// Behavioral coverage for the coordinator's live-stream lifecycle: one stream per vehicle
/// and purpose, reconnects that carry no token grants, the authorization-recovery-then-circuit
/// rule, the command-confirmation window, and healthy-stream polling suppression.
///
/// Stream-engine retry tests still share a real-time scheduler; cadence waits use a virtual clock.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RefreshCoordinatorStreamTests {
    // MARK: - Harness

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func makeCoordinator(
        provider: StreamingMockProvider, defaults: UserDefaults,
        database: VehicleDatabase? = nil,
        policy: LiveStreamPolicy = LiveStreamPolicy(retrySteps: [0.1, 0.2]),
        commandWindow: TimeInterval = 5 * 60,
        commandInitialPollDelay: TimeInterval = 2,
        commandPollInterval: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        scheduler: AsyncTimerLoop? = nil
    ) -> RefreshCoordinator {
        let preferences = PreferencesStore(defaults: defaults,
                                           keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        var features = FeatureSelection.default
        features.set(.realTimeUpdates, enabled: true)
        preferences.features = features
        preferences.vin = StreamingMockProvider.vinA
        return RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: database ?? .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            liveStreamPolicy: policy,
            scheduler: scheduler ?? AsyncTimerLoop(),
            streaming: provider,
            now: now,
            commandConfirmationWindow: commandWindow,
            commandConfirmationInitialPollDelay: commandInitialPollDelay,
            commandConfirmationPollInterval: commandPollInterval
        )
    }

    /// A scheduler whose every cadence wait parks on `clock` until the test releases it.
    private func makeManualScheduler(_ clock: ManualTickClock) -> AsyncTimerLoop {
        AsyncTimerLoop(wait: { duration in try await clock.park(duration) })
    }

    private func waitUntil(
        _ recorder: DiagnosticsRecorder, timeout: TimeInterval = 20,
        _ condition: @escaping @MainActor (DiagnosticsSnapshot) -> Bool
    ) async -> DiagnosticsSnapshot? {
        await recorder.wait(timeout: timeout, condition: condition)
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
        let clock = ManualTickClock()
        let coordinator = makeCoordinator(
            provider: provider, defaults: defaults, scheduler: makeManualScheduler(clock)
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        // Wait for the snapshot that both reports the connection and carries the schedule the
        // connection installed. A refresh publishes one while its fetch is still in flight, with
        // `nextRefresh` already cleared, so waiting on the flag alone can land on that interim
        // snapshot and read no schedule at all.
        let connected = await waitUntil(events) { $0.liveStreamConnected && $0.nextRefresh != nil }
        let snapshot = try #require(connected, "Expected the charging stream to connect")
        // Integrity poll interval is 30 minutes; a routine charging poll would be 120 s.
        let lead = snapshot.nextRefresh.map { $0.timeIntervalSinceNow } ?? 0
        #expect(lead > 1_500, "Expected the integrity poll (~30 min) to be the only scheduled refresh, got \(lead) s")
        #expect(snapshot.liveStreamMetrics.activeTransportStreams == 1)
        #expect(recorder.purposes == [.charging])
        #expect(recorder.maxConcurrent == 1)

        // The newest tick the coordinator armed is the integrity tick, not the 120 s routine poll.
        // Every tick parks on the manual clock and only the test releases one, so the armed tick
        // is the one that decides what runs next, and no routine poll can fire unseen.
        try await clock.waitForPark(after: 0, minimumDuration: 1_500)
        #expect((clock.waits.last ?? 0) > 1_500)
        #expect(clock.pendingDuration == clock.waits.last)
        let fetches = await provider.fetchCount
        #expect(fetches == 1, "Healthy stream must suppress routine polling, saw \(fetches) fetches")
        coordinator.stop()
        clock.releaseAll()
    }

    @Test
    func identicalLiveFramesPublishStateOnlyOnce() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = StreamingMockProvider(
            script: [.repeatedBattery(frames: 2)], recorder: StreamRecorder()
        )
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { _ in events.states.last?.energy.batteryPercentage == 61 })
        // The second identical frame is dropped by the engine in the same main-actor pass that
        // applied the first, so no fixed grace period is needed before counting events.
        #expect(events.states.count == 2,
                "Expected the initial fetch and one changed live state, not one event per identical frame")
        coordinator.stop()
    }

    /// The slow integrity poll still runs while the stream is healthy – that is the drift
    /// check the design keeps, and it is the only thing that fetches.
    @Test
    func integrityPollStillFetchesWhileStreamIsHealthy() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [.healthy(frames: 1)], recorder: recorder)
        let events = DiagnosticsRecorder()
        let policy = LiveStreamPolicy(integrityPollInterval: 0.3, retrySteps: [0.1])
        let clock = ManualTickClock()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults,
                                          policy: policy, scheduler: makeManualScheduler(clock))
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        _ = try #require(await waitUntil(events) { $0.liveStreamConnected })
        // Each integrity tick is released by the test, one at a time, instead of waiting out its
        // 0.3–1.3 s jittered delay. A released tick runs its refresh, then arms the next integrity
        // tick, which parks until the following release.
        for round in 1...2 {
            // The re-armed tick parks on the clock a pass after its schedule call, so wait for a
            // short (integrity-cadence) wait to be the newest one rather than reading a stale entry.
            try await clock.waitForPark(after: round - 1, maximumDuration: 2)
            let parked = clock.pendingDuration ?? .infinity
            #expect(parked < 2, "The armed tick should be the integrity cadence, got \(parked) s")
            let waitsBefore = clock.waits.count
            let fetchesBefore = await provider.fetchCount
            clock.releaseLatest()
            _ = try #require(await waitUntil(events) { $0.refreshSuccesses > round })
            try await clock.waitForPark(after: waitsBefore)
            #expect(await provider.fetchCount > fetchesBefore)
        }
        #expect(await provider.fetchCount >= 3, "Two released integrity ticks should each fetch once")
        #expect(recorder.purposes == [.charging], "Integrity polling must not restart the stream")
        #expect(recorder.maxConcurrent == 1)
        coordinator.stop()
        clock.releaseAll()
    }

    @Test(arguments: [true, false])
    func recoveryDefersFetchUntilProviderDeadline(wake: Bool) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = StreamingMockProvider(script: [], recorder: StreamRecorder())
        let events = DiagnosticsRecorder()
        let clock = ManualTickClock()
        var currentTime = Date()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults,
            now: { currentTime }, scheduler: makeManualScheduler(clock))
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let deadline = currentTime.addingTimeInterval(60)
        coordinator.rateLimitedUntil = deadline
        if wake { coordinator.systemWillSleep() }
        else { coordinator.networkDidChange(false) }
        let before = clock.waits.count
        if wake { coordinator.systemDidWake() }
        else { coordinator.networkDidChange(true) }
        #expect(await provider.fetchCount == 1)
        #expect(coordinator.nextRefresh == deadline)
        try await clock.waitForPark(after: before)
        currentTime = deadline
        clock.releaseLatest()
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses >= 2 })
        coordinator.stop()
        clock.releaseAll()
    }

    // MARK: - Reconnect behavior

    /// Transient disconnects reconnect with the collapsed backoff ladder and never touch the
    /// token endpoints – and never run two streams at once.
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

    /// The reported all-day loop, at the coordinator seam: a refused token exchange must park
    /// the stream, publish that it needs authorization, ask the shell for a sign-in (the
    /// `.failed` event), and never restart itself. New credentials are the only thing that
    /// lets it try again.
    @Test
    func refusedTokenExchangeParksTheStreamUntilCredentialsChange() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let auth = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        let provider = StreamingMockProvider(script: [.fail(auth)], recorder: recorder)
        await provider.setAuthorizationRefreshFailure(auth)
        let events = DiagnosticsRecorder()
        let policy = LiveStreamPolicy(repeatedFailureCircuitInterval: 0.2, retrySteps: [0.05])
        let coordinator = makeCoordinator(provider: provider, defaults: defaults, policy: policy)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)

        let parked = await waitUntil(events, timeout: 8) { $0.liveStreamNeedsAuthorization }
        let snapshot = try #require(parked, "Expected the stream to park and ask for sign-in")
        #expect(snapshot.liveStreamRetryAt == nil, "A parked stream is not waiting out a backoff")
        #expect(await provider.authorizationRefreshCount == 1,
                "A refused exchange is not retried: the session is gone, not slow")
        #expect(await provider.streamAttemptCount == 1)
        // The same failure the polling path emits, which is what asks the shell to sign in.
        #expect(events.failedErrors.contains { $0.requiresAuthentication })

        // Parking terminates the engine instead of arming another timed retry.
        #expect(await provider.streamAttemptCount == 1, "The parked stream restarted itself")
        #expect(!(coordinator.streamEngine?.isRunning ?? true))

        // New credentials are the one event that heals it: the provider accepts the token
        // exchange again, and the parked flag clears so a reconnect is allowed.
        await provider.setAuthorizationRefreshFailure(nil)
        coordinator.credentialsChanged(preferredVIN: StreamingMockProvider.vinA)
        #expect(!coordinator.streamNeedsAuthorization)
        let resumed = await waitUntil(events, timeout: 8) { $0.liveStreamConnected }
        _ = try #require(resumed, "New credentials must let the stream connect again")
        #expect(await provider.streamAttemptCount == 2)

        coordinator.stop()
    }

    // MARK: - Purpose gating

    /// When charging ends, the battery stream closes – it has nothing fresh to say about an
    /// idle car – and the regular poll cadence returns.
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
        #expect(await provider.waitForFetch(count: 2))
        let stopped = await waitUntil(events, timeout: 8) { snapshot in
            events.states.last?.isCharging == false && !snapshot.liveStreamConnected
                && snapshot.liveStreamMetrics.activeTransportStreams == 0 && snapshot.nextRefresh != nil
        }
        _ = try #require(stopped, "Expected the stream to stop once charging ended")
        if let next = events.snapshots.last?.nextRefresh?.timeIntervalSinceNow {
            #expect(next > 550, "Expected the idle-vehicle poll cadence (~10 min) after the stream stopped, got \(next) s")
        }
        #expect(await provider.fetchCount == 2, "Expected exactly one confirmation fetch after charging ended")
        coordinator.stop()
    }

    /// A lock command opens a short exterior-confirmation stream in place of the battery
    /// stream; when the window lapses the watchdog closes it and the charging gate decides
    /// again – an expired confirmation stream must never linger as "the live stream".
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
        let database = VehicleDatabase.inMemory()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            database: database,
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
        let persistedReceipts = VehicleStateStore(defaults: defaults, database: database)

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
        #expect(persistedReceipts.commandReceipts(for: StreamingMockProvider.vinA).last?.receipt == receipt)

        coordinator.dismissCommandReceipt(issuedAt: receipt.issuedAt)
        #expect(events.states.last?.commandState.receipt == nil)
        #expect(events.snapshots.last?.commandReceiptVisible == false)
        #expect(persistedReceipts.commandReceipts(for: StreamingMockProvider.vinA).last == nil)

        coordinator.refreshNow()
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 2 })
        #expect(events.states.last?.commandState.receipt == nil)
        #expect(events.snapshots.last?.commandConfirmationStatus == .awaiting)
        coordinator.stop()
    }

    @Test
    func multipleCommandReceiptsPersistAndDismissIndependently() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = DiagnosticsRecorder()
        let database = VehicleDatabase.inMemory()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            database: database,
            commandInitialPollDelay: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        let first = CommandReceipt(
            commandIdentifier: RemoteCommand.honkHorn.identifier,
            issuedAt: Date(),
            command: .honkHorn
        )
        let second = CommandReceipt(
            commandIdentifier: RemoteCommand.flashLights.identifier,
            issuedAt: Date().addingTimeInterval(0.01),
            command: .flashLights
        )
        coordinator.beginCommandConfirmation(first)
        coordinator.beginCommandConfirmation(second)

        #expect(events.states.last?.commandState.receipts == [first, second])
        let store = VehicleStateStore(defaults: defaults, database: database)
        #expect(store.commandReceipts(for: StreamingMockProvider.vinA).map(\.receipt) == [first, second])

        coordinator.dismissCommandReceipt(id: first.id)

        #expect(events.states.last?.commandState.receipts == [second])
        #expect(store.commandReceipts(for: StreamingMockProvider.vinA).map(\.receipt) == [second])
        #expect(events.snapshots.last?.commandReceiptVisible == true)
        coordinator.stop()
    }

    @Test
    func overlappingConfirmationsPollCombinedTelemetryWithoutReplacingEither() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = StreamingMockProvider(script: [], recorder: StreamRecorder())
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandInitialPollDelay: 0.05,
            commandPollInterval: 0.1
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        let charging = CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(80).identifier,
            issuedAt: Date(),
            command: .setChargeTarget(80)
        )
        let cleaning = CommandReceipt(
            commandIdentifier: RemoteCommand.startPreCleaning.identifier,
            issuedAt: Date().addingTimeInterval(0.01),
            command: .startPreCleaning
        )
        coordinator.beginCommandConfirmation(charging)
        coordinator.beginCommandConfirmation(cleaning)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses >= 2 })
        let selections = await provider.fetchSelections
        #expect(selections.contains { $0.enabled == [.remoteCharging, .remotePreCleaning] })
        let receipts = try #require(events.states.last?.commandState.receipts)
        // The matching charging read confirms that receipt without disturbing the cleaning one.
        #expect(receipts.first(where: { $0.id == charging.id })?.status.isConfirmed == true)
        #expect(receipts.first(where: { $0.id == cleaning.id })?.status == .awaiting)
        coordinator.stop()
    }

    @Test
    func matchingTelemetryConfirmsOneReceiptWithoutEndingAnother() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = StreamingMockProvider(
            script: [.exteriorLocked],
            recorder: StreamRecorder()
        )
        await provider.setCharging(false)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(provider: provider, defaults: defaults)
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        let horn = CommandReceipt(
            commandIdentifier: RemoteCommand.honkHorn.identifier,
            issuedAt: Date(),
            command: .honkHorn
        )
        let lock = CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: Date().addingTimeInterval(0.01),
            command: .lock
        )
        coordinator.beginCommandConfirmation(horn)
        coordinator.beginCommandConfirmation(lock)
        _ = try #require(await waitUntil(events) { diagnostics in
            diagnostics.commandConfirmationIdentifier == horn.commandIdentifier
                && diagnostics.awaitingCommandReceiptCount == 1
                && events.states.contains { state in
                    state.commandState.receipts.first(where: { $0.id == lock.id })?
                        .status.isConfirmed == true
                }
        })

        let receipts = try #require(events.states.last?.commandState.receipts)
        #expect(receipts.first(where: { $0.id == lock.id })?.status.isConfirmed == true)
        #expect(receipts.first(where: { $0.id == horn.id })?.status == .awaiting)
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
            !$0.liveStreamConnected && $0.liveStreamRetryAt != nil && $0.nextRefresh != nil
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
        _ = try #require(await waitUntil(events, timeout: 2) { $0.refreshSuccesses >= 2 })
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
        _ = try #require(await waitUntil(events, timeout: 2) { $0.refreshSuccesses >= 2 })
        #expect(recorder.purposes.count == before, "Climate commands must not open any stream")
        #expect(recorder.purposes == [.charging])
        #expect(await provider.fetchCount == 2, "Climate commands retain one authoritative follow-up poll")
        coordinator.stop()
    }

    @Test
    func repeatedClimateReceiptSupersedesOlderBannerAndConfirmedReceiptIsHidden() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            commandInitialPollDelay: 5
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        let command = RemoteCommand.startClimate(
            temperatureCelsius: 0,
            frontLeftSeat: .off,
            frontRightSeat: .off,
            rearLeftSeat: .off,
            rearRightSeat: .off,
            steeringWheel: .off
        )
        let first = CommandReceipt(
            commandIdentifier: command.identifier,
            issuedAt: Date().addingTimeInterval(-1),
            command: command
        )
        let second = CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: Date(),
            command: .stopClimate
        )
        coordinator.beginCommandConfirmation(first)
        coordinator.beginCommandConfirmation(second)
        #expect(events.states.last?.commandState.receipts.map(\.id) == [second.id])

        let confirmed = CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: second.issuedAt,
            command: .stopClimate,
            status: .confirmed(at: Date())
        )
        coordinator.beginCommandConfirmation(confirmed)
        #expect(events.states.last?.commandState.receipts.isEmpty == true)
        coordinator.stop()
    }

    @Test
    func acknowledgedUnobservableClimateCommandCreatesNoStickyBanner() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = DiagnosticsRecorder()
        let database = VehicleDatabase.inMemory()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            database: database
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.stopClimate.identifier,
            issuedAt: Date(),
            command: .stopClimate,
            providerBrand: .volvo,
            status: .acknowledged(at: Date())
        )
        coordinator.beginCommandConfirmation(receipt)

        #expect(events.states.last?.commandState.receipts.isEmpty == true)
        #expect(events.snapshots.last?.awaitingCommandReceiptCount == 0)
        #expect(VehicleStateStore(defaults: defaults, database: database)
            .commandReceipts(for: StreamingMockProvider.vinA).map(\.receipt.id) == [receipt.id])
        coordinator.stop()
    }

    @Test
    func climateConfirmationUsesRawTelemetryInsteadOfOptimisticPresentation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let provider = StreamingMockProvider(script: [], recorder: StreamRecorder())
        await provider.setCharging(false)
        await provider.setClimate(.idle)
        let preferences = PreferencesStore(defaults: defaults,
                                           keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: database),
            observesEnvironment: false,
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }),
            commandConfirmationWindow: 2,
            commandConfirmationInitialPollDelay: 0.05,
            commandConfirmationPollInterval: 0.1
        )
        let events = DiagnosticsRecorder()
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        var optimistic = try #require(coordinator.latest)
        optimistic.climateStatus = VehicleClimateStatus(
            activity: .heating, timeRemainingMinutes: 30, timerTriggered: false)
        optimistic.commandState.optimisticLockUntil = Date().addingTimeInterval(90)
        let command = RemoteCommand.startClimate(
            temperatureCelsius: 0,
            frontLeftSeat: .off,
            frontRightSeat: .off,
            rearLeftSeat: .off,
            rearRightSeat: .off,
            steeringWheel: .off
        )
        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: command.identifier,
            issuedAt: Date(),
            command: command
        ), optimisticState: optimistic)

        _ = try #require(await waitUntil(events) { $0.refreshSuccesses >= 2 })
        #expect(events.snapshots.last?.commandConfirmationStatus == .awaiting)
        #expect(database.snapshots.loadSnapshot(for: StreamingMockProvider.vinA)?.climateStatus?.activity == .idle)
        #expect(events.states.last?.climateStatus?.activity == .heating)

        await provider.setClimate(.ventilating)
        _ = try #require(await waitUntil(events) { diagnostics in
            diagnostics.commandConfirmationStatus?.isConfirmed == true
        })
        #expect(database.snapshots.loadSnapshot(for: StreamingMockProvider.vinA)?.climateStatus?.activity == .ventilating)
        #expect(events.states.last?.climateStatus?.activity == .ventilating)
        #expect(events.states.last?.commandState.receipts.isEmpty == true)
        coordinator.stop()
    }

    @Test(arguments: [
        RemoteCommand.setChargeTarget(80),
        RemoteCommand.setAmpLimit(16)
    ])
    func pollOnlyChargingSettingConfirmationConfirmsWithoutOpeningAStream(
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

        // A matching post-command read confirms a charging-setting write on the first targeted
        // poll — including the no-op case, where the vehicle never advances its own reading
        // timestamp. Confirming must also END the short repeat cadence: polling a no-op write
        // for the whole confirmation window burned ~500 quota calls per command.
        let firstPoll = try #require(await waitUntil(events, timeout: 2) {
            $0.refreshSuccesses >= 2 && $0.nextRefresh != nil
        })
        #expect(recorder.purposes.isEmpty, "Charging-setting confirmation must not open the battery stream")
        let receipts = try #require(events.states.last?.commandState.receipts)
        switch command {
        case .setChargeTarget:
            // The mock's state reports target 80, so a matching post-command read confirms
            // immediately — and confirmation must end the short repeat cadence (a no-op write
            // used to poll the whole five-minute window, ~500 quota calls).
            #expect(receipts.first?.status.isConfirmed == true)
            _ = try #require(await waitUntil(events, timeout: 2) {
                ($0.nextRefresh?.timeIntervalSinceNow ?? .infinity) > 60
            })
        case .setAmpLimit:
            // The mock reports no current limit, so this receipt cannot prove: it must keep
            // the short repeat cadence (without a stream) until the value lands.
            #expect(receipts.first?.status.isAwaiting == true)
            #expect((firstPoll.nextRefresh?.timeIntervalSinceNow ?? .infinity) < 1.2,
                    "Unproven poll-only confirmation retains its short repeat cadence")
            _ = try #require(await waitUntil(events, timeout: 2) {
                $0.refreshSuccesses >= 3
            }, "Expected poll-only confirmation to fetch repeatedly")
        default:
            Issue.record("unexpected command")
        }
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
    func injectedTimeSourceDefinesTheConfirmationDeadline() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var currentTime = Date(timeIntervalSince1970: 1_750_000_000)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            commandWindow: 90,
            now: { currentTime }
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        coordinator.beginCommandConfirmation(CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(90).identifier,
            issuedAt: currentTime,
            command: .setChargeTarget(90)
        ))

        let originalDeadline = currentTime.addingTimeInterval(90)
        #expect(events.snapshots.last?.commandConfirmationDeadline == originalDeadline)

        coordinator.systemWillSleep()
        currentTime = currentTime.addingTimeInterval(30)
        coordinator.systemDidWake()
        #expect(events.snapshots.last?.commandConfirmationDeadline == originalDeadline.addingTimeInterval(30))
        coordinator.stop()
    }

    @Test
    func confirmationPollFetchesOnlyCommandTelemetry() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StreamRecorder()
        let provider = StreamingMockProvider(script: [], recorder: recorder)
        await provider.setCharging(false)
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

        #expect(await provider.waitForFetch(count: 2, matching: [.remoteCharging]))
        _ = try #require(await waitUntil(events) { $0.refreshAttempts >= 2 && $0.nextRefresh != nil })
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

        // Wait for the awaiting state to carry a schedule rather than reading whatever snapshot
        // happened to land last: a refresh in flight publishes with `nextRefresh` cleared.
        let awaiting = try #require(await waitUntil(events) {
            $0.commandConfirmationStatus == .awaiting && $0.nextRefresh != nil
        }, "Expected a confirmation poll scheduled under the provider's retry deadline")
        let confirmationDeadline = try #require(awaiting.nextRefresh)
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
        // One database for both instances: the durable tier they share is what a relaunch reads.
        let database = VehicleDatabase.inMemory()
        let first = makeCoordinator(provider: firstProvider, defaults: defaults, database: database)
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
        let second = makeCoordinator(provider: secondProvider, defaults: defaults, database: database)
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
    func relaunchRestoresMultipleReceiptLifecycles() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let issuedAt = Date()
        let confirmed = CommandReceipt(
            commandIdentifier: RemoteCommand.setChargeTarget(80).identifier,
            issuedAt: issuedAt.addingTimeInterval(-30),
            command: .setChargeTarget(80),
            status: .confirmed(at: issuedAt.addingTimeInterval(-20))
        )
        let awaiting = CommandReceipt(
            commandIdentifier: RemoteCommand.lock.identifier,
            issuedAt: issuedAt,
            command: .lock
        )
        let database = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: defaults, database: database)
        store.saveCommandReceipts([
            StoredCommandReceipt(receipt: confirmed, confirmationDeadline: nil),
            StoredCommandReceipt(
                receipt: awaiting,
                confirmationDeadline: issuedAt.addingTimeInterval(60)
            )
        ], for: StreamingMockProvider.vinA)

        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            database: database
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })

        #expect(events.states.last?.commandState.receipts == [confirmed, awaiting])
        #expect(events.snapshots.last?.commandReceiptCount == 2)
        #expect(events.snapshots.last?.awaitingCommandReceiptCount == 1)
        coordinator.stop()
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
        let database = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: defaults, database: database)
        store.saveCommandReceipts(
            [StoredCommandReceipt(receipt: receipt, confirmationDeadline: deadline)],
            for: StreamingMockProvider.vinA
        )

        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            database: database
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) {
            $0.refreshSuccesses == 1
                && $0.commandConfirmationIdentifier == receipt.commandIdentifier
        })

        #expect(events.snapshots.last?.commandConfirmationDeadline == nil)
        #expect(events.states.last?.commandState.receipt?.status == .timedOut(at: deadline))
        #expect(store.commandReceipts(for: StreamingMockProvider.vinA).last?.receipt.status == .timedOut(at: deadline))
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
        #expect(store.commandReceipts(for: StreamingMockProvider.vinA).last == nil)
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
        var currentTime = Date()
        let coordinator = makeCoordinator(
            provider: provider,
            defaults: defaults,
            commandWindow: 0.1,
            commandInitialPollDelay: 5,
            commandPollInterval: 5,
            now: { currentTime }
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
        currentTime = currentTime.addingTimeInterval(0.2)
        resume(coordinator)

        _ = try #require(await waitUntil(events) { diagnostics in
            diagnostics.liveStreamConnected
                && recorder.purposes.filter { $0 == .exteriorConfirmation }.count == 2
        }, "Expected confirmation streaming to resume after temporary suspension")
        #expect(recorder.purposes.last == .exteriorConfirmation)
        coordinator.stop()
    }

    /// Switching vehicles cancels the old stream and opens at most one stream for the new
    /// VIN – the expired task's cleanup must not resurrect state for a car we left.
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

    @Test
    func vehicleSwitchPreservesReceiptsPerVIN() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = DiagnosticsRecorder()
        let database = VehicleDatabase.inMemory()
        let coordinator = makeCoordinator(
            provider: StreamingMockProvider(script: [], recorder: StreamRecorder()),
            defaults: defaults,
            database: database
        )
        coordinator.onEvent = { events.record($0) }
        coordinator.start(preferredVIN: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses == 1 })
        let receipt = CommandReceipt(
            commandIdentifier: RemoteCommand.honkHorn.identifier,
            issuedAt: Date(),
            command: .honkHorn,
            targetVIN: StreamingMockProvider.vinA,
            providerBrand: .polestar,
            status: .acknowledged(at: Date())
        )
        coordinator.beginCommandConfirmation(receipt)

        coordinator.selectCar(vin: StreamingMockProvider.vinB)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses >= 2 })
        #expect(events.states.last?.identity.vin == StreamingMockProvider.vinB)
        #expect(events.states.last?.commandState.receipts.isEmpty == true)

        coordinator.selectCar(vin: StreamingMockProvider.vinA)
        _ = try #require(await waitUntil(events) { $0.refreshSuccesses >= 3 })
        #expect(events.states.last?.identity.vin == StreamingMockProvider.vinA)
        #expect(events.states.last?.commandState.receipts.isEmpty == true)
        #expect(VehicleStateStore(defaults: defaults, database: database)
            .commandReceipts(for: StreamingMockProvider.vinA).map(\.receipt.id) == [receipt.id])
        coordinator.stop()
    }
}

// MARK: - Recorders

private enum StreamBehavior: Sendable {
    case fail(Error)
    case healthy(frames: Int)
    case repeatedBattery(frames: Int)
    case exteriorLocked
}

/// Releases only the newest armed cadence wait; superseded waits leave through cancellation.
@MainActor
private final class ManualTickClock {
    private struct Parked {
        let id: UUID
        let duration: TimeInterval
        let release: TestEvent<Void>
    }
    private(set) var waits: [TimeInterval] = []
    private var parked: [Parked] = []
    private let changes = TestEvent<Void>()

    var pendingDuration: TimeInterval? { parked.last?.duration }

    func park(_ duration: TimeInterval) async throws {
        let id = UUID()
        let release = TestEvent<Void>()
        waits.append(duration)
        parked.append(Parked(id: id, duration: duration, release: release))
        changes.yield(())
        defer { parked.removeAll { $0.id == id } }
        try await release.next(timeout: .seconds(45))
    }

    func waitForPark(after count: Int, minimumDuration: TimeInterval = -.infinity,
                     maximumDuration: TimeInterval = .infinity) async throws {
        while !(waits.count > count && (pendingDuration.map {
            $0 > minimumDuration && $0 < maximumDuration
        } ?? false)) {
            try await changes.next()
        }
    }

    func releaseLatest() { parked.last?.release.yield(()) }

    func releaseAll() {
        let all = parked
        parked.removeAll()
        all.forEach { $0.release.cancel() }
        changes.cancel()
    }
}

/// Lock-protected record of stream opens. `onTermination` runs on an arbitrary executor, so
/// actor isolation cannot protect this state – and test closures read it synchronously.
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
    private(set) var failedErrors: [VehicleServiceError] = []

    private struct Waiter {
        let condition: @MainActor (DiagnosticsSnapshot) -> Bool
        let continuation: CheckedContinuation<DiagnosticsSnapshot?, Never>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func wait(timeout: TimeInterval, condition: @escaping @MainActor (DiagnosticsSnapshot) -> Bool) async -> DiagnosticsSnapshot? {
        if let snapshot = snapshots.last(where: condition) { return snapshot }
        if Task.isCancelled { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(id, with: nil)
                }
                waiters[id] = Waiter(condition: condition, continuation: continuation, timeout: timeoutTask)
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: nil) }
        }
    }

    private func finish(_ id: UUID, with snapshot: DiagnosticsSnapshot?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: snapshot)
    }

    func record(_ event: RefreshCoordinatorEvent) {
        if case .diagnostics(let snapshot) = event { snapshots.append(snapshot) }
        if case .state(let state) = event { states.append(state) }
        if case .failed(let error) = event { failedErrors.append(error) }
        guard let snapshot = snapshots.last else { return }
        let matched = waiters.filter { $0.value.condition(snapshot) }.map(\.key)
        for id in matched { finish(id, with: snapshot) }
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
    private(set) var streamAttemptCount = 0
    private(set) var remoteCommandCount = 0
    private var refreshFailure: VehicleServiceError?
    private struct FetchWaiter {
        let count: Int
        let selection: Set<AppFeature>?
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private var fetchWaiters: [UUID: FetchWaiter] = [:]
    private var charging = true
    private var climateActivity: ClimateActivity?
    private var nextFetchFailure: VehicleServiceError?
    private var script: [StreamBehavior]
    private let recorder: StreamRecorder

    init(script: [StreamBehavior], recorder: StreamRecorder) {
        self.script = script
        self.recorder = recorder
    }

    func waitForFetch(count: Int, matching selection: Set<AppFeature>? = nil) async -> Bool {
        if fetchCount >= count && (selection == nil || fetchSelections.contains { $0.enabled == selection }) { return true }
        if Task.isCancelled { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.finishFetchWaiter(id, success: false)
                }
                fetchWaiters[id] = FetchWaiter(count: count, selection: selection, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { await self.finishFetchWaiter(id, success: false) }
        }
    }

    private func finishFetchWaiter(_ id: UUID, success: Bool) {
        guard let waiter = fetchWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: success)
    }

    func setCharging(_ enabled: Bool) { charging = enabled }
    func setClimate(_ activity: ClimateActivity?) { climateActivity = activity }
    func failNextFetch(_ error: VehicleServiceError) { nextFetchFailure = error }
    func setAuthorizationRefreshFailure(_ error: VehicleServiceError?) { refreshFailure = error }

    // VehicleProviding

    var hasWarmSession: Bool { true }
    var cars: [CarSummary] {
        [CarSummary(vin: Self.vinA, title: "Car A"), CarSummary(vin: Self.vinB, title: "Car B")]
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? Self.vinA }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        fetchSelections.append(features)
        let ready = fetchWaiters.filter { waiter in
            fetchCount >= waiter.value.count && (waiter.value.selection == nil
                || features.enabled == waiter.value.selection)
        }.map(\.key)
        for id in ready { finishFetchWaiter(id, success: true) }
        if let nextFetchFailure {
            self.nextFetchFailure = nil
            throw nextFetchFailure
        }
        var state = Self.makeMockState(vin: vin, charging: charging)
        if let climateActivity {
            state.climateStatus = VehicleClimateStatus(
                activity: climateActivity,
                timeRemainingMinutes: climateActivity == .idle ? nil : 30,
                timerTriggered: false
            )
            state.freshness.readingDates[.climateStatus] = state.freshness.fetchedAt
        }
        return state
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        remoteCommandCount += 1
        return RemoteCommandResult(outcome: .completed, message: nil)
    }

    // VehicleLiveStreaming

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        streamAttemptCount += 1
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
        case .repeatedBattery(let frames):
            recorder.open(purpose: purpose, vin: vin)
            let recorder = self.recorder
            let frame = Self.frame(percent: 61)
            return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
                continuation.yield(.connected(activeTransportStreams: 1))
                for _ in 0..<frames {
                    continuation.yield(.battery(frame))
                }
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
        if let refreshFailure { throw refreshFailure }
    }

    private static func makeMockState(vin: String, charging: Bool) -> VehicleState {
        // TESTS-12: thin wrapper over the shared TestSupport fixture builder.
        vehicle(
            vin: vin, battery: 55, rangeKm: 280,
            state: charging ? .charging : .idle,
            connection: charging ? .connected : .disconnected,
            chargingType: charging ? .ac : .none,
            modelYear: nil,
            fetchedAt: Date(), reportedAt: nil
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
