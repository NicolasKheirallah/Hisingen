import Foundation

extension VolvoAPI {
    func fetchVehicleStateImplementation(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await refreshTokenIfNeeded()
        guard accessToken != nil else { throw VolvoError.authenticationRequired(.expiredSession) }

        let details = (try? await vehicleDetails(vin: vin)) ?? VolvoVehicleDetailsDTO(
            vin: vin, modelYear: nil,
            descriptions: VolvoVehicleDetailsDTO.Descriptions(model: "Volvo", upholstery: nil, steering: nil),
            fuelType: "ELECTRIC", externalColour: nil, gearbox: nil, batteryCapacityKWH: nil, images: nil
        )
        let powertrain = VolvoPowertrain.classify(fuelType: details.fuelType)
        let needsEnergy = powertrain.hasElectricRange
            && (features.contains(.chargingDetails) || features.contains(.remoteCharging)
                || features.contains(.batteryDiagnostics))

        let needsStatistics = features.contains(.tripMeters)
            || (powertrain.hasFuelRange && features.contains(.batteryDiagnostics))

        let needsFuel = powertrain.hasFuelRange || (details.fuelType != nil && details.fuelType != "ELECTRIC")
        async let fuelTask: VolvoFuelDTO? = optional(enabled: needsFuel, key: "fuel", vin: vin) {
            try await self.get("/connected-vehicle/v2/vehicles/\(vin)/fuel")
        }

        async let energyTask: VolvoEnergyStateDTO? = optional(enabled: needsEnergy, key: "energy-state", vin: vin) {
            try await self.get("/energy/v2/vehicles/\(vin)/state")
        }
        async let doorsTask: VolvoDoorsDTO? = optional(
            enabled: features.contains(.exteriorStatus) || features.contains(.remoteLocks), key: "doors", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/doors") }
        async let windowsTask: VolvoWindowsDTO? = optional(
            enabled: features.contains(.exteriorStatus) || features.contains(.remoteWindows), key: "windows", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/windows") }
        async let tyresTask: VolvoTyresDTO? = optional(
            enabled: features.contains(.tyreAndWarnings), key: "tyres", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/tyres") }
        async let diagnosticsTask: VolvoDiagnosticsDTO? = optional(
            enabled: features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings), key: "diagnostics", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/diagnostics") }
        async let odometerTask: VolvoOdometerDTO? = optional(
            enabled: features.contains(.vehicleHealth), key: "odometer", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/odometer") }
        async let statisticsTask: VolvoStatisticsDTO? = optional(
            enabled: needsStatistics, key: "statistics", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/statistics") }
        async let locationTask: VolvoLocationDTO? = optional(
            enabled: features.contains(.vehicleLocation), key: "location", vin: vin
        ) { try await self.get("/location/v1/vehicles/\(vin)/location") }
        async let brakesTask: VolvoBrakesDTO? = optional(
            enabled: features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings), key: "brakes", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/brakes") }
        async let warningsTask: VolvoWarningsDTO? = optional(
            enabled: features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings), key: "warnings", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/warnings") }
        async let engineStatusTask: VolvoEngineStatusDTO? = optional(
            enabled: true, key: "engine-status", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/engine-status") }
        async let commandAccessibilityTask: VolvoCommandAccessibilityDTO? = optional(
            enabled: true, key: "command-accessibility", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/command-accessibility") }

        let fuel = try await fuelTask
        let energy = try await energyTask
        let doors = try await doorsTask
        let windows = try await windowsTask
        let tyres = try await tyresTask
        let diagnostics = try await diagnosticsTask
        let odometer = try await odometerTask
        let statistics = try await statisticsTask
        let location = try await locationTask
        let brakes = try await brakesTask
        let warnings = try await warningsTask
        let engineStatus = try await engineStatusTask
        let commandAccessibility = try await commandAccessibilityTask

        if features.contains(.vehicleImage) {
            await fetchCarImage(vin: vin, imageUrlString: details.images?.exteriorImageUrl)
            await fetchInteriorImage(vin: vin, imageUrlString: details.images?.interiorImageUrl)
        }

        let vehicleLocation: VehicleLocation? = location.flatMap { (loc: VolvoLocationDTO) -> VehicleLocation? in
            guard let coords = loc.geometry?.coordinates, coords.count >= 2 else { return nil }
            return VehicleLocation(
                latitude: coords[1],
                longitude: coords[0],
                heading: loc.properties?.heading.flatMap(Double.init),
                speed: nil,
                timestamp: loc.properties?.timestamp
            )
        }

        let reportedAt: Date? = [energy?.batteryChargeLevel?.updatedAt, diagnostics?.serviceWarning?.updatedAt]
            .compactMap { $0 }.max()

        // Volvo exposes no climate-status resource. Climatization is command-only
        // (POST .../commands/climatization-start|stop); every GET spelling under
        // connected-vehicle/v2, energy/v2 and location/v1 404s at the gateway's routing
        // layer, before authentication, exactly like a path that was never registered.
        // With remote climate commands available we still show a clean Idle/Standby state
        // rather than a broken unavailable badge.
        let climate: VehicleClimateStatus? = {
            guard features.contains(.climateStatus), features.contains(.remoteClimate) else { return nil }
            return VehicleClimateStatus(
                activity: .idle,
                timeRemainingMinutes: nil,
                timerTriggered: false,
                interiorTemperatureCelsius: nil,
                requestedTemperatureCelsius: 22.0
            )
        }()

        // Volvo publishes no software/OTA resource. The Connected Vehicle API v2 surface is
        // details, doors, windows, tyres, warnings, diagnostics, engine, engine-status, brakes,
        // fuel, odometer, statistics, commands, command-accessibility — and the Energy and
        // Location APIs alongside it. None of them reports a firmware level or update state,
        // so there is nothing to show and nothing to invent.
        let software: VehicleSoftwareInfo? = nil

        var unavailable: [AppFeature] = []
        if features.contains(.softwareUpdates) { unavailable.append(.softwareUpdates) }
        if features.contains(.exteriorStatus), doors == nil, windows == nil { unavailable.append(.exteriorStatus) }
        if features.contains(.tyreAndWarnings), tyres == nil { unavailable.append(.tyreAndWarnings) }
        if features.contains(.vehicleHealth), diagnostics == nil, odometer == nil { unavailable.append(.vehicleHealth) }
        if features.contains(.tripMeters), statistics == nil { unavailable.append(.tripMeters) }
        if features.contains(.vehicleLocation), vehicleLocation == nil { unavailable.append(.vehicleLocation) }
        if features.contains(.chargingSchedule) { unavailable.append(.chargingSchedule) }

        var openings: [OpeningReading] = []
        let doorFields: [(VehicleOpening, String?)] = [
            (.frontLeftDoor, doors?.frontLeftDoor?.value), (.frontRightDoor, doors?.frontRightDoor?.value),
            (.rearLeftDoor, doors?.rearLeftDoor?.value), (.rearRightDoor, doors?.rearRightDoor?.value),
            (.hood, doors?.hood?.value), (.tailgate, doors?.tailgate?.value), (.chargeLid, doors?.tankLid?.value)
        ]
        let windowFields: [(VehicleOpening, String?)] = [
            (.frontLeftWindow, windows?.frontLeftWindow?.value), (.frontRightWindow, windows?.frontRightWindow?.value),
            (.rearLeftWindow, windows?.rearLeftWindow?.value), (.rearRightWindow, windows?.rearRightWindow?.value),
            (.sunroof, windows?.sunroof?.value)
        ]
        for (opening, raw) in doorFields + windowFields {
            if let state = OpeningState(volvoStatus: raw) { openings.append(OpeningReading(opening: opening, state: state)) }
        }
        let exterior: ExteriorSnapshot? = (doors != nil || windows != nil)
            ? ExteriorSnapshot(openings: openings, isLocked: doors?.isLocked, alarmTriggered: nil)
            : nil

        let energyCaps = needsEnergy ? try? await fetchEnergyCapabilities(vin: vin) : nil
        var probes = VehicleProbedCapabilities()
        if doors != nil || windows != nil { probes.record(.exteriorStatus, as: .supported) }
        if diagnostics != nil { probes.record(.serviceWarnings, as: .supported) }
        if tyres?.readings.contains(where: { $0.kilopascals != nil }) == true {
            probes.record(.tyrePressureValues, as: .supported)
        }
        if commandAccessibility?.isAvailable == true {
            probes.record(.climateStartStop, as: .supported)
            probes.record(.locks, as: .supported)
            probes.record(.honkAndFlash, as: .supported)
        }
        if statistics?.tripMeterManual != nil || statistics?.tripMeterAutomatic != nil {
            probes.record(.tripMeters, as: .supported)
        }

        if let supported = energyCaps?.targetBatteryLevel?.isSupported {
            probes.record(.chargeTarget, as: supported ? .supported : .unavailable)
        }
        if let supported = energyCaps?.chargingPower?.isSupported {
            probes.record(.chargingCurrentLimit, as: supported ? .supported : .unavailable)
        }

        let batteryPct: Double? = energy?.batteryChargeLevel?.value
        let rangeKm: Int? = energy?.rangeKm
        let estMinutes: Int? = energy?.estTimeToTargetMinutes
        let targetPct: Int? = energy?.targetPercent
        let chargingWatts: Int? = energy?.chargingPower?.value.map { Int(($0 * 1_000).rounded()) }
        let currentDrawAmps: Int? = energy?.chargingCurrent?.value.map { Int($0.rounded()) }
        let currentLimitAmps: Int? = energy?.chargingCurrentLimit?.value.map { Int($0.rounded()) }
        let chargingAmps: Int? = currentDrawAmps ?? currentLimitAmps
        let chargingVolts: Int? = energy?.chargingVoltage?.value.map { Int($0.rounded()) }
        let chargingState: ChargingState = ChargingState(volvoChargingStatus: energy?.chargingStatus?.value)
        let chargerConn: ChargerConnection = ChargerConnection(volvoConnectionStatus: energy?.chargerConnectionStatus?.value)
        let modelName: String? = details.descriptions?.model
        let modelYear: String? = details.modelYear.map(String.init)
        let odometerKm: Int? = odometer?.odometer?.value
        let daysToService: Int? = diagnostics?.daysToServiceApprox
        let distToService: Int? = diagnostics?.distanceToService?.value
        let serviceWarn: Bool = diagnostics?.hasServiceWarning ?? false
        var fluidWarns: [String] = diagnostics?.fluidWarnings ?? []
        if let brakeWarning = brakes?.brakeFluidLevelWarning?.value?.uppercased(),
           !brakeWarning.contains("NO_WARNING"), !brakeWarning.isEmpty,
           !fluidWarns.contains(L10n.text("Brake fluid")) {
            fluidWarns.append(L10n.text("Brake fluid"))
        }

        var vehicleWarnings: [VehicleWarning] = diagnostics?.vehicleWarnings ?? []
        let activeBulbWarnings = warnings?.activeWarnings ?? []
        if !activeBulbWarnings.isEmpty && !vehicleWarnings.contains(.exteriorLight) {
            vehicleWarnings.append(.exteriorLight)
        }

        let health: VehicleHealthDetails? = (tyres != nil || diagnostics != nil || warnings != nil || brakes != nil)
            ? VehicleHealthDetails(tyres: tyres?.readings ?? [], warnings: vehicleWarnings)
            : nil
        let batteryDiag: BatteryDiagnostics? = features.contains(.batteryDiagnostics)
            ? BatteryDiagnostics(
                timeToTargetMinutes: estMinutes,
                timeToMinimumSOCMinutes: nil,
                chargerPowerState: .unknown,
                averageConsumption: statistics?.averageEnergyConsumption?.value,
                averageConsumptionSinceCharge: nil,
                energyUsedSinceChargeWh: nil
            )
            : nil
        let tripManual: Double? = statistics?.tripMeterManual?.value
        let tripAuto: Double? = statistics?.tripMeterAutomatic?.value
        let probesResult: VehicleProbedCapabilities? = probes.count > 0 ? probes : nil
        let fuelPct: Double? = fuel?.percentage ?? (fuel?.liters.map { min(100.0, max(0.0, ($0 / 60.0) * 100.0)) })
        let fuelRange: Int? = fuel?.rangeKm ?? statistics?.distanceToEmptyTank?.value
        let fuelLiters: Double? = fuel?.liters
        let avgFuelConsumption: Double? = statistics?.averageFuelConsumption?.value
        let isEngineRunning: Bool? = engineStatus?.isRunning
        // vehicle-details batteryCapacityKWH is a vehicle specification, not BMS SoH telemetry.
        let batteryCap: Double? = details.batteryCapacityKWH
        let carImg: Data? = features.contains(.vehicleImage) ? (carImageData[vin] ?? imageCache.image(for: vin)) : nil
        let interiorImg: Data? = features.contains(.vehicleImage)
            ? (interiorImageData[vin] ?? imageCache.interiorImage(for: vin)) : nil
        let availability: VehicleAvailability = (commandAccessibility?.isAvailable == true) ? .available : .unknown

        var state = VehicleState(
            batteryPercentage: batteryPct,
            rangeKm: rangeKm,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: estMinutes,
            chargeTargetPercentage: targetPct,
            chargingPowerWatts: chargingWatts,
            chargingCurrentAmps: currentDrawAmps ?? chargingAmps,
            chargingVoltageVolts: chargingVolts,
            chargingType: .unknown,
            chargerConnection: chargerConn,
            availability: availability,
            modelName: modelName,
            modelYear: modelYear,
            registrationNo: nil,
            vin: vin,
            ownerFirstName: nil,
            odometerKm: odometerKm,
            daysToService: daysToService,
            distanceToServiceKm: distToService,
            serviceWarning: serviceWarn,
            fluidWarnings: fluidWarns,
            exteriorStatus: exterior,
            healthDetails: health,
            softwareInfo: software,
            climateStatus: climate,
            tripMeterManualKm: tripManual,
            tripMeterAutomaticKm: tripAuto,
            batteryDiagnostics: batteryDiag,
            location: vehicleLocation,
            unavailableFeatures: unavailable,
            probedCapabilities: probesResult,
            powertrain: powertrain,
            fuelLevelPercent: fuelPct,
            fuelRangeKm: fuelRange,
            reportedBatteryCapacityKwh: batteryCap,
            imageData: carImg,
            fetchedAt: Date(),
            vehicleReportedAt: reportedAt,
            dataWarnings: activeBulbWarnings
        )
        state.externalColour = details.externalColour
        state.gearbox = details.gearbox
        state.engineHoursToService = diagnostics?.engineHoursToService?.value
        state.averageSpeedKmH = statistics?.averageSpeed?.value
        state.fuelAmountLiters = fuelLiters
        state.averageFuelConsumptionLPer100Km = avgFuelConsumption
        state.isEngineRunning = isEngineRunning
        state.fuelType = details.fuelType
        state.upholstery = details.descriptions?.upholstery
        state.steeringOrientation = details.descriptions?.steering
        state.serviceTrigger = diagnostics?.serviceTrigger?.value
        state.tripComputerElectricRangeKm = statistics?.distanceToEmptyBattery?.value
        state.chargingCurrentLimitAmps = currentLimitAmps
        state.interiorImageData = interiorImg
        state.electricDistanceKm = statistics?.electricDistance?.value.map { $0 / 1000.0 }
        state.fuelDistanceKm = statistics?.fuelDistance?.value.map { $0 / 1000.0 }
        state.regeneratedEnergyKwh = statistics?.regeneratedEnergy?.value
        state.frontBrakePadStatus = brakes?.frontBrakePadStatus?.value
        state.rearBrakePadStatus = brakes?.rearBrakePadStatus?.value
        state.preferredWorkshopId = diagnostics?.workshopId?.value
        state.preferredWorkshopName = diagnostics?.workshopName?.value
        return state
    }

    private func fetchCarImage(vin: String, imageUrlString: String?) async {
        if carImageData[vin] != nil || imageCache.image(for: vin) != nil { return }
        guard let imageUrlString, let url = URL(string: imageUrlString), url.scheme == "https" else { return }
        guard let (bytes, response) = try? await perform(URLRequest(url: url), limit: 5_000_000, operation: "vehicle image"),
              response.statusCode == 200,
              bytes.count <= 5_000_000 else { return }
        carImageData[vin] = bytes
        imageCache.save(bytes, for: vin)
    }

    private func fetchInteriorImage(vin: String, imageUrlString: String?) async {
        if interiorImageData[vin] != nil || imageCache.interiorImage(for: vin) != nil { return }
        guard let imageUrlString, let url = URL(string: imageUrlString), url.scheme == "https" else { return }
        guard let (bytes, response) = try? await perform(URLRequest(url: url), limit: 5_000_000, operation: "vehicle interior image"),
              response.statusCode == 200,
              bytes.count <= 5_000_000 else { return }
        interiorImageData[vin] = bytes
        imageCache.saveInterior(bytes, for: vin)
    }



    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await fetchVehicleStateImplementation(vin: vin, features: features)
    }
}
