import Foundation

extension RefreshCoordinator {
    func startLiveStreamingIfNeeded(vin: String) {
        guard preferences.features.contains(.realTimeUpdates),
              !streamNeedsAuthorization,
              streamEngine?.isRunning != true,
              let streaming,
              let state = latest,
              let purpose = desiredLiveStreamPurpose(for: state) else { return }
        let requestGeneration = generation
        // Persists at most every 10 s across the frames of this stream run.
        var lastPersistAt = Date.distantPast
        let engine = LiveStreamEngine(
            streaming: streaming,
            providerBrand: api.brand,
            policy: liveStreamPolicy,
            jitter: liveStreamJitter,
            now: now,
            context: .init(
                isDesired: { [weak self] desiredPurpose, desiredVIN in
                    guard let self, requestGeneration == self.generation,
                          self.latest?.identity.vin == desiredVIN,
                          self.desiredLiveStreamPurpose(for: self.latest) == desiredPurpose else { return false }
                    return true
                },
                onConnected: { [weak self] in
                    guard let self else { return }
                    if confirmations.isConfirmationPending {
                        scheduleCommandConfirmationPoll()
                    } else {
                        schedule(after: liveStreamPolicy.integrityPollInterval, retrySession: false)
                    }
                    publishDiagnostics()
                },
                onFrame: { [weak self] update in
                    guard let self, requestGeneration == self.generation,
                          let authoritative = self.latestAuthoritative,
                          authoritative.identity.vin == vin else { return false }
                    let current = await Task.detached(priority: .userInitiated) {
                        var updated = authoritative
                        updated.applyLiveUpdate(update)
                        updated.stripPresentationState()
                        return updated
                    }.value
                    guard requestGeneration == self.generation,
                          self.latestAuthoritative?.identity.vin == vin else { return false }
                    latestAuthoritative = current
                    let frameTime = now()
                    if frameTime.timeIntervalSince(lastPersistAt) >= 10 {
                        lastPersistAt = frameTime
                        stateStore.save(current)
                    }
                    let previous = latest
                    let confirmed = confirmations.observe(current, vin: latest?.identity.vin)
                    let displayed = commandPresentation(
                        authoritative: current,
                        previous: previous
                    )
                    latest = displayed
                    if isMeaningfullyDifferentForPresentation(displayed, from: previous) {
                        onEvent?(.state(displayed))
                    }
                    if confirmed {
                        refreshCommandConfirmationInfrastructure(vin: vin)
                    }
                    return true
                },
                onDisconnected: { [weak self] in
                    guard let self else { return }
                    scheduleFallbackPoll(for: latest)
                    publishDiagnostics()
                },
                onReauthorizationRequired: { [weak self] error in
                    guard let self else { return }
                    handleStreamReauthorizationRequired(error)
                },
                onIdle: { [weak self] in
                    guard let self else { return }
                    scheduleFallbackPoll(for: latest)
                    publishDiagnostics()
                    // A parked stream stays parked: restarting it would only repeat the same
                    // refused token exchange until the user signs in.
                    guard !streamNeedsAuthorization else { return }
                    if let vin = latest?.identity.vin {
                        startLiveStreamingIfNeeded(vin: vin)
                    }
                }
            )
        )
        streamEngine = engine
        engine.setPurpose(purpose, vin: vin)
    }

    /// The stream's token exchange was refused, so no reconnect can succeed until the consumer
    /// session is signed in again. Parks the stream for the rest of this coordinator's life,
    /// leaves the scheduled poll in charge of telemetry, and emits the same authentication
    /// failure the polling path emits so the shell asks the user to sign in.
    func handleStreamReauthorizationRequired(_ error: VehicleServiceError) {
        guard !streamNeedsAuthorization else { return }
        streamNeedsAuthorization = true
        logger.error("Live stream parked until sign-in: \(String(describing: error), privacy: .public)")
        onEvent?(.failed(error))
        publishDiagnostics()
    }

    private func isMeaningfullyDifferentForPresentation(
        _ candidate: VehicleState,
        from previous: VehicleState?
    ) -> Bool {
        guard let previous else { return true }
        return VehiclePresentationFingerprint(candidate) != VehiclePresentationFingerprint(previous)
    }

    func desiredLiveStreamPurpose(for state: VehicleState?) -> VehicleLiveStreamPurpose? {
        guard let state else { return nil }
        // The loop owns which purpose could prove an awaiting command; the routine charging
        // stream is this coordinator's own fallback.
        if case .stream(let commandPurpose) = confirmations.transport(
            for: state, realTimeEnabled: preferences.features.contains(.realTimeUpdates)
        ) {
            return commandPurpose
        }
        return liveStreamPolicy.shouldStream(state) ? .charging : nil
    }

    func stopLiveStreaming() {
        streamEngine?.stop()
    }
}
