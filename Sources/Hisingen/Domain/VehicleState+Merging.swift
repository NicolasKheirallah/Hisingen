import Foundation

extension VehicleState {
    mutating func applyLiveUpdate(_ update: VehicleLiveUpdate, receivedAt: Date = Date()) {
        switch update {
        case .connected:
            return
        case .battery(let battery):
            let reportedAt = battery.reportedAt
            var appliedReading = false
            if shouldApplyLiveReading(.battery, reportedAt: reportedAt) {
                if let value = battery.batteryPercentage {
                    energy.batteryPercentage = value
                    if let reportedAt { freshness.readingDates[.battery] = reportedAt }
                }
                energy.diagnostics = battery.diagnostics
                energy.reportedBatteryCapacityKwh = battery.reportedBatteryCapacityKwh
                    ?? energy.reportedBatteryCapacityKwh
                appliedReading = true
            }
            if let value = battery.rangeKm,
               shouldApplyLiveReading(.range, reportedAt: reportedAt) {
                energy.rangeKm = value
                if let reportedAt { freshness.readingDates[.range] = reportedAt }
                appliedReading = true
            }
            let hasChargingReading = battery.estimatedChargingTimeToFullMinutes != nil
                || battery.chargingState != nil
                || battery.chargerConnection != .unknown
                || battery.chargingType != .unknown
                || battery.chargingPowerWatts != nil
                || battery.chargingCurrentAmps != nil
                || battery.chargingVoltageVolts != nil
            if hasChargingReading,
               shouldApplyLiveReading(.charging, reportedAt: reportedAt) {
                energy.estimatedTimeToFullMinutes = battery.estimatedChargingTimeToFullMinutes
                    ?? energy.estimatedTimeToFullMinutes
                energy.chargingState = battery.chargingState ?? energy.chargingState
                if battery.chargerConnection != .unknown {
                    energy.connection = battery.chargerConnection
                }
                if battery.chargingType != .unknown {
                    energy.type = battery.chargingType
                }
                energy.powerWatts = battery.chargingPowerWatts ?? energy.powerWatts
                energy.currentAmps = battery.chargingCurrentAmps ?? energy.currentAmps
                energy.voltageVolts = battery.chargingVoltageVolts ?? energy.voltageVolts
                if let reportedAt { freshness.readingDates[.charging] = reportedAt }
                appliedReading = true
            }
            if appliedReading { advanceVehicleReportedAt(to: reportedAt) }
        case .exterior(let exterior, let reportedAt):
            let date = exterior.reportedAt ?? reportedAt
            let merged = exterior.merging(previous: exteriorStatus)
            var next = exteriorStatus ?? merged
            var appliedReading = false
            if shouldApplyLiveReading(.openings, reportedAt: date) {
                next.openings = merged.openings
                next.isTailgateLocked = merged.isTailgateLocked
                if let date { freshness.readingDates[.openings] = date }
                appliedReading = true
            }
            if (exterior.isLocked != nil || exterior.alarmTriggered != nil),
               shouldApplyLiveReading(.locks, reportedAt: date) {
                next.isLocked = merged.isLocked
                next.alarmTriggered = merged.alarmTriggered
                if let date { freshness.readingDates[.locks] = date }
                appliedReading = true
            }
            if appliedReading {
                if let date {
                    next.reportedAt = max(next.reportedAt ?? .distantPast, date)
                }
                exteriorStatus = next
                advanceVehicleReportedAt(to: date)
            }
        }
        freshness.fetchedAt = receivedAt
        freshness.isCached = false
    }

    func shouldApplyLiveReading(_ reading: VehicleReading, reportedAt: Date?) -> Bool {
        guard let reportedAt, let current = readingDates[reading] else { return true }
        return reportedAt >= current
    }

    private mutating func advanceVehicleReportedAt(to reportedAt: Date?) {
        guard let reportedAt else { return }
        freshness.vehicleReportedAt = max(freshness.vehicleReportedAt ?? .distantPast, reportedAt)
    }

