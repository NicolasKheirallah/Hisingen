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
            if previous?.angle != angle || (previous?.retryAt ?? .distantPast) <= now() {
                await fetchCarImage(vin: vin)
                try Task.checkCancellation()
                guard sessionEpoch == epoch else { throw CancellationError() }
                // Missing artwork may be transient; retry without querying metadata on every frame.
                let retryAt = carImages[vin] == nil ? now().addingTimeInterval(300) : Date.distantFuture
                imagePreparationAttempts[vin] = (angle, retryAt)
            }
        }
        if features.contains(.ownerGreeting), !ownerInfoPrepared,
           (ownerInfoRetryAt ?? .distantPast) <= now() {
            if ownerFirstName == nil { await fetchOwnerInfo() }
            try Task.checkCancellation()
            guard sessionEpoch == epoch else { throw CancellationError() }
            ownerInfoPrepared = ownerFirstName != nil
            ownerInfoRetryAt = ownerInfoPrepared ? nil : now().addingTimeInterval(300)
        }
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await fetchVehicleStateImplementation(vin: vin, features: features)
    }

    /// No telemetry fetch: identity is prepared by `prepareVehicle`/`reloadVehicleMetadata`
    /// and read from actor state here, so the augmented provider can overlay consumer-only
    /// metadata onto portal-served refreshes without a consumer round trip. `availability`
    /// is a placeholder the overlay never copies — the portal owns that fact.
    func identitySnapshot(for vin: String, features: FeatureSelection) -> VehicleIdentitySnapshot? {
        guard let identity = identities[vin] else { return nil }
        return VehicleIdentitySnapshot(
            availability: .available,
            modelName: identity.modelName,
            modelYear: features.contains(.vehicleIdentity) ? identity.modelYear : nil,
            registrationNo: features.contains(.vehicleIdentity) ? identity.registrationNo : nil,
            vin: vin,
            ownerFirstName: features.contains(.ownerGreeting) ? ownerFirstName : nil,
            structureWeek: features.contains(.vehicleIdentity) ? identity.structureWeek : nil,
            internalVehicleIdentifier: features.contains(.vehicleIdentity) ? identity.internalVehicleIdentifier : nil,
            pno34: features.contains(.vehicleIdentity) ? identity.pno34 : nil,
            accountMarket: market,
            imageData: features.contains(.vehicleImage) ? carImages[vin] : nil
        )
    }

    func fetchVehicleStateImplementation(vin: String, features: FeatureSelection) async throws -> VehicleState {
        let epoch = sessionEpoch
        try await prepareVehicle(vin: vin, features: features)
        try requireSession(epoch)
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }

        // All identity reads are scoped to the VIN being fetched. A background garage scan
        // selecting another vehicle concurrently can no longer leak its model name, plate,
        // or render image into this snapshot.
        let carIdentity = identities[vin] ?? .empty

        let query = Self.telematicsQuery(features: features)
        // Same rule as discovery: only provider-specific failures may degrade to "no
        // telematics data". A swallowed 401 here used to produce an empty-looking state
        // instead of a sign-in prompt, and a swallowed 429 looked like a dead battery read.
        let graphQLStartedAt = now()
        let response: GraphQLResponse<TelematicsPayloadDTO>?
        do {
            response = try await graphQL(
                query: query,
                variables: VINListVariables(vins: [vin]),
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

        // Discovery may need to retry a 406 with the other grant, and only this actor holds
        // both. Idempotent and cheap.
        await installAlternateAccessTokenProviderIfNeeded()

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
        // Confirmation selections contain only remote-command features. They must hit the
        // backend on every three-second poll; the normal 15–90 second capability caches
        // would otherwise keep returning the pre-command value with a fresh local timestamp.
        let bypassCommandCaches = !features.enabled.isEmpty
            && features.enabled.isSubset(of: AppFeature.remoteFeatures)

        let servicesStartedAt = now()
        async let batteryExtrasTask = optionalBattery(
            enabled: needsChargingContext || features.contains(.batteryDiagnostics) || battery == nil,
            vin: vin, token: serviceToken
        )
        async let availabilityTask = optionalAvailability(
            enabled: features.contains(.vehicleAvailability), vin: vin, token: serviceToken
        )
        async let targetTask: CapabilityState<PCCSScalarRead> = optionalCapability(
            .targetSOC, enabled: needsChargingContext, vin: vin,
            bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchTargetSoc(vin: vin, accessToken: serviceToken) }
        async let exteriorTask: CapabilityState<ExteriorSnapshot> = optionalCapability(
            .exterior,
            enabled: needsExterior, vin: vin, bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchExterior(vin: vin, accessToken: serviceToken) }
        async let healthTask: CapabilityState<GrpcHealthReport> = optionalCapability(
            .health,
            enabled: features.contains(.tyreAndWarnings) || features.contains(.vehicleHealth), vin: vin
        ) { try await self.grpc.fetchHealth(vin: vin, accessToken: serviceToken) }
        async let softwareTask: CapabilityState<VehicleSoftwareInfo> = optionalCapability(
            .software,
            enabled: needsSoftware, vin: vin, bypassCache: bypassCommandCaches
        ) {
            try await self.grpc.fetchSoftware(vin: vin, accessToken: serviceToken,
                                               locale: self.preferences.interfaceLanguage.effectiveLanguageCode)
        }
        async let scheduleTask: CapabilityState<[VehicleSchedule]> = optionalCapability(
            .schedules,
            enabled: needsSchedules, vin: vin, bypassCache: bypassCommandCaches
        ) { Optional(try await self.grpc.fetchChargingSchedules(vin: vin, accessToken: serviceToken)) }
        async let climateTask: CapabilityState<VehicleClimateStatus> = optionalCapability(
            .climate, enabled: needsClimate, vin: vin,
            bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchClimate(vin: vin, accessToken: serviceToken) }
        async let climateTimersTask: CapabilityState<[VehicleSchedule]> = optionalCapability(
            .climateTimers, enabled: needsClimateTimers, vin: vin, bypassCache: bypassCommandCaches
        ) { Optional(try await self.grpc.fetchClimateTimers(vin: vin, accessToken: serviceToken)) }
        async let tripsTask: CapabilityState<GrpcOdometerReport> = optionalCapability(
            .trips, enabled: features.contains(.tripMeters), vin: vin
        ) { try await self.grpc.fetchOdometer(vin: vin, accessToken: serviceToken) }
        async let connectivityTask: CapabilityState<VehicleConnectivity> = optionalCapability(
            .connectivity,
            enabled: features.contains(.connectivityDiagnostics) && modelProfile.permits(.connectivity),
            vin: vin
        ) { try await self.grpc.fetchConnectivity(vin: vin, accessToken: serviceToken) }
        async let airTask: CapabilityState<VehicleAirQuality> = optionalCapability(
            PolestarReading<VehicleAirQuality>.airQuality,
            enabled: needsAirQuality, vin: vin, bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchAirQuality(vin: vin, accessToken: serviceToken) }
        async let weatherTask: CapabilityState<VehicleWeather> = optionalCapability(
            .weather, enabled: features.contains(.vehicleWeather), vin: vin
        ) { try await self.grpc.fetchWeather(vin: vin, accessToken: serviceToken) }
        async let locationTask: CapabilityState<VehicleLocation> = optionalCapability(
            .location, enabled: features.contains(.vehicleLocation), vin: vin
        ) { try await self.grpc.fetchLocation(vin: vin, accessToken: serviceToken) }
        async let ampLimitTask: CapabilityState<PCCSScalarRead> = optionalCapability(
            .ampLimit,
            enabled: needsChargingContext && modelProfile.permits(.chargingCurrentLimit), vin: vin,
            bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchAmpLimit(vin: vin, accessToken: serviceToken) }
        async let chargeLocationsTask: CapabilityState<[ChargeLocationSnapshot]> = optionalCapability(
            .chargeLocations, enabled: needsSchedules, vin: vin, bypassCache: bypassCommandCaches
        ) { try await self.grpc.fetchChargeLocations(vin: vin, accessToken: serviceToken) }
        // MyCars supplies identity fallbacks and the installed version independently of OTA discovery.
        async let myCarsTask: CapabilityState<VehicleOTACapabilities> = optionalCapability(
            .myCars,
            enabled: features.contains(.softwareUpdates) || features.contains(.vehicleIdentity)
                || features.contains(.batteryDiagnostics)
                || !features.enabled.isDisjoint(with: AppFeature.remoteFeatures), vin: vin
        ) { try await self.grpc.fetchMyCars(vin: vin, accessToken: serviceToken) }

        let extras = try await batteryExtrasTask
        let availabilityReport = try await availabilityTask
        let targetReading = try await targetTask
        let chargeTarget = targetReading.value?.value
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
        let chargeLocations = try await chargeLocationsTask
        let otaCapabilities = try await myCarsTask

        let state = PolestarConsumerSnapshotAssembler(
            features: features,
            vin: vin,
            carIdentity: carIdentity,
            ownerFirstName: ownerFirstName,
            market: market,
            imageData: carImages[vin],
            fetchedAt: now(),
            graphQLStartedAt: graphQLStartedAt,
            servicesStartedAt: servicesStartedAt,
            targetObservation: targetReading.observation,
            hasGraphQLErrors: response?.errors?.isEmpty == false,
            battery: battery,
            odometer: odometer,
            health: health,
            extras: extras,
            availabilityReport: availabilityReport,
            chargeTarget: chargeTarget,
            targetSocRawFields: targetReading.value?.unknownFields ?? [],
            exterior: exterior,
            c3Health: c3Health,
            software: software,
            schedules: schedules,
            climate: climate,
            climateTimers: climateTimers,
            trips: trips,
            connectivity: connectivity,
            air: air,
            weather: weather,
            location: location,
            ampLimit: ampLimit,
            ampLimitRawFields: ampLimit.value?.unknownFields ?? [],
            chargeLocations: chargeLocations,
            otaCapabilities: otaCapabilities
        ).assemble()
        try requireSession(epoch)
        return state
    }

    static func resolvedBatteryCapacity(graphQL: Double?, batteryService: Double?, equipment: VehicleEquipment?) -> Double? {
        [graphQL, batteryService, equipment?.batteryCapacityKwh]
            .compactMap { $0 }.first { $0.isFinite && $0 > 0 }
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

// Mapping helpers for the telematics payload.
extension PolestarAPI {
    static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func hasWarning(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.contains("NO_WARNING") && !value.contains("UNSPECIFIED")
    }

    static func fluidWarnings(_ health: HealthDTO?) -> [String] {
        guard let health else { return [] }
        let values = [
            (health.brakeFluidLevelWarning, "BRAKE_FLUID_LEVEL_WARNING_", L10n.text("Brake fluid")),
            (health.engineCoolantLevelWarning, "ENGINE_COOLANT_LEVEL_WARNING_", L10n.text("Coolant")),
            (health.oilLevelWarning, "OIL_LEVEL_WARNING_", L10n.text("Oil"))
        ]
        return values.compactMap { raw, prefix, label in
            guard let raw, hasWarning(raw) else { return nil }
            let detail = raw.replacingOccurrences(of: prefix, with: "")
                .replacingOccurrences(of: "_", with: " ").lowercased()
            return "\(label) \(detail)"
        }
    }
}
