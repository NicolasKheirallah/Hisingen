import Foundation

extension PolestarAPI {
    func prepareVehicle(vin: String, features: FeatureSelection) async throws {
        try await refreshTokenIfNeeded()
        let epoch = sessionEpoch
        try await applyCarInfo(vin: vin)
        try Task.checkCancellation()
        guard sessionEpoch == epoch else { throw CancellationError() }
        if features.contains(.vehicleImage) {
            let angle = await MainActor.run { preferences.carRenderAngle.rawValue }
            let previous = imagePreparationAttempts[vin]
            if previous?.angle != angle || (previous?.retryAt ?? .distantPast) <= Date() {
                await fetchCarImage(vin: vin)
                try Task.checkCancellation()
                guard sessionEpoch == epoch else { throw CancellationError() }
                // Missing artwork may be transient; retry without querying metadata on every frame.
                let retryAt = carImages[vin] == nil ? Date().addingTimeInterval(300) : Date.distantFuture
                imagePreparationAttempts[vin] = (angle, retryAt)
            }
        }
        if features.contains(.ownerGreeting), !ownerInfoPrepared {
            if ownerFirstName == nil { await fetchOwnerInfo() }
            try Task.checkCancellation()
            guard sessionEpoch == epoch else { throw CancellationError() }
            ownerInfoPrepared = true
        }
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await fetchVehicleStateImplementation(vin: vin, features: features)
    }

    func fetchVehicleStateImplementation(vin: String, features: FeatureSelection) async throws -> VehicleState {
        let epoch = sessionEpoch
        try await prepareVehicle(vin: vin, features: features)
        try requireSession(epoch)
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }

        await grpc.setUseStreaming(features.contains(.realTimeUpdates))

        // All identity reads are scoped to the VIN being fetched. A background garage scan
        // selecting another vehicle concurrently can no longer leak its model name, plate,
        // or render image into this snapshot.
        let carIdentity = identities[vin] ?? .empty