    func mergingLastKnown(
        from previous: VehicleState?,
        features: FeatureSelection,
        refreshedFeatures: Set<AppFeature>? = nil,
        imageCache: CarImageCache = CarImageCache.shared
    ) -> VehicleState {
        guard let previous, previous.vin == vin else { return self }
        let isCommandLocked = (previous.optimisticCommandLockUntil ?? .distantPast) > Date()
        let policy = SnapshotMergePolicy(
            features: features,
            refreshedFeatures: refreshedFeatures,
            failedFeatures: unavailableFeatures,
            isCommandLocked: isCommandLocked,
            fetchedAt: fetchedAt
        )
        let mergedUnavailableFeatures = policy.failedFeatures.union(
            previous.unavailableFeatures.filter { !policy.wasRefreshed($0) }
        ).sorted { $0.title < $1.title }
        let connectivityIsUnsupported = probedCapabilities?.support(for: .connectivity) == .unavailable
        let mergedProbes: VehicleProbedCapabilities? = {
            guard let probedCapabilities else { return previous.probedCapabilities }
            return previous.probedCapabilities?.merging(newerProbe: probedCapabilities) ?? probedCapabilities
        }()
        // Polestar reports a single version string whose meaning flips once an update is
        // pending, so the running version drops out of the payload for the whole rollout.
        // Carry the last settled reading forward – otherwise "Installed Version" disappears
        // from the moment an update is offered until it finishes installing.
        let mergedSoftware: VehicleSoftwareInfo? = {
            guard var current = softwareInfo else {
                return policy.keep(.softwareUpdates) ? previous.softwareInfo : nil
            }
            if current.installedVersion == nil {
                current.installedVersion = previous.softwareInfo?.installedVersion
            }
            return current
        }()

        var merged = VehicleState(
            energy: energy.merging(previous: previous.energy, policy: policy),
            identity: identity.merging(previous: previous.identity, policy: policy, imageCache: imageCache),
            maintenance: maintenance.merging(previous: previous.maintenance, policy: policy),
            freshness: freshness.merging(previous: previous.freshness, unavailableFeatures: mergedUnavailableFeatures),
            exteriorStatus: exteriorStatus ?? (features.contains(.exteriorStatus) ? previous.exteriorStatus : nil),
            softwareInfo: mergedSoftware,
            climateStatus: VehicleClimateStatus.merging(incoming: climateStatus, previous: previous.climateStatus, policy: policy),
            climateTimers: !climateTimers.isEmpty ? climateTimers
                : (features.contains(.climateStatus) ? previous.climateTimers : []),
            tripComputer: tripComputer.merging(previous: previous.tripComputer, policy: policy),
            connectivity: connectivity ?? (features.contains(.connectivityDiagnostics) && !connectivityIsUnsupported
                ? previous.connectivity : nil),
            airQuality: VehicleAirQuality.merging(incoming: airQuality, previous: previous.airQuality, policy: policy),
            weather: weather ?? (features.contains(.vehicleWeather) ? previous.weather : nil),
            location: location ?? (features.contains(.vehicleLocation) ? previous.location : nil),
            probedCapabilities: mergedProbes,
            powertrain: powertrain == .unknown ? previous.powertrain : powertrain,
            fuelSystem: fuelSystem.merging(previous: previous.fuelSystem)
        )
        merged.freshness.readingDates = readingDates
        merged.freshness.metaReceivedDates = freshness.metaReceivedDates ?? previous.freshness.metaReceivedDates
        if energy.batteryPercentage == nil { merged.freshness.readingDates[.battery] = previous.reportedDate(for: .battery) }
        if energy.rangeKm == nil { merged.freshness.readingDates[.range] = previous.reportedDate(for: .range) }
        if maintenance.odometerKm == nil { merged.freshness.readingDates[.odometer] = previous.reportedDate(for: .odometer) }
        if maintenance.details == nil { merged.freshness.readingDates[.health] = previous.reportedDate(for: .health) }

        var retained = Set(previous.retainedDataCategories.filter { !policy.wasRefreshed($0) })
        func markRetained(_ feature: AppFeature, currentIsMissing: Bool, previousWasPresent: Bool) {
            if features.contains(feature), policy.wasRefreshed(feature), currentIsMissing, previousWasPresent {
                retained.insert(feature)
            }
        }
        markRetained(.exteriorStatus, currentIsMissing: exteriorStatus == nil, previousWasPresent: previous.exteriorStatus != nil)
        markRetained(.tyreAndWarnings, currentIsMissing: healthDetails == nil, previousWasPresent: previous.healthDetails != nil)
        markRetained(.softwareUpdates, currentIsMissing: softwareInfo == nil, previousWasPresent: previous.softwareInfo != nil)
        markRetained(.climateStatus, currentIsMissing: climateStatus == nil, previousWasPresent: previous.climateStatus != nil)
        markRetained(.tripMeters, currentIsMissing: tripMeterManualKm == nil && tripMeterAutomaticKm == nil,
                     previousWasPresent: previous.tripMeterManualKm != nil || previous.tripMeterAutomaticKm != nil)
        if !connectivityIsUnsupported {
            markRetained(.connectivityDiagnostics, currentIsMissing: connectivity == nil,
                         previousWasPresent: previous.connectivity != nil)
        }
        markRetained(.airQuality, currentIsMissing: airQuality == nil, previousWasPresent: previous.airQuality != nil)
        markRetained(.batteryDiagnostics, currentIsMissing: batteryDiagnostics == nil, previousWasPresent: previous.batteryDiagnostics != nil)
        markRetained(.vehicleWeather, currentIsMissing: weather == nil, previousWasPresent: previous.weather != nil)
        markRetained(.vehicleLocation, currentIsMissing: location == nil, previousWasPresent: previous.location != nil)
        retained.formUnion(policy.failedFeatures.filter { features.contains($0) })
        merged.freshness.retainedDataCategories = retained.sorted { $0.title < $1.title }
        merged.freshness.retainedDataAt = retained.isEmpty ? nil : (previous.retainedDataAt ?? previous.vehicleReportedAt ?? previous.fetchedAt)
        merged.setOptimisticLock(isCommandLocked ? previous.optimisticCommandLockUntil : nil)
        return merged
    }

