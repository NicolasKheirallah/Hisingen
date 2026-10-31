import Foundation

/// What a snapshot-level merge may consult: the requested features, what this refresh
/// actually refreshed, what came back unavailable, and whether a just-accepted command
/// still owns the displayed value. Per-field retention rules live with their snapshot;
/// they read the shared situation through this one value.
struct SnapshotMergePolicy {
    let features: FeatureSelection
    let refreshedFeatures: Set<AppFeature>
    let failedFeatures: Set<AppFeature>
    let isCommandLocked: Bool
    let fetchedAt: Date

    init(features: FeatureSelection,
         refreshedFeatures: Set<AppFeature>?,
         failedFeatures: [AppFeature],
         isCommandLocked: Bool,
         fetchedAt: Date) {
        self.features = features
        self.refreshedFeatures = refreshedFeatures ?? AppFeature.permittedFeatures
        self.failedFeatures = Set(failedFeatures)
        self.isCommandLocked = isCommandLocked
        self.fetchedAt = fetchedAt
    }

    func wasRefreshed(_ feature: AppFeature) -> Bool {
        refreshedFeatures.contains(feature)
    }

    /// A value survives from the previous snapshot only when its feature was requested and
    /// this refresh did not produce a fresh (or attempted-but-failed) reading for it.
    func keep(_ feature: AppFeature) -> Bool {
        features.contains(feature) && (!wasRefreshed(feature) || failedFeatures.contains(feature))
    }

    /// During the command grace window a disagreeing reading is a stale cache, not a flip:
    /// the previous value wins until the lock expires or telemetry confirms the same state.
    func commandLockedValue<T>(new: T?, previous: T?, keepPrevious: Bool = true) -> T? {
        if isCommandLocked, let previous { return previous }
        if let new { return new }
        return keepPrevious ? previous : nil
    }
}

extension EnergyAndChargingSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        let previousChargingState: ChargingState? = {
            if case .unknown = chargingState { return previous.chargingState }
            return nil
        }()
        let keepCharging = policy.features.contains(.chargingDetails)
        var merged = EnergyAndChargingSnapshot(
            batteryPercentage: batteryPercentage ?? (keepCharging ? previous.batteryPercentage : nil),
            rangeKm: rangeKm ?? (keepCharging ? previous.rangeKm : nil),
            chargingState: previousChargingState ?? chargingState,
            scheduleOutcome: scheduleOutcome ?? (keepCharging ? previous.scheduleOutcome : nil),
            estimatedTimeToFullMinutes: estimatedTimeToFullMinutes ?? (keepCharging ? previous.estimatedTimeToFullMinutes : nil),
            estimatedTimeToTargetMinutes: estimatedTimeToTargetMinutes ?? (keepCharging ? previous.estimatedTimeToTargetMinutes : nil),
            targetPercentage: policy.commandLockedValue(new: targetPercentage, previous: previous.targetPercentage, keepPrevious: keepCharging),
            powerWatts: powerWatts ?? (keepCharging ? previous.powerWatts : nil),
            currentAmps: policy.commandLockedValue(new: currentAmps, previous: previous.currentAmps, keepPrevious: keepCharging),
            voltageVolts: voltageVolts ?? (keepCharging ? previous.voltageVolts : nil),
            type: type == .unknown ? previous.type : type,
            connection: connection == .unknown ? previous.connection : connection,
            currentLimitAmps: currentLimitAmps ?? (keepCharging ? previous.currentLimitAmps : nil),
            reportedBatteryCapacityKwh: reportedBatteryCapacityKwh ?? (keepCharging ? previous.reportedBatteryCapacityKwh : nil),
            diagnostics: diagnostics ?? (policy.features.contains(.batteryDiagnostics) ? previous.diagnostics : nil),
            schedules: !schedules.isEmpty ? schedules
                : (policy.features.contains(.chargingSchedule) ? previous.schedules : []),
            // Locations are only re-shown when this fetch actually returned them or when the
            // feature was not refreshed; an empty result after a successful refresh clears
            // rather than holding stale locations.
            locations: !locations.isEmpty ? locations
                : (policy.keep(.chargingDetails) ? previous.locations : []),
            // A failed charge-now read must not keep a stale override pill alive: nil the
            // flag for this cycle rather than carrying the last success forward.
            chargeNowActive: policy.failedFeatures.contains(.remoteCharging)
                ? nil
                : (chargeNowActive ?? (keepCharging ? previous.chargeNowActive : nil)),
            // Providers never produce samples; the buffer carries forward from the previous
            // snapshot and the live reading below appends to it.
            samples: previous.samples
        )
        merged.absorbChargingSample(at: policy.fetchedAt)
        return merged
    }

    /// Live charging-sample accumulation for the in-progress charging curve. Runs on every
    /// merged snapshot: a new sample lands when charging has moved (≥20 s or ≥0.2 %), the
    /// buffer is capped, and it resets as soon as the car stops charging.
    mutating func absorbChargingSample(at fetchedAt: Date) {
        guard chargingState.isActivelyCharging else {
            samples = []
            return
        }
        guard let percentage = batteryPercentage else { return }
        let sample = ChargingSample(
            timestamp: fetchedAt, batteryPercentage: percentage, powerWatts: powerWatts, chargingType: type
        )
        if let last = samples.last {
            if sample.timestamp.timeIntervalSince(last.timestamp) >= 20
                || abs(sample.batteryPercentage - last.batteryPercentage) >= 0.2 {
                samples.append(sample)
            }
        } else {
            samples.append(sample)
        }
        if samples.count > 50 {
            samples.removeFirst(samples.count - 50)
        }
    }
}