        let query = Self.telematicsQuery(features: features)
        // Same rule as discovery: only provider-specific failures may degrade to "no
        // telematics data". A swallowed 401 here used to produce an empty-looking state
        // instead of a sign-in prompt, and a swallowed 429 looked like a dead battery read.
        let response: GraphQLResponse<TelematicsPayloadDTO>?
        do {
            response = try await graphQL(
                query: query,
                variables: ["vins": [vin]],
                token: token,
                operation: "vehicle telematics"
            )
        } catch {
            if Self.isRequestLevelFailure(error) { throw error }
            logger.warning("Polestar vehicle telematics degraded (provider-specific): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            response = nil
        }
        let telematics = response?.data?.carTelematicsV2

        let battery = Self.matchingReading(telematics?.battery, vin: vin, vinOf: { $0.vin })
        let odometer = Self.matchingReading(telematics?.odometer, vin: vin, vinOf: { $0.vin })
        let health = Self.matchingReading(telematics?.health, vin: vin, vinOf: { $0.vin })

        let serviceToken = accessToken ?? token

        let needsChargingContext = features.contains(.chargingDetails) || features.contains(.remoteCharging)
            || battery == nil
        let modelProfile = VehicleCapabilityProfile(modelName: carIdentity.modelName)
        let needsExterior = features.contains(.exteriorStatus) || features.contains(.remoteLocks)
            || features.contains(.remoteWindows)
        let needsSoftware = features.contains(.softwareUpdates) || features.contains(.remoteOTA)
        let needsSchedules = features.contains(.chargingSchedule) || features.contains(.remoteSchedules)
        let needsClimate = features.contains(.climateStatus) || features.contains(.remoteClimate)
        let needsClimateTimers = features.contains(.climateStatus) || features.contains(.remoteSchedules)
        let needsAirQuality = features.contains(.airQuality)
            || (features.contains(.remotePreCleaning) && modelProfile.permits(.preCleaning))

        async let batteryExtrasTask = optionalBattery(
            enabled: needsChargingContext || features.contains(.batteryDiagnostics) || battery == nil,
            vin: vin, token: serviceToken
        )
        async let availabilityTask = optionalAvailability(
            enabled: features.contains(.vehicleAvailability), vin: vin, token: serviceToken
        )
        async let targetTask = targetSOC(
            enabled: needsChargingContext, vin: vin, token: serviceToken
        )
        async let exteriorTask: OptionalCapability<ExteriorSnapshot> = optionalCapability(
            features.contains(.exteriorStatus) ? .exteriorStatus : .remoteLocks,
            enabled: needsExterior, vin: vin
        ) { try await self.grpc.fetchExterior(vin: vin, accessToken: serviceToken) }
        async let healthTask: OptionalCapability<GrpcHealthReport> = optionalCapability(
            .tyreAndWarnings,
            enabled: features.contains(.tyreAndWarnings) || features.contains(.vehicleHealth), vin: vin
        ) { try await self.grpc.fetchHealth(vin: vin, accessToken: serviceToken) }
        async let softwareTask: OptionalCapability<VehicleSoftwareInfo> = optionalCapability(
            features.contains(.softwareUpdates) ? .softwareUpdates : .remoteOTA,
            enabled: needsSoftware, vin: vin
        ) {
            try await self.grpc.fetchSoftware(vin: vin, accessToken: serviceToken,
                                               locale: preferences.interfaceLanguage.effectiveLanguageCode)
        }
        async let scheduleTask: OptionalCapability<[VehicleSchedule]> = optionalCapability(
            features.contains(.chargingSchedule) ? .chargingSchedule : .remoteSchedules,
            enabled: needsSchedules, vin: vin
        ) { Optional(try await self.grpc.fetchChargingSchedules(vin: vin, accessToken: serviceToken)) }
        async let climateTask: OptionalCapability<VehicleClimateStatus> = optionalCapability(
            features.contains(.climateStatus) ? .climateStatus : .remoteClimate,
            key: "climate-status", enabled: needsClimate, vin: vin
        ) { try await self.grpc.fetchClimate(vin: vin, accessToken: serviceToken) }
        async let climateTimersTask: OptionalCapability<[VehicleSchedule]> = optionalCapability(
            features.contains(.climateStatus) ? .climateStatus : .remoteSchedules,
            key: "climate-timers", enabled: needsClimateTimers, vin: vin
        ) { Optional(try await self.grpc.fetchClimateTimers(vin: vin, accessToken: serviceToken)) }
        async let tripsTask: OptionalCapability<GrpcOdometerReport> = optionalCapability(
            .tripMeters, enabled: features.contains(.tripMeters), vin: vin
        ) { try await self.grpc.fetchOdometer(vin: vin, accessToken: serviceToken) }
        async let connectivityTask: OptionalCapability<VehicleConnectivity> = optionalCapability(
            .connectivityDiagnostics,
            enabled: features.contains(.connectivityDiagnostics) && modelProfile.permits(.connectivity),
            vin: vin
        ) { try await self.grpc.fetchConnectivity(vin: vin, accessToken: serviceToken) }
        async let airTask: OptionalCapability<VehicleAirQuality> = optionalCapability(
            features.contains(.airQuality) ? .airQuality : .remotePreCleaning,
            enabled: needsAirQuality, vin: vin
        ) { try await self.grpc.fetchAirQuality(vin: vin, accessToken: serviceToken) }
        async let weatherTask: OptionalCapability<VehicleWeather> = optionalCapability(
            .vehicleWeather, enabled: features.contains(.vehicleWeather), vin: vin
        ) { try await self.grpc.fetchWeather(vin: vin, accessToken: serviceToken) }
        async let locationTask: OptionalCapability<VehicleLocation> = optionalCapability(
            .vehicleLocation, enabled: features.contains(.vehicleLocation), vin: vin
        ) { try await self.grpc.fetchLocation(vin: vin, accessToken: serviceToken) }
        async let ampLimitTask: OptionalCapability<Int> = optionalCapability(
            .chargingDetails, key: "amp-limit",
            enabled: needsChargingContext && modelProfile.permits(.chargingCurrentLimit), vin: vin
        ) { try await self.grpc.fetchAmpLimit(vin: vin, accessToken: serviceToken) }
        async let errorsTask: OptionalCapability<[VehicleChronosError]> = optionalCapability(
            .vehicleErrors, enabled: features.contains(.vehicleErrors), vin: vin
        ) { try await self.grpc.fetchErrors(vin: vin, accessToken: serviceToken) }
        async let chargeLocationsTask: OptionalCapability<[ChargeLocationSnapshot]> = optionalCapability(
            .chargingSchedule, key: "charge-locations", enabled: needsSchedules, vin: vin
        ) { try await self.grpc.fetchChargeLocations(vin: vin, accessToken: serviceToken) }
        // MyCars supplies identity fallbacks and the installed version independently of OTA discovery.
        async let myCarsTask: OptionalCapability<VehicleOTACapabilities> = optionalCapability(
            .softwareUpdates, key: "my-cars",
            enabled: features.contains(.softwareUpdates) || features.contains(.remoteOTA) || features.contains(.vehicleIdentity), vin: vin
        ) { try await self.grpc.fetchMyCars(vin: vin, accessToken: serviceToken) }

        let extras = try await batteryExtrasTask
        let vehicleAvailability = try await availabilityTask
        let chargeTarget = try await targetTask
        let exterior = try await exteriorTask
        let c3Health = try await healthTask
        let software = try await softwareTask
        let schedules = try await scheduleTask
        let climate = try await climateTask
        let climateTimers = try await climateTimersTask
        let trips = try await tripsTask
        let connectivity = try await connectivityTask
        let air = try await airTask
        let weather = try await weatherTask
        let location = try await locationTask
        let ampLimit = try await ampLimitTask
        let serviceErrors = try await errorsTask
        let chargeLocations = try await chargeLocationsTask
        let otaCapabilities = try await myCarsTask

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
        if response?.errors?.isEmpty == false { warnings.append(L10n.text("Some API fields were unavailable")) }
        if battery == nil && extras == nil { warnings.append(L10n.text("Battery data was unavailable")) }

        var optionalResults: [(AppFeature, Bool)] = [
            (.tyreAndWarnings, features.contains(.tyreAndWarnings) && c3Health.unavailable),


            (.vehicleHealth, features.contains(.vehicleHealth) && health == nil && c3Health.unavailable),
            (.tripMeters, trips.unavailable), (.connectivityDiagnostics, connectivity.unavailable),
            (.batteryDiagnostics, features.contains(.batteryDiagnostics) && extras == nil)
        ]
        if needsExterior {
            if features.contains(.exteriorStatus) { optionalResults.append((.exteriorStatus, exterior.unavailable)) }
            if features.contains(.remoteLocks) { optionalResults.append((.remoteLocks, exterior.unavailable)) }
            if features.contains(.remoteWindows) { optionalResults.append((.remoteWindows, exterior.unavailable)) }
        }
        if needsSoftware {
            let hasInstalledVersion = otaCapabilities.value?.installedSoftwareVersion?.isEmpty == false
            if features.contains(.softwareUpdates) { optionalResults.append((.softwareUpdates, software.unavailable && !hasInstalledVersion)) }
            if features.contains(.remoteOTA) { optionalResults.append((.remoteOTA, software.unavailable)) }
        }
        if needsSchedules {
            if features.contains(.chargingSchedule) { optionalResults.append((.chargingSchedule, schedules.unavailable)) }
            if features.contains(.remoteSchedules) { optionalResults.append((.remoteSchedules, schedules.unavailable)) }
        }
        if features.contains(.climateStatus) {
            optionalResults.append((.climateStatus, climate.unavailable && climateTimers.unavailable))
        }
        if features.contains(.remoteClimate) { optionalResults.append((.remoteClimate, climate.unavailable)) }
        if features.contains(.remoteSchedules) { optionalResults.append((.remoteSchedules, climateTimers.unavailable)) }
        if needsAirQuality {
            if features.contains(.airQuality) { optionalResults.append((.airQuality, air.unavailable)) }
            if features.contains(.remotePreCleaning) { optionalResults.append((.remotePreCleaning, air.unavailable)) }
        }
        if features.contains(.vehicleWeather) { optionalResults.append((.vehicleWeather, weather.unavailable)) }
        if features.contains(.vehicleErrors) { optionalResults.append((.vehicleErrors, serviceErrors.unavailable)) }
        var seenUnavailable = Set<AppFeature>()
        let unavailable = optionalResults.compactMap { feature, failed in
            failed && seenUnavailable.insert(feature).inserted ? feature : nil
        }
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
        if chargeTarget != nil { probes.record(.chargeTarget, as: .supported) }
        if ampLimit.value != nil { probes.record(.chargingCurrentLimit, as: .supported) }
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
            let active = graphFields.compactMap { raw, warning in Self.hasWarning(raw) ? warning : nil }
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

        let capacityKwh = [battery?.reportedBatteryCapacityKwh?.value, extras?.reportedBatteryCapacityKwh]
            .compactMap { $0 }
            .first { $0 > 0 }

        var state = VehicleState(
            batteryPercentage: batteryPercentage,
            rangeKm: range,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: Self.positive(minutes),
            chargeTargetPercentage: chargeTarget,
            chargingPowerWatts: needsChargingContext ? Self.positive(extras?.chargingPowerWatts) : nil,
            chargingCurrentAmps: needsChargingContext
                ? Self.positive(extras?.chargingCurrentAmps) : nil,
            chargingVoltageVolts: needsChargingContext ? Self.positive(extras?.chargingVoltageVolts) : nil,
            chargingType: needsChargingContext ? (extras?.chargingType ?? .unknown) : .unknown,
            chargerConnection: needsChargingContext ? (extras?.chargerConnection ?? .unknown) : .unknown,
            availability: vehicleAvailability,


            modelName: carIdentity.modelName ?? otaCapabilities.value?.identity?.modelName,
            modelYear: features.contains(.vehicleIdentity) ? (carIdentity.modelYear ?? otaCapabilities.value?.identity?.modelYear) : nil,
            registrationNo: features.contains(.vehicleIdentity) ? carIdentity.registrationNo : nil,
            vin: vin,
            ownerFirstName: features.contains(.ownerGreeting) ? ownerFirstName : nil,
            odometerKm: (odometer?.odometerMeters?.value).map { $0 / 1_000 }
                ?? (features.contains(.vehicleHealth) ? trips.value?.odometerKm : nil),
            daysToService: health?.daysToService?.value ?? c3ServiceHealth?.daysToService,
            distanceToServiceKm: health?.distanceToServiceKm?.value ?? c3ServiceHealth?.distanceToServiceKm,
            serviceWarning: Self.hasWarning(health?.serviceWarning) || (c3ServiceHealth?.serviceWarning ?? false),
            fluidWarnings: Self.fluidWarnings(health),
            exteriorStatus: exterior.value,
            healthDetails: healthDetails,
            softwareInfo: software.value,
            chargingSchedules: schedules.value ?? [],
            climateStatus: climate.value,
            climateTimers: climateTimers.value ?? [],
            tripMeterManualKm: trips.value?.manualTripKm,
            tripMeterAutomaticKm: trips.value?.automaticTripKm,
            connectivity: connectivity.value,
            airQuality: air.value,
            batteryDiagnostics: features.contains(.batteryDiagnostics)
                ? extras.map { diag -> BatteryDiagnostics in
                    var enriched = diag.diagnostics
                    enriched.unknownWireFields = diag.unknownFields
                    return enriched
                } : nil,
            weather: features.contains(.vehicleWeather) ? weather.value : nil,
            location: features.contains(.vehicleLocation) ? location.value : nil,
            unavailableFeatures: unavailable,
            probedCapabilities: probes.count > 0 ? probes : nil,
            imageData: features.contains(.vehicleImage) ? carImages[vin] : nil,
            fetchedAt: Date(),
            vehicleReportedAt: [primaryReportedAt, extras?.reportedAt].compactMap { $0 }.max(),
            dataWarnings: warnings
        )
        state.reportedBatteryCapacityKwh = capacityKwh
        state.vehicleErrors = features.contains(.vehicleErrors) ? (serviceErrors.value ?? []) : []
        // Odometer average speeds arrive per trip period, with explicit km/h units; keep
        // them out of the blended `averageSpeedKmH` (Volvo statistics) so sources never
        // overwrite each other.
        state.tripComputer.manualAverageSpeedKmH = trips.value?.manualAverageSpeedKmH
        state.tripComputer.automaticAverageSpeedKmH = trips.value?.automaticAverageSpeedKmH
        // Engine hours to service is a real service-interval input (upstream Health field 2),
        // distinct from the GraphQL-engineHours Volvo path; GraphQL keeps precedence.
        if let engineHours = c3Health.value?.engineHoursToService, state.engineHoursToService == nil {
            state.engineHoursToService = engineHours
        }

        state.otaCapabilities = otaCapabilities.value
        if needsSoftware {
            state.softwareInfo = Self.mergingSoftwareInfo(software.value, myCars: otaCapabilities.value)
        }
        state.structureWeek = features.contains(.vehicleIdentity) ? carIdentity.structureWeek : nil
        state.internalVehicleIdentifier = features.contains(.vehicleIdentity) ? carIdentity.internalVehicleIdentifier : nil
        state.pno34 = features.contains(.vehicleIdentity) ? carIdentity.pno34 : nil
        state.externalColour = features.contains(.vehicleIdentity) ? carIdentity.exteriorColorName : nil
        state.upholstery = features.contains(.vehicleIdentity) ? carIdentity.upholsteryName : nil
        state.wheels = features.contains(.vehicleIdentity) ? carIdentity.wheelsName : nil
        state.packages = features.contains(.vehicleIdentity) ? carIdentity.packageNames : []
        state.accountMarket = market
        state.chargingCurrentLimitAmps = ampLimit.value
        state.chargeLocations = chargeLocations.value ?? []
        state.interiorImageData = features.contains(.vehicleImage) ? imageCache.interiorImage(for: vin) : nil
        try requireSession(epoch)
        return state
    }

