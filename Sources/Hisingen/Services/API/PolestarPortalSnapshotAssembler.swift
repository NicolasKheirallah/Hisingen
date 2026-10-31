import Foundation

struct PolestarPortalTelemetryBundle: Sendable {
    let battery: PolestarDataPortalBatteryDTO?
    let exterior: PolestarDataPortalExteriorDTO?
    let health: PolestarDataPortalHealthDTO?
    let availability: PolestarDataPortalAvailabilityDTO?
    let odometer: PolestarDataPortalOdometerDTO?
    let location: PolestarDataPortalLocationDTO?
    let parkingClimatization: PolestarParkingClimatizationDTO?
    let preCleaning: PolestarPreCleaningDTO?
    let targetSoc: PolestarTargetSocDTO?
    let ampLimit: PolestarAmpLimitDTO?
    let chargeLocations: PolestarChargeLocationsDTO?
    let globalChargeTimer: PolestarGlobalChargeTimerDTO?
    let parkingClimateTimer: PolestarParkingClimateTimerDTO?
    let chargeNow: PolestarChargeNowDTO?
    // No bundle entry for override-charge-timer: the portal defines it as POST/DELETE only,
    // so a per-refresh GET would burn quota on a guaranteed error with nothing to decode.
    // The synced read of the same override switch lives on the charge-now resource above.
}

enum PolestarPortalSnapshotAssembler {
    private static func assembleAvailability(from dto: PolestarDataPortalAvailabilityDTO?) -> VehicleAvailability {
        // A missing frame must not flip a sleeping car to "Online": .unknown makes the
        // identity merge retain the previous availability until a real frame arrives.
        guard let dto, let status = dto.availabilityStatus?.uppercased() else {
            return .unknown
        }
        switch status {
        case "AVAILABLE", "AVAILABILITY_STATUS_AVAILABLE", "ONLINE": return .available
        case "UNAVAILABLE", "AVAILABILITY_STATUS_UNAVAILABLE", "OFFLINE": return .unavailable(reason: dto.unavailableReason)
        default: return .unknown
        }
    }

    private static func assembleReadingDates(from bundle: PolestarPortalTelemetryBundle) -> [VehicleReading: Date] {
        var readingDates: [VehicleReading: Date] = [:]
        if let bDate = bundle.battery?.timestamp?.date { readingDates[.battery] = bDate }
        if let eDate = bundle.exterior?.timestamp?.date { readingDates[.openings] = eDate }
        if let hDate = bundle.health?.timestamp?.date { readingDates[.health] = hDate }
        if let oDate = bundle.odometer?.timestamp?.date { readingDates[.odometer] = oDate }
        if let lDate = bundle.location?.timestamp?.date { readingDates[.location] = lDate }
        if let cDate = bundle.parkingClimatization?.timestamp?.date { readingDates[.climateStatus] = cDate }
        if let aDate = bundle.preCleaning?.timestamp?.date { readingDates[.airQuality] = aDate }
        if let avDate = bundle.availability?.timestamp?.date { readingDates[.availability] = avDate }
        if let cnDate = bundle.chargeNow?.syncedOverrideChargeTimer?.updatedAtTimestamp?.date { readingDates[.charging] = cnDate }
        return readingDates
    }

    /// Portal ingest times keyed like the vehicle report times above, so the freshness card
    /// can show where a domain sat in the delivery pipeline.
    private static func assembleMetaReceivedDates(from bundle: PolestarPortalTelemetryBundle) -> [VehicleReading: Date] {
        var received: [VehicleReading: Date] = [:]
        func ingest(_ raw: String?, for reading: VehicleReading) {
            guard let raw, let date = Self.parseMetaReceivedAt(raw) else { return }
            received[reading] = date
        }
        ingest(bundle.battery?.metaReceivedAt, for: .battery)
        ingest(bundle.exterior?.metaReceivedAt, for: .openings)
        ingest(bundle.health?.metaReceivedAt, for: .health)
        ingest(bundle.odometer?.metaReceivedAt, for: .odometer)
        ingest(bundle.location?.metaReceivedAt, for: .location)
        ingest(bundle.parkingClimatization?.metaReceivedAt, for: .climateStatus)
        ingest(bundle.preCleaning?.metaReceivedAt, for: .airQuality)
        ingest(bundle.availability?.metaReceivedAt, for: .availability)
        ingest(bundle.chargeNow?.metaReceivedAt, for: .charging)
        return received
    }

