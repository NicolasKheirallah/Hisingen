import Foundation

extension RefreshCoordinator {
    func schedule(after interval: TimeInterval, retrySession: Bool, addsJitter: Bool = true) {
        scheduler.cancel()
        guard !sleeping, networkAvailable else { nextRefresh = nil; return }
        let maxJitter = min(15, max(1, interval * 0.1))
        let jitter = addsJitter ? Double.random(in: 0...maxJitter) : 0
        let requestedDeadline = now().addingTimeInterval(interval + jitter)
        let deadline = max(requestedDeadline, rateLimitedUntil ?? .distantPast)
        let delay = max(0, deadline.timeIntervalSince(now()))
        nextRefresh = deadline
        scheduler.scheduleOnce(after: delay) { [weak self] in
            guard let self else { return }
            self.resumeCommandConfirmationIfNeeded()
            if retrySession || !self.sessionReady {
                self.beginSession(preferredVIN: preferences.vin.nilIfEmpty, deferIfBusy: true)
            } else {
                self.streamEngine?.noteFallbackPoll()
                self.refresh(trigger: .timer)
            }
        }
    }

    func scheduleFallbackPoll(for state: VehicleState?) {
        guard let state else { return }
        if confirmations.isConfirmationPending {
            scheduleCommandConfirmationPoll()
            return
        }
        schedule(after: pollingInterval(for: state), retrySession: false)
    }

    func scheduleCommandConfirmationPoll() {
        if scheduler.isArmed, nextRefresh != nil { return }
        schedule(after: confirmations.pollInterval, retrySession: false, addsJitter: false)
    }

    func pollingInterval(for state: VehicleState) -> TimeInterval {
        if confirmations.isConfirmationPending {
            return confirmations.pollInterval
        }
        if streamEngine?.isConnected == true { return liveStreamPolicy.integrityPollInterval }
        return portalPacedInterval(RefreshPolicy.interval(
            isCharging: state.isCharging,
            isClimateActive: state.isClimateActive,
            isVehicleAvailable: {
                if case .unavailable = state.identity.availability { return false }
                if case .available = state.identity.availability { return true }
                return nil
            }()
        ))
    }

    /// Stretches a scheduled cadence so the Data Portal's daily meter lasts until midnight UTC.
    /// Only the portal-backed Polestar modes spend that meter. Manual refreshes skip this path
    /// and still run.
    func portalPacedInterval(_ requested: TimeInterval) -> TimeInterval {
        guard api.brand == .polestar, preferences.polestarConnectionMode != .polestarID else {
            return requested
        }
        let current = now()
        return DataPortalQuotaGovernor.pace(
            requestedInterval: requested,
            used: PolestarDataPortalAPI.dailyCallCount,
            secondsUntilReset: DataPortalQuotaGovernor.secondsUntilReset(now: current),
            now: current
        ).interval
    }
}