extension VehicleIdentitySnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy, imageBackfill: VehicleImageBackfill) -> Self {
        let availability: VehicleAvailability = {
            guard policy.features.contains(.vehicleAvailability), case .unknown = self.availability else {
                return self.availability
            }
            return previous.availability
        }()
        return VehicleIdentitySnapshot(
            availability: availability,
            modelName: modelName ?? (policy.features.contains(.vehicleIdentity) ? previous.modelName : nil),
            modelYear: modelYear ?? (policy.features.contains(.vehicleIdentity) ? previous.modelYear : nil),
            registrationNo: registrationNo ?? (policy.features.contains(.vehicleIdentity) ? previous.registrationNo : nil),
            vin: vin,
            ownerFirstName: ownerFirstName ?? (policy.features.contains(.ownerGreeting) ? previous.ownerFirstName : nil),
            externalColour: externalColour ?? previous.externalColour,
            gearbox: gearbox ?? previous.gearbox,
            structureWeek: structureWeek ?? previous.structureWeek,
            internalVehicleIdentifier: internalVehicleIdentifier ?? previous.internalVehicleIdentifier,
            pno34: pno34 ?? previous.pno34,
            accountMarket: accountMarket ?? previous.accountMarket,
            upholstery: upholstery ?? previous.upholstery,
            steeringOrientation: steeringOrientation ?? previous.steeringOrientation,
            imageData: imageData ?? (policy.features.contains(.vehicleImage)
                ? (previous.imageData ?? imageBackfill.exterior) : nil),
            interiorImageData: interiorImageData ?? (policy.features.contains(.vehicleImage)
                ? (previous.interiorImageData ?? imageBackfill.interior) : nil),
            usageMode: usageMode ?? previous.usageMode,
            // The producer nils the reason on any AVAILABLE frame, so an incoming nil here
            // means "this frame says available" or "the availability read failed" — carry
            // the previous reason forward only while the merged availability is still
            // unavailable, never across a transition back to online.
            unavailableReason: unavailableReason ?? {
                if case .unavailable = availability { return previous.unavailableReason }
                return nil
            }()
        )
    }
}

extension ServiceSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        ServiceSnapshot(
            daysToService: daysToService ?? (policy.features.contains(.vehicleHealth) ? previous.daysToService : nil),
            distanceToServiceKm: distanceToServiceKm
                ?? (policy.features.contains(.vehicleHealth) ? previous.distanceToServiceKm : nil),
            serviceWarning: !serviceWarning && policy.keep(.vehicleHealth) ? previous.serviceWarning : serviceWarning,
            fluidWarnings: fluidWarnings.isEmpty && policy.keep(.vehicleHealth) ? previous.fluidWarnings : fluidWarnings,
            engineHoursToService: engineHoursToService ?? (policy.features.contains(.vehicleHealth) ? previous.engineHoursToService : nil),
            trigger: trigger ?? (policy.features.contains(.vehicleHealth) ? previous.trigger : nil),
            preferredWorkshopID: preferredWorkshopID ?? (policy.features.contains(.vehicleHealth) ? previous.preferredWorkshopID : nil),
            preferredWorkshopName: preferredWorkshopName ?? (policy.features.contains(.vehicleHealth) ? previous.preferredWorkshopName : nil)
        )
    }
}

extension MaintenanceAndHealthSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        MaintenanceAndHealthSnapshot(
            odometerKm: odometerKm ?? (policy.features.contains(.vehicleHealth) ? previous.odometerKm : nil),
            odometerKmPrecise: odometerKmPrecise ?? (policy.features.contains(.vehicleHealth) ? previous.odometerKmPrecise : nil),
            details: details ?? (policy.features.contains(.tyreAndWarnings) ? previous.details : nil),
            service: service.merging(previous: previous.service, policy: policy),
            warranty: warranty ?? previous.warranty,
            frontBrakePadStatus: frontBrakePadStatus ?? previous.frontBrakePadStatus,
            rearBrakePadStatus: rearBrakePadStatus ?? previous.rearBrakePadStatus
        )
    }
}