    static func mergingSoftwareInfo(_ ota: VehicleSoftwareInfo?, myCars: VehicleOTACapabilities?) -> VehicleSoftwareInfo? {
        guard let installed = myCars?.installedSoftwareVersion, !installed.isEmpty else { return ota }
        var software = ota ?? VehicleSoftwareInfo()
        software.installedVersion = installed
        return software
    }

    static func telematicsQuery(features: FeatureSelection) -> String {
        let odometerSelection = features.contains(.vehicleHealth)
            ? "odometer { vin odometerMeters timestamp { seconds } }" : ""
        let healthSelection = features.contains(.vehicleHealth) ? """
            health {
              vin daysToService distanceToServiceKm serviceWarning
              brakeFluidLevelWarning engineCoolantLevelWarning oilLevelWarning
              timestamp { seconds }
            }
            """ : ""
        return """
        query CarTelematicsV2($vins: [String!]!) {
          carTelematicsV2(vins: $vins) {
            battery {
              vin batteryChargeLevelPercentage estimatedDistanceToEmptyKm
              chargingStatusV2 estimatedChargingTimeToFullMinutes
              reportedBatteryCapacityKwh
              timestamp { seconds }
            }
            \(odometerSelection)
            \(healthSelection)
          }
        }
        """
    }

    static func matchingReading<Value>(
        _ values: [Value]?,
        vin: String,
        vinOf: (Value) -> String?
    ) -> Value? {
        guard let values else { return nil }
        if let exact = values.first(where: { vinOf($0) == vin }) { return exact }


        guard values.count == 1, let only = values.first, vinOf(only) == nil else { return nil }
        return only
    }


}