    /// Ten minutes is well above normal ingest jitter and well below anything a user would
    /// still call fresh, so only genuinely queued readings warn.
    private static let pipelineLagWarningThreshold: TimeInterval = 10 * 60

    private static func assemblePipelineLagWarnings(from bundle: PolestarPortalTelemetryBundle) -> [String] {
        let laggyDomains: [(String, vehicleReportedAt: Date?, metaReceivedAt: String?)] = [
            ("battery", bundle.battery?.timestamp?.date, bundle.battery?.metaReceivedAt),
            ("exterior", bundle.exterior?.timestamp?.date, bundle.exterior?.metaReceivedAt),
            ("health", bundle.health?.timestamp?.date, bundle.health?.metaReceivedAt),
            ("odometer", bundle.odometer?.timestamp?.date, bundle.odometer?.metaReceivedAt),
            ("location", bundle.location?.timestamp?.date, bundle.location?.metaReceivedAt),
            ("climate", bundle.parkingClimatization?.timestamp?.date, bundle.parkingClimatization?.metaReceivedAt),
            ("air quality", bundle.preCleaning?.timestamp?.date, bundle.preCleaning?.metaReceivedAt)
        ]
        return laggyDomains.compactMap { (domain: String, reportedAt: Date?, receivedAt: String?) -> String? in
            guard let reportedAt, let receivedAt,
                  let ingestedAt = Self.parseMetaReceivedAt(receivedAt) else { return nil }
            let interval = ingestedAt.timeIntervalSince(reportedAt)
            guard interval >= Self.pipelineLagWarningThreshold else { return nil }
            guard let lag = portalRoundedInt(interval / 60, range: 0...1_000_000_000) else { return nil }
            // The domain word is a lookup key ("battery", "air quality", …), so the localized
            // sentence reads with the reader's own word instead of an English token.
            return L10n.format("%@ data was delayed at the portal for %d min", L10n.text(domain), Int(lag))
        }
    }

