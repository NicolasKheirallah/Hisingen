import Foundation

struct PolestarConsumerSnapshotAssembler {
    let features: FeatureSelection
    let vin: String
    let carIdentity: PolestarAPI.CarIdentity
    let ownerFirstName: String?
    let market: String?
    let imageData: Data?
    let fetchedAt: Date
    let graphQLStartedAt: Date
    let servicesStartedAt: Date
    let targetObservation: VehicleReadingObservation?
    let hasGraphQLErrors: Bool
    let battery: BatteryDTO?
    let odometer: OdometerDTO?
    let health: HealthDTO?
    let extras: GrpcBatteryExtras?
    let availabilityReport: GrpcAvailabilityReport
    let chargeTarget: Int?
    /// Payload fields the charge-target read returned beyond the decoded field 1, retained
    /// raw for the diagnostics surface. Defaults keep test call sites valid.
    var targetSocRawFields: [VehicleRawWireField] = []
    let exterior: CapabilityState<ExteriorSnapshot>
    let c3Health: CapabilityState<GrpcHealthReport>
    let software: CapabilityState<VehicleSoftwareInfo>
    let schedules: CapabilityState<[VehicleSchedule]>
    let climate: CapabilityState<VehicleClimateStatus>
    let climateTimers: CapabilityState<[VehicleSchedule]>
    let trips: CapabilityState<GrpcOdometerReport>
    let connectivity: CapabilityState<VehicleConnectivity>
    let air: CapabilityState<VehicleAirQuality>
    let weather: CapabilityState<VehicleWeather>
    let location: CapabilityState<VehicleLocation>
    let ampLimit: CapabilityState<PCCSScalarRead>
    /// Payload fields the current-limit read returned beyond the decoded field 1.
    var ampLimitRawFields: [VehicleRawWireField] = []
    let chargeLocations: CapabilityState<[ChargeLocationSnapshot]>
    let otaCapabilities: CapabilityState<VehicleOTACapabilities>

    private var needsChargingContext: Bool { features.contains(.chargingDetails) || features.contains(.remoteCharging) || battery == nil }
    private var needsExterior: Bool { features.contains(.exteriorStatus) || features.contains(.remoteLocks) || features.contains(.remoteWindows) }
    private var needsSoftware: Bool { features.contains(.softwareUpdates) || features.contains(.remoteOTA) }
    private var needsSchedules: Bool { features.contains(.chargingSchedule) || features.contains(.remoteSchedules) }
    private var needsAirQuality: Bool {
        features.contains(.airQuality) || (features.contains(.remotePreCleaning) && VehicleCapabilityProfile(modelName: carIdentity.modelName).permits(.preCleaning))
    }