extension TripComputerSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        let keepTrip = policy.features.contains(.tripMeters)
        let keepCharging = policy.features.contains(.chargingDetails)
        return TripComputerSnapshot(
            manualTripKm: manualTripKm ?? (policy.features.contains(.tripMeters) ? previous.manualTripKm : nil),
            automaticTripKm: automaticTripKm ?? (policy.features.contains(.tripMeters) ? previous.automaticTripKm : nil),
            averageSpeedKmH: averageSpeedKmH ?? (keepTrip ? previous.averageSpeedKmH : nil),
            manualAverageSpeedKmH: manualAverageSpeedKmH ?? (keepTrip ? previous.manualAverageSpeedKmH : nil),
            automaticAverageSpeedKmH: automaticAverageSpeedKmH ?? (keepTrip ? previous.automaticAverageSpeedKmH : nil),
            electricRangeKm: electricRangeKm ?? (keepCharging ? previous.electricRangeKm : nil),
            electricDistanceKm: electricDistanceKm ?? (keepTrip ? previous.electricDistanceKm : nil),
            fuelDistanceKm: fuelDistanceKm ?? (keepTrip ? previous.fuelDistanceKm : nil),
            regeneratedEnergyKwh: regeneratedEnergyKwh ?? (keepTrip ? previous.regeneratedEnergyKwh : nil),
            sinceChargeTripKm: sinceChargeTripKm ?? (policy.features.contains(.tripMeters) ? previous.sinceChargeTripKm : nil),
            // Same reading, same feature gate: an average speed without its trip distance
            // would render a never-refreshing half-row when .tripMeters is disabled.
            sinceChargeAverageSpeedKmH: sinceChargeAverageSpeedKmH ?? (policy.features.contains(.tripMeters) ? previous.sinceChargeAverageSpeedKmH : nil)
        )
    }
}

extension FuelSystemSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        let keep = policy.features.contains(.vehicleHealth)
        return FuelSystemSnapshot(
            levelPercent: levelPercent ?? (keep ? previous.levelPercent : nil),
            rangeKm: rangeKm ?? (keep ? previous.rangeKm : nil),
            amountLiters: amountLiters ?? (keep ? previous.amountLiters : nil),
            averageConsumptionLPer100Km: averageConsumptionLPer100Km ?? (keep ? previous.averageConsumptionLPer100Km : nil),
            isEngineRunning: isEngineRunning ?? (keep ? previous.isEngineRunning : nil),
            type: type ?? (keep ? previous.type : nil)
        )
    }
}

extension SnapshotFreshness {
    /// Composes the whole-state freshness record. Reading-date fallbacks and retained-data
    /// categories need the other snapshots' presence, so those stay at the state level.
    func merging(previous: Self, unavailableFeatures: [AppFeature]) -> Self {
        SnapshotFreshness(
            fetchedAt: fetchedAt,
            vehicleReportedAt: vehicleReportedAt ?? previous.vehicleReportedAt,
            dataWarnings: dataWarnings,
            unavailableFeatures: unavailableFeatures,
            retainedDataCategories: [],
            retainedDataAt: nil,
            servedByFallback: servedByFallback,
            readingObservations: readingObservations,
            commandObservations: commandObservations
        )
    }
}

extension VehicleClimateStatus {
    static func merging(
        incoming: VehicleClimateStatus?,
        previous: VehicleClimateStatus?,
        policy: SnapshotMergePolicy
    ) -> VehicleClimateStatus? {
        if policy.isCommandLocked {
            // Confirmation wins over optimism: any live-session reading (including the
            // backend's STARTING state, which outlasts the optimistic overlay) replaces
            // the synthesized state. A stale idle frame or a missing reading must not
            // revert the lock – the previous (optimistic) state stands.
            if let incoming, incoming.activity.isActiveSession { return incoming }
            if let previous { return previous }
        }
        if let incoming { return incoming }
        guard let previous else { return nil }
        return policy.features.contains(.climateStatus) ? previous : nil
    }
}

extension VehicleAirQuality {
    static func merging(
        incoming: VehicleAirQuality?,
        previous: VehicleAirQuality?,
        policy: SnapshotMergePolicy
    ) -> VehicleAirQuality? {
        if policy.isCommandLocked {
            // Same confirmation-wins rule as climate: a live cleaning reading (running
            // or pending) replaces the optimistic state; stale off/unknown frames and
            // missing readings hold the lock.
            if let incoming, incoming.cleaningState == .on || incoming.cleaningState == .pending {
                return incoming
            }
            if let previous { return previous }
        }
        if let incoming { return incoming }
        guard let previous else { return nil }
        return policy.features.contains(.airQuality) ? previous : nil
    }
}