    /// Wire form is RFC 3339, with fractional seconds on the live portal and without in
    /// recorded payloads.
    private static func parseMetaReceivedAt(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func assembleVehicleState(vin: String, bundle: PolestarPortalTelemetryBundle, weather: VehicleWeather?, failedFeatures: [AppFeature] = [], now: Date, timeZone: TimeZone) -> VehicleState {
        var energy = bundle.battery?.toEnergySnapshot() ?? EnergyAndChargingSnapshot()
        if let target = bundle.targetSoc?.targetSocPercentage { energy.targetPercentage = target }
        if let amp = bundle.ampLimit?.ampLimit { energy.currentLimitAmps = amp }
        if let locs = bundle.chargeLocations { energy.locations = locs.toChargeLocations(timeZone: timeZone, now: now) }
        if let timers = bundle.globalChargeTimer { energy.schedules = timers.toSchedules(timeZone: timeZone, now: now) }
        if let syncedOverride = bundle.chargeNow?.syncedOverrideChargeTimer {
            // Only the synced value counts: a pending override has not reached the car yet.
            energy.chargeNowActive = syncedOverride.override == true
        }
        // The backend queues setting changes behind the car's next wake; the pending copies
        // ride alongside the synced values so the controls card can say "queued" instead of
        // silently showing a number the car has not applied.
        if let pendingTarget = bundle.targetSoc?.pendingTargetSoc?.batteryChargeTargetLevel {
            energy.diagnostics?.pendingTargetPercentage = portalRoundedInt(pendingTarget, range: 0...100)
        }
        if let pendingAmps = bundle.ampLimit?.pendingAmpLimit?.ampLimit {
            energy.diagnostics?.pendingLimitAmps = portalRoundedInt(pendingAmps, range: 0...1000)
        }
        if let pendingLocations = bundle.chargeLocations?.pendingChargeLocations, !pendingLocations.isEmpty {
            energy.pendingChargeLocationCount = pendingLocations.count
        }
        if let pendingDeletions = bundle.chargeLocations?.pendingDeleteChargeLocations, !pendingDeletions.isEmpty {
            energy.pendingChargeLocationDeletionCount = pendingDeletions.count
        }
        if bundle.globalChargeTimer?.pendingGlobalChargeTimer != nil {
            energy.pendingGlobalChargeTimer = true
        }
        if let pendingOverride = bundle.chargeNow?.pendingOverrideChargeTimer?.override {
            energy.pendingChargeNowOverride = pendingOverride
        }
        if let pendingClimate = bundle.parkingClimateTimer?.pendingParkingClimateTimers, !pendingClimate.isEmpty {
            energy.pendingClimateTimerCount = pendingClimate.count
        }
        if let pendingClimateDeletions = bundle.parkingClimateTimer?.pendingDeleteParkingClimateTimers,
           !pendingClimateDeletions.isEmpty {
            energy.pendingClimateTimerDeletionCount = pendingClimateDeletions.count
        }
        if bundle.parkingClimateTimer?.pendingTimerSettings != nil {
            energy.pendingTimerSettings = true
        }
        energy.diagnostics?.targetSource = bundle.targetSoc?.targetSoc?.source
        energy.diagnostics?.limitSource = bundle.ampLimit?.syncedAmpLimit?.source
        if let increase = bundle.battery?.dischargeInfo?.energyAvailableIncrease {
            energy.diagnostics?.energyAvailableIncreaseKwh = increase
        }
        if let preconditioning = bundle.battery?.manualPreconditioning {
            energy.diagnostics?.batteryPreconditioningStatus = preconditioning.preconditioningStatus
            energy.diagnostics?.batteryPreconditioningEndsAt = preconditioning.endingAt?.date
        } else if let bpSetting = bundle.parkingClimateTimer?.timerSettings?.batteryPreconditioning,
                  bpSetting != "BP_UNDEFINED" && bpSetting != "BP_OFF" {
            energy.diagnostics?.batteryPreconditioningStatus = bpSetting
        }

        var extSnapshot = bundle.exterior?.toExteriorSnapshot()
        if let alarm = bundle.exterior?.alarm?.uppercased() {
            // The shared exterior mapper treats any value containing "ALARM" as an event,
            // which would flag the spec's ALARM_STATUS_IDLE as triggered. Only the
            // TRIGGERED spelling is an alarm event.
            extSnapshot?.alarmTriggered = alarm.contains("TRIGGERED")
        }

        var healthSnapshot = bundle.health?.toMaintenanceSnapshot() ?? MaintenanceAndHealthSnapshot()
        if let km = bundle.odometer?.calculatedOdometerKm { healthSnapshot.odometerKm = km }
        // The portal reports lifetime distance in metres; keep the sub-kilometre remainder
        // instead of letting only the rounded kilometre value carry it.
        healthSnapshot.odometerKmPrecise = portalValue(bundle.odometer?.odometerMeters, range: 0...10_000_000_000).map { $0 / 1000.0 }

        let tripComputer = bundle.odometer?.toTripComputerSnapshot() ?? TripComputerSnapshot()

        let availability = assembleAvailability(from: bundle.availability)
        let identity = VehicleIdentitySnapshot(
            availability: availability,
            availabilityReportedAt: bundle.availability?.timestamp?.date,
            // Deliberately nil: the M2M surface carries no model metadata, and a placeholder
            // here would win the state merge over the consumer API's real model name
            // ("Polestar" vs "Polestar 2"). A nil keeps the previously fetched name instead.
            modelName: nil,
            vin: vin,
            usageMode: bundle.availability?.usageMode,
            // A stale reason must not shadow an AVAILABLE report, so keep the raw wire
            // value only while the vehicle actually reads as unavailable.
            unavailableReason: {
                if case .unavailable = availability { return bundle.availability?.unavailableReason }
                return nil
            }()
        )
        let readingDates = assembleReadingDates(from: bundle)
        let freshness = SnapshotFreshness(
            isCached: false,
            fetchedAt: now,
            vehicleReportedAt: readingDates.values.max(),
            readingDates: readingDates,
            // metaReceivedAt is the portal's ingest time; a large gap to the vehicle's own
            // timestamp means the reading sat in the delivery pipeline and may be older
            // than its freshness suggests.
            metaReceivedDates: assembleMetaReceivedDates(from: bundle),
            dataWarnings: assemblePipelineLagWarnings(from: bundle),
            // The consumer-exclusive commands are never portal-served; the rest of the
            // list is what this refresh actually asked for and failed to read.
            unavailableFeatures: failedFeatures + [.remoteLocks, .remoteWindows, .remoteHonkFlash, .remoteOTA]
        )

        let timerSettings = bundle.parkingClimateTimer?.timerSettings
        func timerSeatLevel(_ raw: String?) -> Int? {
            switch raw?.uppercased() {
            case "I_OFF", "HEATING_INTENSITY_OFF", "OFF": return 0
            case "I_LEVEL1", "HEATING_INTENSITY_LOW", "LEVEL_1", "LOW": return 1
            case "I_LEVEL2", "HEATING_INTENSITY_MEDIUM", "LEVEL_2", "MEDIUM": return 2
            case "I_LEVEL3", "HEATING_INTENSITY_HIGH", "LEVEL_3", "HIGH": return 3
            default: return nil
            }
        }

        let climateStatus: VehicleClimateStatus? = {
            if let clim = bundle.parkingClimatization {
                var status = clim.toVehicleClimateStatus(batteryPreconditioning: bundle.battery?.manualPreconditioning, now: now)
                if status.requestedTemperatureCelsius == nil, let t = portalValue(timerSettings?.requestedCompartmentTemperatureCelsius, range: -40...60) {
                    status = VehicleClimateStatus(
                        activity: status.activity,
                        timeRemainingMinutes: status.timeRemainingMinutes,
                        timerTriggered: status.timerTriggered,
                        interiorTemperatureCelsius: status.interiorTemperatureCelsius,
                        requestedTemperatureCelsius: t,
                        driverSeatHeatingLevel: status.driverSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowLeftSeat),
                        passengerSeatHeatingLevel: status.passengerSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowRightSeat),
                        steeringWheelHeatingLevel: status.steeringWheelHeatingLevel ?? timerSeatLevel(timerSettings?.steeringWheelHeatingIntensity),
                        rearLeftSeatHeatingLevel: status.rearLeftSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowLeftSeat),
                        rearRightSeatHeatingLevel: status.rearRightSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowRightSeat),
                        ventilation: status.ventilation,
                        mainClimateRunningStatus: status.mainClimateRunningStatus,
                        sessionStartedAt: status.sessionStartedAt,
                        sessionEndsAt: status.sessionEndsAt,
                        errors: status.errors,
                        startReason: status.startReason
                    )
                }
                return status
            }
            if let precond = bundle.battery?.manualPreconditioning {
                let status = precond.preconditioningStatus?.uppercased()
                let isActive = status == "MANUAL_PRECONDITIONING_STATUS_ON" || status == "ACTIVE"
                let started = precond.startedAt?.date
                let ends = precond.endingAt?.date
                let remaining: Int? = {
                    guard let ends else { return nil }
                    let diff = ends.timeIntervalSince(now)
                    return diff > 0 ? max(1, portalRoundedInt(diff / 60, range: 0...525_600) ?? 1) : 0
                }()
                return VehicleClimateStatus(
                    activity: isActive ? .active : .idle,
                    timeRemainingMinutes: isActive ? remaining : nil,
                    timerTriggered: false,
                    requestedTemperatureCelsius: portalValue(timerSettings?.requestedCompartmentTemperatureCelsius, range: -40...60),
                    driverSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowLeftSeat),
                    passengerSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowRightSeat),
                    steeringWheelHeatingLevel: timerSeatLevel(timerSettings?.steeringWheelHeatingIntensity),
                    rearLeftSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowLeftSeat),
                    rearRightSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowRightSeat),
                    sessionStartedAt: started,
                    sessionEndsAt: ends
                )
            }
            if let timerSettings, let reqTemp = portalValue(timerSettings.requestedCompartmentTemperatureCelsius, range: -40...60) {
                return VehicleClimateStatus(
                    activity: .idle,
                    timeRemainingMinutes: nil,
                    timerTriggered: false,
                    requestedTemperatureCelsius: reqTemp,
                    driverSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.frontRowLeftSeat),
                    passengerSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.frontRowRightSeat),
                    steeringWheelHeatingLevel: timerSeatLevel(timerSettings.steeringWheelHeatingIntensity),
                    rearLeftSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.rearRowLeftSeat),
                    rearRightSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.rearRowRightSeat)
                )
            }
            return nil
        }()

        let airQuality = bundle.preCleaning?.toVehicleAirQuality()
        let climateTimers = bundle.parkingClimateTimer?.toClimateSchedules(timeZone: timeZone, now: now) ?? []

        return VehicleState(
            energy: energy,
            identity: identity,
            maintenance: healthSnapshot,
            freshness: freshness,
            commandState: CommandPresentationState(),
            exteriorStatus: extSnapshot,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripComputer: tripComputer,
            airQuality: airQuality,
            weather: weather,
            location: bundle.location?.toVehicleLocation(),
            powertrain: .bev
        )
    }


}