    func assemble() -> VehicleState {
        let primaryReportedAt = battery?.timestamp?.date
        let extrasAreNewer = extras?.reportedAt.map { reported in
            primaryReportedAt.map { reported > $0 } ?? true
        } ?? false
        let batteryPercentage = extrasAreNewer
            ? (extras?.batteryPercentage ?? battery?.batteryChargeLevelPercentage?.value)
            : (battery?.batteryChargeLevelPercentage?.value ?? extras?.batteryPercentage)
        let range = extrasAreNewer
            ? (extras?.rangeKm ?? battery?.estimatedDistanceToEmptyKm?.value)
            : (battery?.estimatedDistanceToEmptyKm?.value ?? extras?.rangeKm)
        let primaryChargingState = battery?.chargingStatusV2.map {
            ChargingState(apiValue: $0.value)
        }
        let chargingState = extrasAreNewer
            ? (extras?.chargingState ?? primaryChargingState ?? .unknown("UNSPECIFIED"))
            : (primaryChargingState ?? extras?.chargingState ?? .unknown("UNSPECIFIED"))
        let minutes = extrasAreNewer
            ? (extras?.estimatedChargingTimeToFullMinutes ?? battery?.estimatedChargingTimeToFullMinutes?.value)
            : (battery?.estimatedChargingTimeToFullMinutes?.value ?? extras?.estimatedChargingTimeToFullMinutes)

        var warnings: [String] = []
        if hasGraphQLErrors { warnings.append(L10n.text("Some API fields were unavailable")) }
        if battery == nil && extras == nil { warnings.append(L10n.text("Battery data was unavailable")) }

        var unavailable = SnapshotAssembly.UnavailableFeatures()
        unavailable.mark(.tyreAndWarnings, when: features.contains(.tyreAndWarnings) && c3Health.unavailable)
        unavailable.mark(.vehicleHealth, when: features.contains(.vehicleHealth) && health == nil && c3Health.unavailable)
        unavailable.mark(.tripMeters, when: trips.unavailable)
        unavailable.mark(.connectivityDiagnostics, when: connectivity.unavailable)
        unavailable.mark(.batteryDiagnostics, when: features.contains(.batteryDiagnostics) && extras == nil)
        if needsExterior {
            unavailable.mark(.exteriorStatus, when: features.contains(.exteriorStatus) && exterior.unavailable)
            unavailable.mark(.remoteLocks, when: features.contains(.remoteLocks) && exterior.unavailable)
            unavailable.mark(.remoteWindows, when: features.contains(.remoteWindows) && exterior.unavailable)
        }
        if needsSoftware {
            let hasInstalledVersion = otaCapabilities.value?.installedSoftwareVersion?.isEmpty == false
            unavailable.mark(.softwareUpdates,
                             when: features.contains(.softwareUpdates) && software.unavailable && !hasInstalledVersion)
            unavailable.mark(.remoteOTA, when: features.contains(.remoteOTA) && software.unavailable)
        }
        if needsSchedules {
            unavailable.mark(.chargingSchedule, when: features.contains(.chargingSchedule) && schedules.unavailable)
            unavailable.mark(.remoteSchedules, when: features.contains(.remoteSchedules) && schedules.unavailable)
        }
        unavailable.mark(.climateStatus, when: features.contains(.climateStatus) && climate.unavailable && climateTimers.unavailable)
        unavailable.mark(.remoteClimate, when: features.contains(.remoteClimate) && climate.unavailable)
        unavailable.mark(.remoteSchedules, when: features.contains(.remoteSchedules) && climateTimers.unavailable)
        if needsAirQuality {
            unavailable.mark(.airQuality, when: features.contains(.airQuality) && air.unavailable)
            unavailable.mark(.remotePreCleaning, when: features.contains(.remotePreCleaning) && air.unavailable)
        }
        unavailable.mark(.vehicleWeather, when: features.contains(.vehicleWeather) && weather.unavailable)
        let c3ServiceHealth = features.contains(.vehicleHealth) ? c3Health.value : nil
        var probes = VehicleProbedCapabilities()
        if exterior.value != nil { probes.record(.exteriorStatus, as: .supported) }
        if let health = c3Health.value {
            probes.record(.serviceWarnings, as: .supported)
            if health.details.tyres.contains(where: { $0.kilopascals != nil }) {
                probes.record(.tyrePressureValues, as: .supported)
            }
        }
        if software.value != nil { probes.record(.softwareStatus, as: .supported) }
        if schedules.value != nil { probes.record(.chargingSchedule, as: .supported) }
        if climateTimers.value != nil { probes.record(.climateTimers, as: .supported) }
        if trips.value != nil { probes.record(.tripMeters, as: .supported) }
        if connectivity.value != nil { probes.record(.connectivity, as: .supported) }
        else if connectivity.unsupported { probes.record(.connectivity, as: .unavailable) }
        if chargeTarget != nil { probes.record(.chargeTarget, as: .supported) }
        if ampLimit.value?.value != nil { probes.record(.chargingCurrentLimit, as: .supported) }
        if chargeLocations.value?.isEmpty == false { probes.record(.chargeLocations, as: .supported) }

        let healthDetails: VehicleHealthDetails? = {
            guard features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings) else { return nil }
            let details = c3Health.value?.details
            let graphFields: [(String?, VehicleWarning)] = [
                (health?.brakeFluidLevelWarning, .brakeFluid),
                (health?.engineCoolantLevelWarning, .engineCoolant),
                (health?.oilLevelWarning, .oil)
            ]
            let reported = graphFields.compactMap { raw, warning -> VehicleWarning? in
                guard let raw, !raw.contains("UNSPECIFIED") else { return nil }
                return warning
            }
            let active = graphFields.compactMap { raw, warning in PolestarAPI.hasWarning(raw) ? warning : nil }
            guard details != nil || !reported.isEmpty else { return nil }
            var warnings = details?.warnings ?? []
            var reportedWarnings = details?.reportedWarnings ?? []
            for warning in active where !warnings.contains(warning) { warnings.append(warning) }
            for warning in reported where !reportedWarnings.contains(warning) { reportedWarnings.append(warning) }
            return VehicleHealthDetails(
                tyres: details?.tyres ?? [],
                warnings: warnings,
                reportedWarnings: reportedWarnings,
                lightFailures: details?.lightFailures ?? []
            )
        }()