    /// Publishes the ledger's overlay. The receipts always come from that one producer, and the
    /// lock is replaced only when the overlay names one, so publishing receipts cannot silently
    /// drop a lock a command has just claimed.
    mutating func publish(_ overlay: CommandPresentationState) {
        commandState.receipts = overlay.receipts
        if let lock = overlay.optimisticLockUntil { commandState.optimisticLockUntil = lock }
    }

    /// Takes the display for a command that was just accepted: the lock starts here and the
    /// ledger's receipts arrive when the confirmation loop can show them.
    mutating func claimOptimisticLock(until lock: Date) {
        commandState = CommandPresentationState(optimisticLockUntil: lock)
    }

    /// Replaces the lock alone — `nil` ends the lock a superseded command claimed while the
    /// receipts stay on screen. The merge policy carries it forward while a command is unconfirmed.
    mutating func setOptimisticLock(_ lock: Date?) {
        commandState.optimisticLockUntil = lock
    }

    /// Drops the display-only command state a fresh provider read must never carry.
    ///
    /// Receipts and optimistic locks are Hisingen's presentation of a command, not telemetry:
    /// persisting them would put them in durable history and in the next snapshot. One call
    /// instead of two assignments at every point a read arrives, so adding a presentation field
    /// cannot leave a stale copy behind at whichever site was missed.
    mutating func stripPresentationState() {
        commandState = .empty
    }
}
