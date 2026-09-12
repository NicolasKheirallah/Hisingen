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
                    batteryPercentage = value
                    if let reportedAt { readingDates[.battery] = reportedAt }
                }
                batteryDiagnostics = battery.diagnostics
                reportedBatteryCapacityKwh = battery.reportedBatteryCapacityKwh
                    ?? reportedBatteryCapacityKwh
                appliedReading = true
            }
            if let value = battery.rangeKm,
               shouldApplyLiveReading(.range, reportedAt: reportedAt) {
                rangeKm = value
                if let reportedAt { readingDates[.range] = reportedAt }
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
                estimatedChargingTimeToFullMinutes = battery.estimatedChargingTimeToFullMinutes
                    ?? estimatedChargingTimeToFullMinutes
                chargingState = battery.chargingState ?? chargingState
                if battery.chargerConnection != .unknown {
                    chargerConnection = battery.chargerConnection
                }
                if battery.chargingType != .unknown {
                    chargingType = battery.chargingType
                }
                chargingPowerWatts = battery.chargingPowerWatts ?? chargingPowerWatts
                chargingCurrentAmps = battery.chargingCurrentAmps ?? chargingCurrentAmps
                chargingVoltageVolts = battery.chargingVoltageVolts ?? chargingVoltageVolts
                if let reportedAt { readingDates[.charging] = reportedAt }
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
                if let date { readingDates[.openings] = date }
                appliedReading = true
            }
            if (exterior.isLocked != nil || exterior.alarmTriggered != nil),
               shouldApplyLiveReading(.locks, reportedAt: date) {
                next.isLocked = merged.isLocked
                next.alarmTriggered = merged.alarmTriggered
                if let date { readingDates[.locks] = date }
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
        fetchedAt = receivedAt
        isCachedSnapshot = false
    }

    func shouldApplyLiveReading(_ reading: VehicleReading, reportedAt: Date?) -> Bool {
        guard let reportedAt, let current = readingDates[reading] else { return true }
        return reportedAt >= current
    }

    private mutating func advanceVehicleReportedAt(to reportedAt: Date?) {
        guard let reportedAt else { return }
        vehicleReportedAt = max(vehicleReportedAt ?? .distantPast, reportedAt)
    }

    func mergingLastKnown(
        from previous: VehicleState?,
        features: FeatureSelection,
        refreshedFeatures: Set<AppFeature>? = nil,
        imageCache: CarImageCache = CarImageCache()
    ) -> VehicleState {
        guard let previous, previous.vin == vin else { return self }
        let failed = Set(unavailableFeatures)
        let refreshed = refreshedFeatures ?? AppFeature.permittedFeatures
        func wasRefreshed(_ feature: AppFeature) -> Bool {
            refreshed.contains(feature)
        }
        func keep(_ feature: AppFeature) -> Bool {
            features.contains(feature) && (!wasRefreshed(feature) || failed.contains(feature))
        }
        let mergedUnavailableFeatures = failed.union(
            previous.unavailableFeatures.filter { !wasRefreshed($0) }
        ).sorted { $0.title < $1.title }
        let previousChargingState: ChargingState? = {
            if case .unknown = chargingState { return previous.chargingState }
            return nil
        }()
        let mergedAvailability: VehicleAvailability = {
            guard features.contains(.vehicleAvailability), case .unknown = availability else { return availability }
            return previous.availability
        }()
        let mergedProbes: VehicleProbedCapabilities? = {
            guard let probedCapabilities else { return previous.probedCapabilities }
            return previous.probedCapabilities?.merging(newerProbe: probedCapabilities) ?? probedCapabilities
        }()
        let connectivityIsUnsupported = probedCapabilities?.support(for: .connectivity) == .unavailable
        // Polestar reports a single version string whose meaning flips once an update is
        // pending, so the running version drops out of the payload for the whole rollout.
        // Carry the last settled reading forward — otherwise "Installed Version" disappears
        // from the moment an update is offered until it finishes installing.
        let mergedSoftware: VehicleSoftwareInfo? = {
            guard var current = softwareInfo else {
                return keep(.softwareUpdates) ? previous.softwareInfo : nil
            }
            if current.installedVersion == nil {
                current.installedVersion = previous.softwareInfo?.installedVersion
            }
            return current
        }()

        let isCommandLocked = (previous.optimisticCommandLockUntil ?? .distantPast) > Date()
        let mergedClimate: VehicleClimateStatus? = {
            guard let prevClimate = previous.climateStatus else {
                return climateStatus ?? (features.contains(.climateStatus) ? previous.climateStatus : nil)
            }
            if isCommandLocked {
                if prevClimate.activity == .heating || prevClimate.activity == .cooling || prevClimate.activity == .ventilating || prevClimate.activity == .active {
                    if let incoming = climateStatus, incoming.activity == .heating || incoming.activity == .cooling || incoming.activity == .ventilating || incoming.activity == .active {
                        return incoming
                    }
                    return prevClimate
                } else if prevClimate.activity == .idle {
                    if let incoming = climateStatus, incoming.activity == .idle {
                        return incoming
                    }
                    return prevClimate
                }
            }
            return climateStatus ?? (features.contains(.climateStatus) ? previous.climateStatus : nil)
        }()

        let mergedAirQuality: VehicleAirQuality? = {
            // During the command grace window a disagreeing reading is a stale cache, not a flip.
            if isCommandLocked, let previous = previous.airQuality {
                if let incoming = airQuality, incoming.cleaningState == previous.cleaningState {
                    return incoming
                }
                return previous
            }
            return airQuality ?? previous.airQuality
        }()

        let mergedChargeTarget: Int? = {
            if isCommandLocked, let prevTarget = previous.chargeTargetPercentage {
                return prevTarget
            }
            return chargeTargetPercentage ?? previous.chargeTargetPercentage
        }()

        let mergedCurrentAmps: Int? = {
            if isCommandLocked, let prevAmps = previous.chargingCurrentAmps {
                return prevAmps
            }
            return chargingCurrentAmps ?? previous.chargingCurrentAmps
        }()

        var merged = VehicleState(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: batteryPercentage ?? previous.batteryPercentage,
                rangeKm: rangeKm ?? previous.rangeKm,
                chargingState: previousChargingState ?? chargingState,
                estimatedTimeToFullMinutes: estimatedChargingTimeToFullMinutes
                    ?? previous.estimatedChargingTimeToFullMinutes,
                targetPercentage: mergedChargeTarget,
                powerWatts: chargingPowerWatts ?? previous.chargingPowerWatts,
                currentAmps: mergedCurrentAmps,
                voltageVolts: chargingVoltageVolts ?? previous.chargingVoltageVolts,
                type: chargingType == .unknown ? previous.chargingType : chargingType,
                connection: chargerConnection == .unknown ? previous.chargerConnection : chargerConnection,
                reportedBatteryCapacityKwh: reportedBatteryCapacityKwh ?? previous.reportedBatteryCapacityKwh,
                diagnostics: batteryDiagnostics
                    ?? (features.contains(.batteryDiagnostics) ? previous.batteryDiagnostics : nil),
                schedules: !chargingSchedules.isEmpty ? chargingSchedules
                    : (features.contains(.chargingSchedule) ? previous.chargingSchedules : [])
            ),
            identity: VehicleIdentitySnapshot(
                availability: mergedAvailability,
                modelName: modelName ?? (features.contains(.vehicleIdentity) ? previous.modelName : nil),
                modelYear: modelYear ?? (features.contains(.vehicleIdentity) ? previous.modelYear : nil),
                registrationNo: registrationNo ?? (features.contains(.vehicleIdentity) ? previous.registrationNo : nil),
                vin: vin,
                ownerFirstName: ownerFirstName ?? (features.contains(.ownerGreeting) ? previous.ownerFirstName : nil),
                imageData: imageData ?? (features.contains(.vehicleImage)
                    ? (previous.imageData ?? imageCache.image(for: vin)) : nil)
            ),
            maintenance: MaintenanceAndHealthSnapshot(
                odometerKm: odometerKm ?? (features.contains(.vehicleHealth) ? previous.odometerKm : nil),
                details: healthDetails ?? (features.contains(.tyreAndWarnings) ? previous.healthDetails : nil),
                service: ServiceSnapshot(
                    daysToService: daysToService ?? (features.contains(.vehicleHealth) ? previous.daysToService : nil),
                    distanceToServiceKm: distanceToServiceKm
                        ?? (features.contains(.vehicleHealth) ? previous.distanceToServiceKm : nil),
                    serviceWarning: !serviceWarning && keep(.vehicleHealth) ? previous.serviceWarning : serviceWarning,
                    fluidWarnings: fluidWarnings.isEmpty && keep(.vehicleHealth) ? previous.fluidWarnings : fluidWarnings
                )
            ),
            freshness: SnapshotFreshness(
                fetchedAt: fetchedAt,
                vehicleReportedAt: vehicleReportedAt ?? previous.vehicleReportedAt,
                dataWarnings: dataWarnings,
                unavailableFeatures: mergedUnavailableFeatures
            ),
            exteriorStatus: exteriorStatus ?? (features.contains(.exteriorStatus) ? previous.exteriorStatus : nil),
            softwareInfo: mergedSoftware,
            climateStatus: mergedClimate,
            climateTimers: !climateTimers.isEmpty ? climateTimers
                : (features.contains(.climateStatus) ? previous.climateTimers : []),
            tripComputer: TripComputerSnapshot(
                manualTripKm: tripMeterManualKm ?? (features.contains(.tripMeters) ? previous.tripMeterManualKm : nil),
                automaticTripKm: tripMeterAutomaticKm ?? (features.contains(.tripMeters) ? previous.tripMeterAutomaticKm : nil)
            ),
            connectivity: connectivity ?? (features.contains(.connectivityDiagnostics) && !connectivityIsUnsupported
                ? previous.connectivity : nil),
            airQuality: mergedAirQuality,
            weather: weather ?? (features.contains(.vehicleWeather) ? previous.weather : nil),
            location: location ?? (features.contains(.vehicleLocation) ? previous.location : nil),
            probedCapabilities: mergedProbes,
            powertrain: powertrain == .unknown ? previous.powertrain : powertrain,
            fuelSystem: FuelSystemSnapshot(
                levelPercent: fuelLevelPercent ?? previous.fuelLevelPercent,
                rangeKm: fuelRangeKm ?? previous.fuelRangeKm
            )
        )
        merged.externalColour = externalColour ?? previous.externalColour
        merged.gearbox = gearbox ?? previous.gearbox
        merged.engineHoursToService = engineHoursToService ?? previous.engineHoursToService
        merged.averageSpeedKmH = averageSpeedKmH ?? previous.averageSpeedKmH
        merged.fuelAmountLiters = fuelAmountLiters ?? previous.fuelAmountLiters
        merged.averageFuelConsumptionLPer100Km = averageFuelConsumptionLPer100Km ?? previous.averageFuelConsumptionLPer100Km
        merged.isEngineRunning = isEngineRunning ?? previous.isEngineRunning
        merged.fuelType = fuelType ?? previous.fuelType
        merged.structureWeek = structureWeek ?? previous.structureWeek
        merged.internalVehicleIdentifier = internalVehicleIdentifier ?? previous.internalVehicleIdentifier
        merged.pno34 = pno34 ?? previous.pno34
        merged.readingDates = readingDates
        merged.estimatedChargingTimeToTargetMinutes = estimatedChargingTimeToTargetMinutes
        if batteryPercentage == nil { merged.readingDates[.battery] = previous.reportedDate(for: .battery) }
        if rangeKm == nil { merged.readingDates[.range] = previous.reportedDate(for: .range) }
        if odometerKm == nil { merged.readingDates[.odometer] = previous.reportedDate(for: .odometer) }
        if healthDetails == nil { merged.readingDates[.health] = previous.reportedDate(for: .health) }
        merged.accountMarket = accountMarket ?? previous.accountMarket
        merged.upholstery = upholstery ?? previous.upholstery
        merged.steeringOrientation = steeringOrientation ?? previous.steeringOrientation
        merged.serviceTrigger = serviceTrigger ?? previous.serviceTrigger
        merged.tripComputerElectricRangeKm = tripComputerElectricRangeKm ?? previous.tripComputerElectricRangeKm
        merged.chargingCurrentLimitAmps = chargingCurrentLimitAmps ?? previous.chargingCurrentLimitAmps
        // Locations are only re-shown when this fetch actually returned them; an empty result
        // after a backend hiccup should not wipe the list the controls tab is rendering.
        merged.chargeLocations = chargeLocations.isEmpty ? previous.chargeLocations : chargeLocations
        merged.warrantyInfo = warrantyInfo ?? previous.warrantyInfo
        merged.interiorImageData = interiorImageData
            ?? (features.contains(.vehicleImage) ? (previous.interiorImageData ?? imageCache.interiorImage(for: vin)) : nil)
        merged.optimisticCommandLockUntil = isCommandLocked ? previous.optimisticCommandLockUntil : nil
        merged.electricDistanceKm = electricDistanceKm ?? previous.electricDistanceKm
        merged.fuelDistanceKm = fuelDistanceKm ?? previous.fuelDistanceKm
        merged.regeneratedEnergyKwh = regeneratedEnergyKwh ?? previous.regeneratedEnergyKwh
        merged.tripComputer.manualAverageSpeedKmH = tripComputer.manualAverageSpeedKmH
            ?? previous.tripComputer.manualAverageSpeedKmH
        merged.tripComputer.automaticAverageSpeedKmH = tripComputer.automaticAverageSpeedKmH
            ?? previous.tripComputer.automaticAverageSpeedKmH
        merged.frontBrakePadStatus = frontBrakePadStatus ?? previous.frontBrakePadStatus
        merged.rearBrakePadStatus = rearBrakePadStatus ?? previous.rearBrakePadStatus
        merged.preferredWorkshopId = preferredWorkshopId ?? previous.preferredWorkshopId
        merged.preferredWorkshopName = preferredWorkshopName ?? previous.preferredWorkshopName

        var retained = Set(previous.retainedDataCategories.filter { !wasRefreshed($0) })
        func markRetained(_ feature: AppFeature, currentIsMissing: Bool, previousWasPresent: Bool) {
            if features.contains(feature), wasRefreshed(feature), currentIsMissing, previousWasPresent {
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
        retained.formUnion(failed.filter { features.contains($0) })
        merged.retainedDataCategories = retained.sorted { $0.title < $1.title }
        merged.retainedDataAt = retained.isEmpty ? nil : (previous.retainedDataAt ?? previous.vehicleReportedAt ?? previous.fetchedAt)

        var samples = previous.chargingSamples
        if merged.isCharging, let pct = merged.batteryPercentage {
            let sample = ChargingSample(
                timestamp: fetchedAt, batteryPercentage: pct, powerWatts: merged.chargingPowerWatts,
                chargingType: merged.chargingType
            )
            if let last = samples.last {
                if sample.timestamp.timeIntervalSince(last.timestamp) >= 20 || abs(sample.batteryPercentage - last.batteryPercentage) >= 0.2 {
                    samples.append(sample)
                }
            } else {
                samples.append(sample)
            }
            if samples.count > 50 {
                samples.removeFirst(samples.count - 50)
            }
        } else if !merged.isCharging {
            samples.removeAll()
        }
        merged.chargingSamples = samples
        return merged
    }
}