        let capacityKwh = PolestarAPI.resolvedBatteryCapacity(
            graphQL: battery?.reportedBatteryCapacityKwh?.value,
            batteryService: extras?.reportedBatteryCapacityKwh,
            equipment: otaCapabilities.value?.equipment
        )

        var state = VehicleState(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: batteryPercentage,
                rangeKm: range,
                chargingState: chargingState,
                // The verdict rides on the GraphQL token. The C3 extras path keeps only the
                // collapsed state, so it reports no verdict rather than guessing one.
                scheduleOutcome: extrasAreNewer
                    ? nil
                    : ChargingScheduleOutcome(apiValue: battery?.chargingStatusV2?.value),
                estimatedTimeToFullMinutes: PolestarAPI.positive(minutes),
                targetPercentage: chargeTarget,
                powerWatts: needsChargingContext ? PolestarAPI.positive(extras?.chargingPowerWatts) : nil,
                currentAmps: needsChargingContext ? PolestarAPI.positive(extras?.chargingCurrentAmps) : nil,
                voltageVolts: needsChargingContext ? PolestarAPI.positive(extras?.chargingVoltageVolts) : nil,
                type: needsChargingContext ? (extras?.chargingType ?? .unknown) : .unknown,
                connection: needsChargingContext ? (extras?.chargerConnection ?? .unknown) : .unknown,
                diagnostics: features.contains(.batteryDiagnostics)
                    ? extras.map { diag -> BatteryDiagnostics in
                        var enriched = diag.diagnostics
                        enriched.unknownWireFields = diag.unknownFields
                        return enriched
                    } : nil,
                schedules: schedules.value ?? []
            ),
            identity: VehicleIdentitySnapshot(
                availability: availabilityReport.availability,
                availabilityReportedAt: availabilityReport.reportedAt,
                availabilityUnknownWireFields: availabilityReport.unknownFields.isEmpty
                    ? nil : availabilityReport.unknownFields,
                modelName: carIdentity.modelName ?? otaCapabilities.value?.identity?.modelName,
                modelYear: features.contains(.vehicleIdentity)
                    ? (carIdentity.modelYear ?? otaCapabilities.value?.identity?.modelYear) : nil,
                registrationNo: features.contains(.vehicleIdentity) ? carIdentity.registrationNo : nil,
                vin: vin,
                ownerFirstName: features.contains(.ownerGreeting) ? ownerFirstName : nil,
                imageData: features.contains(.vehicleImage) ? imageData : nil,
                usageMode: availabilityReport.usageMode
            ),
            maintenance: MaintenanceAndHealthSnapshot(
                odometerKm: (odometer?.odometerMeters?.value).map { $0 / 1_000 }
                    ?? (features.contains(.vehicleHealth) ? trips.value?.odometerKm : nil),
                // GraphQL rounds to whole kilometres; C3 carries the metre reading. Keep the
                // fraction when either source has it so the odometer and distance-to-service
                // rows agree with the car.
                odometerKmPrecise: (odometer?.odometerMeters?.value).map { Double($0) / 1_000 }
                    ?? (features.contains(.vehicleHealth) ? trips.value?.odometerKmPrecise : nil),
                details: healthDetails,
                service: ServiceSnapshot(
                    daysToService: health?.daysToService?.value ?? c3ServiceHealth?.daysToService,
                    distanceToServiceKm: health?.distanceToServiceKm?.value ?? c3ServiceHealth?.distanceToServiceKm,
                    serviceWarning: PolestarAPI.hasWarning(health?.serviceWarning) || (c3ServiceHealth?.serviceWarning ?? false),
                    fluidWarnings: PolestarAPI.fluidWarnings(health)
                )
            ),
            freshness: SnapshotFreshness(
                fetchedAt: fetchedAt,
                vehicleReportedAt: [primaryReportedAt, extras?.reportedAt].compactMap { $0 }.max(),
                dataWarnings: warnings,
                unavailableFeatures: unavailable.features
            ),
            exteriorStatus: exterior.value,
            softwareInfo: software.value,
            climateStatus: climate.value,
            climateTimers: climateTimers.value ?? [],
            tripComputer: TripComputerSnapshot(
                manualTripKm: trips.value?.manualTripKm,
                automaticTripKm: trips.value?.automaticTripKm
            ),
            connectivity: connectivity.value,
            airQuality: air.value,
            weather: features.contains(.vehicleWeather) ? weather.value : nil,
            location: features.contains(.vehicleLocation) ? location.value : nil,
            probedCapabilities: probes.count > 0 ? probes : nil,
            otaCapabilities: otaCapabilities.value
        )
        state.energy.reportedBatteryCapacityKwh = capacityKwh
        state.energy.estimatedTimeToTargetMinutes = extras?.diagnostics.timeToTargetMinutes
        func batteryDate(primaryPresent: Bool, secondaryPresent: Bool) -> Date? {
            let usesSecondary = extrasAreNewer ? secondaryPresent : !primaryPresent && secondaryPresent
            return usesSecondary ? extras?.reportedAt : primaryPresent ? primaryReportedAt : nil
        }
        state.freshness.readingDates[.battery] = batteryDate(primaryPresent: battery?.batteryChargeLevelPercentage != nil,
                                                  secondaryPresent: extras?.batteryPercentage != nil)
        state.freshness.readingDates[.range] = batteryDate(primaryPresent: battery?.estimatedDistanceToEmptyKm != nil,
                                                secondaryPresent: extras?.rangeKm != nil)
        state.freshness.readingDates[.charging] = batteryDate(primaryPresent: primaryChargingState != nil,
                                                   secondaryPresent: extras?.chargingState != nil)
        // ParkingClimatization has no vehicle timestamp. A successful response is still a
        // fresh observation from the dedicated status endpoint, so timestamp the read itself.
        state.freshness.readingDates[.climateStatus] = climate.value == nil
            ? nil
            : state.freshness.fetchedAt
        state.freshness.readingDates[.locks] = exterior.value?.isLocked != nil ? exterior.value?.reportedAt : nil
        state.freshness.readingDates[.openings] = exterior.value?.reportedAt
        state.freshness.readingDates[.health] = c3Health.value?.reportedAt ?? health?.timestamp?.date
        state.freshness.readingDates[.odometer] = odometer?.odometerMeters != nil ? odometer?.timestamp?.date : trips.value?.reportedAt
        // Odometer average speeds arrive per trip period, with explicit km/h units; keep
        // them out of the blended `averageSpeedKmH` (Volvo statistics) so sources never
        // overwrite each other.
        state.tripComputer.manualAverageSpeedKmH = trips.value?.manualAverageSpeedKmH
        state.tripComputer.automaticAverageSpeedKmH = trips.value?.automaticAverageSpeedKmH
        // Since-charge trip computer values come from the same C3 odometer frame. The domain
        // and Info rows already exist; only the decoder was missing.
        state.tripComputer.sinceChargeTripKm = trips.value?.sinceChargeTripKm
        state.tripComputer.sinceChargeAverageSpeedKmH = trips.value?.sinceChargeAverageSpeedKmH
        // Engine hours to service is a real service-interval input (upstream Health field 2),
        // distinct from the GraphQL-engineHours Volvo path; GraphQL keeps precedence.
        if let engineHours = c3Health.value?.engineHoursToService, state.maintenance.service.engineHoursToService == nil {
            state.maintenance.service.engineHoursToService = engineHours
        }

        if needsSoftware {
            state.softwareInfo = PolestarAPI.mergingSoftwareInfo(software.value, myCars: otaCapabilities.value)
            // `fetchSoftware` reports `noUpdateAvailable` when the read succeeds with no
            // pending update. On a car that does not advertise update status at all, that
            // becomes a false all-clear; mark it instead of guessing.
            if let ota = otaCapabilities.value, ota.supportsUpdateStatus == false {
                if state.softwareInfo == nil {
                    state.softwareInfo = VehicleSoftwareInfo(statusNotReported: true)
                } else if state.softwareInfo?.noUpdateAvailable == true {
                    state.softwareInfo?.noUpdateAvailable = nil
                    state.softwareInfo?.statusNotReported = true
                }
            }
        }
        state.identity.structureWeek = features.contains(.vehicleIdentity) ? carIdentity.structureWeek : nil
        state.identity.internalVehicleIdentifier = features.contains(.vehicleIdentity) ? carIdentity.internalVehicleIdentifier : nil
        state.identity.pno34 = features.contains(.vehicleIdentity) ? carIdentity.pno34 : nil
        state.identity.accountMarket = market
        state.energy.currentLimitAmps = ampLimit.value?.value
        state.energy.locations = chargeLocations.value ?? []
        let graphObservation = VehicleReadingObservation(fetchedAt: graphQLStartedAt, source: .polestarGraphQL)
        let batteryObservation = VehicleReadingObservation(fetchedAt: servicesStartedAt, source: .polestarGRPC)
        func energyObservation(primary: Bool, secondary: Bool) -> VehicleReadingObservation? {
            if extrasAreNewer, secondary { return batteryObservation }
            if primary { return graphObservation }
            return secondary ? batteryObservation : nil
        }
        var observations: [VehicleReading: VehicleReadingObservation] = [:]
        observations[.battery] = energyObservation(primary: battery?.batteryChargeLevelPercentage != nil, secondary: extras?.batteryPercentage != nil)
        observations[.range] = energyObservation(primary: battery?.estimatedDistanceToEmptyKm != nil, secondary: extras?.rangeKm != nil)
        observations[.charging] = energyObservation(primary: primaryChargingState != nil, secondary: extras?.chargingState != nil)
        if exterior.value?.isLocked != nil { observations[.locks] = exterior.observation }
        if exterior.value?.openings.isEmpty == false { observations[.openings] = exterior.observation }
        if climate.value != nil { observations[.climateStatus] = climate.observation }
        if air.value != nil { observations[.airQuality] = air.observation }
        if software.value != nil { observations[.software] = software.observation }
        if connectivity.value != nil { observations[.connectivity] = connectivity.observation }
        if location.value != nil { observations[.location] = location.observation }
        observations[.health] = health == nil ? c3Health.observation : graphObservation
        observations[.odometer] = odometer == nil ? trips.observation : graphObservation
        if case .unknown = availabilityReport.availability {} else { observations[.availability] = batteryObservation }
        state.freshness.readingObservations = observations
        var commandObservations: [CommandDisplayField: VehicleReadingObservation] = [:]
        if chargeTarget != nil { commandObservations[.chargeTarget] = targetObservation }
        if ampLimit.value?.value != nil { commandObservations[.chargingCurrentLimit] = ampLimit.observation }
        // PCCS scalar reads keep unconsumed payload fields raw so a new backend field is
        // visible in diagnostics instead of dropped.
        state.energy.targetSocUnknownFields = targetSocRawFields.isEmpty ? nil : targetSocRawFields
        state.energy.ampLimitUnknownFields = ampLimitRawFields.isEmpty ? nil : ampLimitRawFields
        state.freshness.commandObservations = commandObservations
        return state
    }
}
