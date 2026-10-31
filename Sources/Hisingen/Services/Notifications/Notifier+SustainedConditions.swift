import AppKit

extension Notifier {
    /// Re-evaluates conditions that depend on wall-clock time rather than fresh
    /// telemetry, so a parked-open car still escalates even if polling stalls.
    private func recheckSustainedConditions() {
        guard available, authorized, preferences.features.contains(.notifications) else { return }
        dailySummaryTick(now: Date())
        for state in previousStateByVIN.values where !preferences.isMuted(vin: state.identity.vin) {
            checkOpeningsLeftOpen(current: state)
            checkSlowCharging(current: state)
            checkStaleTelemetry(current: state)
        }
    }

    func startSustainedRecheckTimer() {
        guard available else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recheckSustainedConditions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sustainedRecheckTimer = timer
    }

    func checkOpeningsLeftOpen(current: VehicleState) {
        let openings = current.exteriorStatus?.itemsNeedingAttention.map(\.displayName) ?? []
        let condition = current.hasFreshReading(.openings) && current.fuelSystem.isEngineRunning != true && !openings.isEmpty
        trackSustained(condition: condition, key: "\(current.identity.vin).openings", duration: TimeInterval(preferences.openingsAlertDelayMinutes * 60), enabled: preferences.notifyOpeningsLeftOpen) {
            self.postNotice(identifier: "hisingen.\(current.identity.vin).openings-left-open",
                            thread: "hisingen.security.\(current.identity.vin)",
                            title: L10n.text("Vehicle left open"),
                            body: self.privateBody(openings.joined(separator: " · ")),
                            subtitle: self.displayName(for: current),
                            vin: current.identity.vin,
                            urgency: .urgent,
                            category: Self.openingsCategoryID)
        }
    }

    func checkStaleTelemetry(current: VehicleState) {
        let condition = current.isStale()
        trackSustained(condition: condition, key: "\(current.identity.vin).stale", duration: 1, enabled: preferences.notifyStaleTelemetry) {
            self.postNotice(identifier: "hisingen.\(current.identity.vin).stale-telemetry", thread: "hisingen.telemetry.\(current.identity.vin)",
                            title: L10n.text("Vehicle data is stale"),
                            body: self.privateBody(current.freshnessDescription),
                            subtitle: self.displayName(for: current), vin: current.identity.vin,
                            urgency: .background, category: Self.vehicleAlertCategoryID)
        }
    }

    func trackSustained(condition: Bool, key: String, duration: TimeInterval, enabled: Bool = true,
                                action: () -> Void) {
        guard condition else {
            if sustainedConditionStartedAt.removeValue(forKey: key) != nil {
                persistSustainedState()
            }
            if sustainedNotificationsDelivered.remove(key) != nil {
                persistSustainedState()
            }
            return
        }
        let started = sustainedConditionStartedAt[key] ?? Date()
        if sustainedConditionStartedAt[key] == nil {
            sustainedConditionStartedAt[key] = started
            persistSustainedState()
        }
        guard enabled, !sustainedNotificationsDelivered.contains(key),
              Date().timeIntervalSince(started) >= duration else { return }
        sustainedNotificationsDelivered.insert(key)
        persistSustainedState()
        action()
    }

    func persistSustainedState() {
        defaults.set(sustainedConditionStartedAt.mapValues { $0.timeIntervalSince1970 },
                     forKey: "notifier_sustained_starts_v1")
        defaults.set(Array(sustainedNotificationsDelivered), forKey: "notifier_sustained_delivered_v1")
    }

    /// Called when a vehicle's mute state flips so lingering sustained timers for that
    /// car don't fire the moment it is un-muted.
    func vehicleMuteDidChange(vin: String) {
        let prefix = "\(vin)."
        sustainedConditionStartedAt = sustainedConditionStartedAt.filter { !$0.key.hasPrefix(prefix) }
        sustainedNotificationsDelivered = sustainedNotificationsDelivered.filter { !$0.hasPrefix(prefix) }
        persistSustainedState()
    }
}
