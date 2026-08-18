import Foundation

extension PolestarAPI {
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await fetchVehicleStateImplementation(vin: vin, features: features)
    }

    func fetchVehicleStateImplementation(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }

        await grpc.setUseStreaming(features.contains(.realTimeUpdates))

        let query = Self.telematicsQuery(features: features)
        let response: GraphQLResponse<TelematicsPayloadDTO>? = try? await graphQL(
            query: query,
            variables: ["vins": [vin]],
            token: token,
            operation: "vehicle telematics"
        )
        let telematics = response?.data?.carTelematicsV2

        let battery = Self.matchingReading(telematics?.battery, vin: vin, vinOf: { $0.vin })
        let odometer = Self.matchingReading(telematics?.odometer, vin: vin, vinOf: { $0.vin })
        let health = Self.matchingReading(telematics?.health, vin: vin, vinOf: { $0.vin })

        let serviceToken = accessToken ?? token

        let needsChargingContext = features.contains(.chargingDetails) || features.contains(.remoteCharging)
            || battery == nil
        let modelProfile = VehicleCapabilityProfile(modelName: modelName)
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
        // GetMyCars runs whenever softwareUpdates or remoteOTA is enabled — it provides the
        // authoritative installed version and OTA capability flags.
        async let myCarsTask: OptionalCapability<VehicleOTACapabilities> = optionalCapability(
            .softwareUpdates, key: "my-cars",
            enabled: features.contains(.softwareUpdates) || features.contains(.remoteOTA), vin: vin
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
            if features.contains(.softwareUpdates) { optionalResults.append((.softwareUpdates, software.unavailable)) }
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

        var state = VehicleState(
            batteryPercentage: batteryPercentage,
            rangeKm: range,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: Self.positive(minutes),
            chargeTargetPercentage: chargeTarget,
            chargingPowerWatts: needsChargingContext ? Self.positive(extras?.chargingPowerWatts) : nil,
            chargingCurrentAmps: needsChargingContext
                ? (Self.positive(extras?.chargingCurrentAmps) ?? ampLimit.value) : nil,
            chargingVoltageVolts: needsChargingContext ? Self.positive(extras?.chargingVoltageVolts) : nil,
            chargingType: needsChargingContext ? (extras?.chargingType ?? .unknown) : .unknown,
            chargerConnection: needsChargingContext ? (extras?.chargerConnection ?? .unknown) : .unknown,
            availability: vehicleAvailability,


            modelName: modelName,
            modelYear: features.contains(.vehicleIdentity) ? modelYear : nil,
            registrationNo: features.contains(.vehicleIdentity) ? registrationNo : nil,
            vin: vin,
            ownerFirstName: features.contains(.ownerGreeting) ? ownerFirstName : nil,
            odometerKm: (odometer?.odometerMeters?.value).map { $0 / 1_000 }
                ?? (features.contains(.vehicleHealth) ? trips.value?.odometerKm : nil),
            daysToService: health?.daysToService?.value ?? c3ServiceHealth?.daysToService,
            distanceToServiceKm: health?.distanceToServiceKm?.value ?? c3ServiceHealth?.distanceToServiceKm,
            serviceWarning: Self.hasWarning(health?.serviceWarning) || (c3ServiceHealth?.serviceWarning ?? false),
            fluidWarnings: Self.fluidWarnings(health),
            exteriorStatus: exterior.value,
            healthDetails: features.contains(.tyreAndWarnings) ? (c3Health.value?.details ?? VehicleHealthDetails(
                tyres: TyrePosition.allCases.map { TyrePressure(position: $0, kilopascals: nil, warning: .none) },
                warnings: []
            )) : nil,
            softwareInfo: software.value,
            chargingSchedules: schedules.value ?? [],
            climateStatus: climate.value,
            climateTimers: climateTimers.value ?? [],
            tripMeterManualKm: trips.value?.manualTripKm,
            tripMeterAutomaticKm: trips.value?.automaticTripKm,
            connectivity: connectivity.value,
            airQuality: air.value,
            batteryDiagnostics: features.contains(.batteryDiagnostics) ? extras?.diagnostics : nil,
            weather: features.contains(.vehicleWeather) ? weather.value : nil,
            location: features.contains(.vehicleLocation) ? location.value : nil,
            unavailableFeatures: unavailable,
            probedCapabilities: probes.count > 0 ? probes : nil,
            imageData: features.contains(.vehicleImage) ? carImageData : nil,
            fetchedAt: Date(),
            vehicleReportedAt: [primaryReportedAt, extras?.reportedAt].compactMap { $0 }.max(),
            dataWarnings: warnings
        )
        state.vehicleErrors = features.contains(.vehicleErrors) ? (serviceErrors.value ?? []) : []

        // Merge GetMyCars OTA capabilities: use the authoritative installed version from
        // GetMyCars when GetSoftwareInfo doesn't provide one (during a rollout, GetSoftwareInfo
        // only reports the target version, leaving installedVersion nil).
        if let otaCaps = otaCapabilities.value {
            state.otaCapabilities = otaCaps
            if var sw = state.softwareInfo, sw.installedVersion == nil,
               let installed = otaCaps.installedSoftwareVersion {
                sw.installedVersion = installed
                state.softwareInfo = sw
            }
        }
        state.structureWeek = features.contains(.vehicleIdentity) ? structureWeek : nil
        state.internalVehicleIdentifier = features.contains(.vehicleIdentity) ? internalVehicleIdentifier : nil
        state.pno34 = features.contains(.vehicleIdentity) ? pno34 : nil
        state.externalColour = features.contains(.vehicleIdentity) ? exteriorColorName : nil
        state.upholstery = features.contains(.vehicleIdentity) ? upholsteryName : nil
        state.wheels = features.contains(.vehicleIdentity) ? wheelsName : nil
        state.packages = features.contains(.vehicleIdentity) ? packageNames : []
        state.accountMarket = market
        state.interiorImageData = features.contains(.vehicleImage) ? imageCache.interiorImage(for: vin) : nil
        return state
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
