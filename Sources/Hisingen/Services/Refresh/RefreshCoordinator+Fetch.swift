import Foundation
import OSLog

extension RefreshCoordinator {
    func refreshNow() {
        let admission = admit(.manual)
        if case .refused(.rateLimited(let until)) = admission {
            // A rate limit is the one refusal this path can present: tell the user when the
            // pause ends rather than doing nothing visible.
            nextRefresh = until
            publishDiagnostics()
            return
        }
        // Protection for one surface against a repeated click, not precedence between sleep,
        // network, rate limits and in-flight work.
        if let lastManualRefresh, now().timeIntervalSince(lastManualRefresh) < 2, task != nil {
            return
        }
        lastManualRefresh = now()
        switch admission {
        case .start:
            refresh(trigger: .manual)
        case .refused(.needsSession):
            beginSession(preferredVIN: preferences.vin.nilIfEmpty)
        case .refused:
            break
        }
    }

    func reloadVehicleMetadata() {
        if !preferences.features.contains(.realTimeUpdates) {
            streamEngine?.stop()
        }
        // Every refusal but the rate limit folds into an ordinary manual refresh, which is what
        // an unestablished session or an in-flight fetch needs anyway.
        switch admit(.metadata) {
        case .start:
            break
        case .refused(.rateLimited):
            return
        case .refused:
            refreshNow()
            return
        }
        let vin = preferences.vin
        let requestGeneration = generation
        onEvent?(.loading)
        task = Task {
            do {
                try await api.reloadVehicleMetadata(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                refresh(trigger: .manual)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                handle(ServiceErrorPolicy.decision(error, provider: api.brand).error, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    func refreshIfStale() {
        guard let latest else { refreshNow(); return }
        let interval = RefreshPolicy.interval(
            isCharging: latest.isCharging,
            isClimateActive: latest.isClimateActive,
            isVehicleAvailable: {
                switch latest.identity.availability {
                case .available: return true
                case .unavailable: return false
                case .unknown: return nil
                }
            }()
        )
        if now().timeIntervalSince(latest.freshness.fetchedAt) >= interval { refreshNow() }
    }

    func refresh(trigger: Trigger) {
        switch admit(trigger.intent) {
        case .start:
            break
        case .refused(.noVehicleSelected):
            handle(.notConfigured, retrySession: false)
            return
        case .refused:
            return
        }
        if trigger == .manual { onEvent?(.loading) }
        let vin = preferences.vin
        scheduler.cancel()
        nextRefresh = nil
        let confirmationFeatures = confirmations.targetedFeatures(isScheduledTick: trigger.isScheduledTick)
        let features = confirmationFeatures ?? preferences.features
        let requestGeneration = generation
        let started = now()
        refreshAttempts += 1
        task = Task {
            // Signpost spans the network round trip so Instruments shows per-refresh
            // latency without any log volume.
            let intervalState = Self.signposter.beginInterval("fetchVehicleState")
            do {
                let state = try await api.fetchVehicleState(vin: vin, features: features)
                Self.signposter.endInterval("fetchVehicleState", intervalState)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(
                    state,
                    latency: max(0, now().timeIntervalSince(started)),
                    refreshedFeatures: confirmationFeatures?.enabled
                )
            } catch {
                Self.signposter.endInterval("fetchVehicleState", intervalState)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = ServiceErrorPolicy.decision(error, provider: api.brand).error
                if mapped.requiresAuthentication { sessionReady = false }
                handle(mapped, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    func apply(
        _ state: VehicleState,
        latency: TimeInterval,
        refreshedFeatures: Set<AppFeature>? = nil
    ) {
        let previous = latest
        var authoritative = state.mergingLastKnown(
            from: latestAuthoritative,
            features: preferences.features,
            refreshedFeatures: refreshedFeatures,
            imageBackfill: imageBackfill(for: state.identity.vin)
        )
        // Command receipts and optimistic locks are coordinator-owned presentation state,
        // never provider telemetry or durable history.
        authoritative.stripPresentationState()
        // SQLite is the single source of truth for completed charging history. Clear legacy
        // snapshot-carried sessions so the UI cannot alternate between two divergent stores.
        authoritative.energy.sessions = []
        latestAuthoritative = authoritative
        lastFullRefreshAt = authoritative.freshness.fetchedAt
        lastError = nil
        lastLatency = latency
        failureCount = 0
        refreshSuccesses += 1
        rateLimitedUntil = nil
        stateStore.save(authoritative)
        SpotlightIndexer.indexVehicle(authoritative, nickname: preferences.vehicleNickname(for: authoritative.identity.vin))
        let confirmed = confirmations.observe(authoritative, vin: latest?.identity.vin)
        let displayed = commandPresentation(
            authoritative: authoritative,
            previous: previous,
            refreshedFeatures: refreshedFeatures
        )
        latest = displayed
        onEvent?(.state(displayed))
        if confirmed {
            refreshCommandConfirmationInfrastructure(vin: authoritative.identity.vin)
        }
        if desiredLiveStreamPurpose(for: displayed) == nil {
            stopLiveStreaming()
        } else {
            startLiveStreamingIfNeeded(vin: authoritative.identity.vin)
        }
        let interval = pollingInterval(for: displayed)
        schedule(after: interval, retrySession: false, addsJitter: !confirmations.isConfirmationPending)
        publishDiagnostics()
    }

    func commandPresentation(
        authoritative: VehicleState,
        previous: VehicleState?,
        refreshedFeatures: Set<AppFeature>? = nil
    ) -> VehicleState {
        var displayed = authoritative
        if confirmations.isConfirmationPending,
           var optimistic = previous,
           optimistic.identity.vin == authoritative.identity.vin {
            // The optimistic overlay owns these display fields while its command awaits
            // telemetry; every other field accepts the authoritative read.
            let preserved = confirmations.optimisticFields
            if !preserved.contains(.climateStatus) { optimistic.climateStatus = authoritative.climateStatus }
            if !preserved.contains(.airQuality) { optimistic.airQuality = authoritative.airQuality }
            if !preserved.contains(.exterior) {
                optimistic.exteriorStatus = authoritative.exteriorStatus
            }
            if !preserved.contains(.chargeTarget) {
                optimistic.energy.targetPercentage = authoritative.energy.targetPercentage
            }
            if !preserved.contains(.chargingCurrentLimit) {
                optimistic.energy.currentLimitAmps = authoritative.energy.currentLimitAmps
            }
            if !preserved.contains(.chargingState) {
                optimistic.energy.chargingState = authoritative.energy.chargingState
            }
            displayed = authoritative.mergingLastKnown(
                from: optimistic,
                features: preferences.features,
                refreshedFeatures: refreshedFeatures,
                imageBackfill: imageBackfill(for: authoritative.identity.vin)
            )
        }
        displayed.publish(confirmations.overlay)
        return displayed
    }

    /// Resolves the persisted-image tier for a merge. The image cache is persistence-owned,
    /// so it is probed here and the bytes travel into the merge as `VehicleImageBackfill`
    /// data; Domain never reaches into a store. Probes only when vehicle images are part of
    /// the requested feature set, matching the old in-merge gate.
    private func imageBackfill(for vin: String) -> VehicleImageBackfill {
        guard preferences.features.contains(.vehicleImage) else { return .empty }
        return VehicleImageBackfill(
            exterior: imageCache.image(for: vin),
            interior: imageCache.interiorImage(for: vin)
        )
    }

    func handle(_ error: VehicleServiceError, retrySession: Bool) {
        lastError = error
        failureCount += 1
        refreshFailures += 1
        // `String(describing:)` keeps enum payloads and NSError codes that
        // `localizedDescription` flattens away.
        logger.error("Refresh failed (attempt \(self.failureCount, privacy: .public) consecutive): \(String(describing: error), privacy: .public)")
        onEvent?(.failed(error))
        guard error.allowsAutomaticRetry else {
            scheduler.cancel()
            nextRefresh = nil
            publishDiagnostics()
            return
        }
        let retryAfter: TimeInterval?
        if case .rateLimited(let value) = error { retryAfter = value } else { retryAfter = nil }
        let needsSession = retrySession || error.requiresNewSession
        let delay = retryDelay(failureCount, retryAfter, needsSession)
        if case .rateLimited = error {
            rateLimitedUntil = now().addingTimeInterval(delay)
            logger.warning("Rate limited; pausing refreshes until \(self.rateLimitedUntil.map { "\($0)" } ?? "?", privacy: .public)")
        }
        schedule(after: delay, retrySession: needsSession)
        publishDiagnostics()
    }
}
