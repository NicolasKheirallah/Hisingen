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
    func commandLockedValue<T>(new: T?, previous: T?) -> T? {
        if isCommandLocked, let previous { return previous }
        return new ?? previous
    }
}

extension EnergyAndChargingSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        let previousChargingState: ChargingState? = {
            if case .unknown = chargingState { return previous.chargingState }
            return nil
        }()
        var merged = EnergyAndChargingSnapshot(
            batteryPercentage: batteryPercentage ?? previous.batteryPercentage,
            rangeKm: rangeKm ?? previous.rangeKm,
            chargingState: previousChargingState ?? chargingState,
            estimatedTimeToFullMinutes: estimatedTimeToFullMinutes ?? previous.estimatedTimeToFullMinutes,
            estimatedTimeToTargetMinutes: estimatedTimeToTargetMinutes ?? previous.estimatedTimeToTargetMinutes,
            targetPercentage: policy.commandLockedValue(new: targetPercentage, previous: previous.targetPercentage),
            powerWatts: powerWatts ?? previous.powerWatts,
            currentAmps: policy.commandLockedValue(new: currentAmps, previous: previous.currentAmps),
            voltageVolts: voltageVolts ?? previous.voltageVolts,
            type: type == .unknown ? previous.type : type,
            connection: connection == .unknown ? previous.connection : connection,
            currentLimitAmps: currentLimitAmps ?? previous.currentLimitAmps,
            reportedBatteryCapacityKwh: reportedBatteryCapacityKwh ?? previous.reportedBatteryCapacityKwh,
            diagnostics: diagnostics ?? (policy.features.contains(.batteryDiagnostics) ? previous.diagnostics : nil),
            schedules: !schedules.isEmpty ? schedules
                : (policy.features.contains(.chargingSchedule) ? previous.schedules : []),
            // Locations are only re-shown when this fetch actually returned them; an empty
            // result after a backend hiccup should not wipe the list the controls tab renders.
            locations: locations.isEmpty ? previous.locations : locations,
            isAtChargeLocation: isAtChargeLocation ?? previous.isAtChargeLocation,
            currentChargeLocationName: currentChargeLocationName ?? previous.currentChargeLocationName,
            chargeNowActive: chargeNowActive ?? previous.chargeNowActive,
            arrivedAtLocationDate: arrivedAtLocationDate ?? previous.arrivedAtLocationDate,
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
    func merging(previous: Self, policy: SnapshotMergePolicy, imageCache: CarImageCache) -> Self {
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
                ? (previous.imageData ?? imageCache.image(for: vin)) : nil),
            interiorImageData: interiorImageData ?? (policy.features.contains(.vehicleImage)
                ? (previous.interiorImageData ?? imageCache.interiorImage(for: vin)) : nil),
            usageMode: usageMode ?? previous.usageMode,
            unavailableReason: unavailableReason ?? previous.unavailableReason
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
            engineHoursToService: engineHoursToService ?? previous.engineHoursToService,
            trigger: trigger ?? previous.trigger,
            preferredWorkshopID: preferredWorkshopID ?? previous.preferredWorkshopID,
            preferredWorkshopName: preferredWorkshopName ?? previous.preferredWorkshopName
        )
    }
}

extension MaintenanceAndHealthSnapshot {
    func merging(previous: Self, policy: SnapshotMergePolicy) -> Self {
        MaintenanceAndHealthSnapshot(
            odometerKm: odometerKm ?? (policy.features.contains(.vehicleHealth) ? previous.odometerKm : nil),
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
        TripComputerSnapshot(
            manualTripKm: manualTripKm ?? (policy.features.contains(.tripMeters) ? previous.manualTripKm : nil),
            automaticTripKm: automaticTripKm ?? (policy.features.contains(.tripMeters) ? previous.automaticTripKm : nil),
            averageSpeedKmH: averageSpeedKmH ?? previous.averageSpeedKmH,
            manualAverageSpeedKmH: manualAverageSpeedKmH ?? previous.manualAverageSpeedKmH,
            automaticAverageSpeedKmH: automaticAverageSpeedKmH ?? previous.automaticAverageSpeedKmH,
            electricRangeKm: electricRangeKm ?? previous.electricRangeKm,
            electricDistanceKm: electricDistanceKm ?? previous.electricDistanceKm,
            fuelDistanceKm: fuelDistanceKm ?? previous.fuelDistanceKm,
            regeneratedEnergyKwh: regeneratedEnergyKwh ?? previous.regeneratedEnergyKwh,
            sinceChargeTripKm: sinceChargeTripKm ?? (policy.features.contains(.tripMeters) ? previous.sinceChargeTripKm : nil),
            sinceChargeAverageSpeedKmH: sinceChargeAverageSpeedKmH ?? previous.sinceChargeAverageSpeedKmH
        )
    }
}

extension FuelSystemSnapshot {
    func merging(previous: Self) -> Self {
        FuelSystemSnapshot(
            levelPercent: levelPercent ?? previous.levelPercent,
            rangeKm: rangeKm ?? previous.rangeKm,
            amountLiters: amountLiters ?? previous.amountLiters,
            averageConsumptionLPer100Km: averageConsumptionLPer100Km ?? previous.averageConsumptionLPer100Km,
            isEngineRunning: isEngineRunning ?? previous.isEngineRunning,
            type: type ?? previous.type
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
            unavailableFeatures: unavailableFeatures
        )
    }
}

extension VehicleClimateStatus {
    static func merging(
        incoming: VehicleClimateStatus?,
        previous: VehicleClimateStatus?,
        policy: SnapshotMergePolicy
    ) -> VehicleClimateStatus? {
        guard let previous else {
            return incoming ?? (policy.features.contains(.climateStatus) ? previous : nil)
        }
        if policy.isCommandLocked {
            if previous.activity.isActiveSession {
                if let incoming, incoming.activity.isActiveSession {
                    return incoming
                }
                return previous
            } else if previous.activity == .idle {
                if let incoming, incoming.activity == .idle {
                    return incoming
                }
                return previous
            }
        }
        return incoming ?? (policy.features.contains(.climateStatus) ? previous : nil)
    }
}

extension VehicleAirQuality {
    static func merging(
        incoming: VehicleAirQuality?,
        previous: VehicleAirQuality?,
        policy: SnapshotMergePolicy
    ) -> VehicleAirQuality? {
        if policy.isCommandLocked, let previous {
            if let incoming, incoming.cleaningState == previous.cleaningState {
                return incoming
            }
            return previous
        }
        return incoming ?? previous
    }
}
