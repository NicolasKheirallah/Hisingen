import Foundation

extension VehicleState {
    private enum CodingKeys: String, CodingKey {
        case energy, identity, maintenance, freshness, commandState
        case readingDates
        case estimatedChargingTimeToTargetMinutes
        case batteryPercentage, rangeKm, chargingState, estimatedChargingTimeToFullMinutes
        case chargeTargetPercentage, chargingPowerWatts, chargingCurrentAmps, chargingVoltageVolts
        case chargingType, chargerConnection, availability, modelName, modelYear, registrationNo
        // serviceInfo/tripComputer are the current encodings; their flat member keys below
        // exist only for the decoder's legacy fallback.
        case vin, ownerFirstName, odometerKm, serviceInfo, tripComputer, pendingCommand
        case daysToService, distanceToServiceKm, serviceWarning, fluidWarnings
        case tripMeterManualKm, tripMeterAutomaticKm
        case exteriorStatus, healthDetails, softwareInfo, chargingSchedules
        case climateStatus, climateTimers, connectivity
        case airQuality, batteryDiagnostics, weather, location, unavailableFeatures, probedCapabilities
        case chargingSamples, chargingSessions, imageData, fetchedAt, vehicleReportedAt, dataWarnings
        // `fuelSystem` is the current encoding; the flat fuel cases below exist ONLY for the
        // decoder's legacy fallback — the explicit `encode(to:)` never writes them.
        case powertrain, fuelSystem
        case reportedBatteryCapacityKwh
        case externalColour, gearbox, engineHoursToService, averageSpeedKmH
        case fuelLevelPercent, fuelRangeKm, fuelAmountLiters, averageFuelConsumptionLPer100Km
        case isEngineRunning, fuelType
        case structureWeek, internalVehicleIdentifier, pno34, accountMarket
        case upholstery, steeringOrientation, serviceTrigger, tripComputerElectricRangeKm, chargingCurrentLimitAmps
        case interiorImageData, warrantyInfo
        case chargeLocations
        case electricDistanceKm, fuelDistanceKm, regeneratedEnergyKwh, frontBrakePadStatus, rearBrakePadStatus
        case preferredWorkshopId, preferredWorkshopName
        case isCachedSnapshot, retainedDataCategories, retainedDataAt, otaCapabilities
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func readFlat<T: Decodable>(_ key: String) throws -> T? {
            guard let key = CodingKeys(stringValue: key) else { return nil }
            return try values.decodeIfPresent(T.self, forKey: key)
        }

        let energy = try values.decodeIfPresent(EnergyAndChargingSnapshot.self, forKey: .energy)
            ?? EnergyAndChargingSnapshot(
                batteryPercentage: try readFlat("batteryPercentage"),
                rangeKm: try readFlat("rangeKm"),
                chargingState: try values.decode(ChargingState.self, forKey: .chargingState),
                estimatedTimeToFullMinutes: try readFlat("estimatedChargingTimeToFullMinutes"),
                estimatedTimeToTargetMinutes: try readFlat("estimatedChargingTimeToTargetMinutes"),
                targetPercentage: try readFlat("chargeTargetPercentage"),
                powerWatts: try readFlat("chargingPowerWatts"),
                currentAmps: try readFlat("chargingCurrentAmps"),
                voltageVolts: try readFlat("chargingVoltageVolts"),
                type: try values.decode(ChargingType.self, forKey: .chargingType),
                connection: try values.decode(ChargerConnection.self, forKey: .chargerConnection),
                currentLimitAmps: try readFlat("chargingCurrentLimitAmps"),
                reportedBatteryCapacityKwh: try readFlat("reportedBatteryCapacityKwh"),
                diagnostics: try readFlat("batteryDiagnostics"),
                schedules: try values.decodeIfPresent([VehicleSchedule].self, forKey: .chargingSchedules) ?? [],
                locations: try values.decodeIfPresent([ChargeLocationSnapshot].self, forKey: .chargeLocations) ?? [],
                samples: try values.decodeIfPresent([ChargingSample].self, forKey: .chargingSamples) ?? [],
                sessions: try values.decodeIfPresent([ChargingSession].self, forKey: .chargingSessions) ?? []
            )
        let identity = try values.decodeIfPresent(VehicleIdentitySnapshot.self, forKey: .identity)
            ?? VehicleIdentitySnapshot(
                availability: try values.decode(VehicleAvailability.self, forKey: .availability),
                modelName: try readFlat("modelName"),
                modelYear: try readFlat("modelYear"),
                registrationNo: try readFlat("registrationNo"),
                vin: try values.decode(String.self, forKey: .vin),
                ownerFirstName: try readFlat("ownerFirstName"),
                externalColour: try readFlat("externalColour"),
                gearbox: try readFlat("gearbox"),
                structureWeek: try readFlat("structureWeek"),
                internalVehicleIdentifier: try readFlat("internalVehicleIdentifier"),
                pno34: try readFlat("pno34"),
                accountMarket: try readFlat("accountMarket"),
                upholstery: try readFlat("upholstery"),
                steeringOrientation: try readFlat("steeringOrientation"),
                imageData: try readFlat("imageData"),
                interiorImageData: try readFlat("interiorImageData")
            )
        let service = try values.decodeIfPresent(ServiceSnapshot.self, forKey: .serviceInfo)
            ?? ServiceSnapshot(
                daysToService: try readFlat("daysToService"),
                distanceToServiceKm: try readFlat("distanceToServiceKm"),
                serviceWarning: try values.decodeIfPresent(Bool.self, forKey: .serviceWarning) ?? false,
                fluidWarnings: try values.decodeIfPresent([String].self, forKey: .fluidWarnings) ?? [],
                engineHoursToService: try readFlat("engineHoursToService"),
                trigger: try readFlat("serviceTrigger"),
                preferredWorkshopID: try readFlat("preferredWorkshopId"),
                preferredWorkshopName: try readFlat("preferredWorkshopName")
            )
        let maintenance = try values.decodeIfPresent(MaintenanceAndHealthSnapshot.self, forKey: .maintenance)
            ?? MaintenanceAndHealthSnapshot(
                odometerKm: try readFlat("odometerKm"),
                details: try readFlat("healthDetails"),
                service: service,
                warranty: try readFlat("warrantyInfo"),
                frontBrakePadStatus: try readFlat("frontBrakePadStatus"),
                rearBrakePadStatus: try readFlat("rearBrakePadStatus")
            )
        let freshness = try values.decodeIfPresent(SnapshotFreshness.self, forKey: .freshness)
            ?? SnapshotFreshness(
                isCached: try values.decodeIfPresent(Bool.self, forKey: .isCachedSnapshot) ?? false,
                fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
                vehicleReportedAt: try readFlat("vehicleReportedAt"),
                readingDates: try values.decodeIfPresent([VehicleReading: Date].self, forKey: .readingDates) ?? [:],
                dataWarnings: try values.decode([String].self, forKey: .dataWarnings),
                unavailableFeatures: try values.decodeIfPresent([AppFeature].self, forKey: .unavailableFeatures) ?? [],
                retainedDataCategories: try values.decodeIfPresent([AppFeature].self, forKey: .retainedDataCategories) ?? [],
                retainedDataAt: try readFlat("retainedDataAt")
            )
        let tripComputer = try values.decodeIfPresent(TripComputerSnapshot.self, forKey: .tripComputer)
            ?? TripComputerSnapshot(
                manualTripKm: try readFlat("tripMeterManualKm"),
                automaticTripKm: try readFlat("tripMeterAutomaticKm"),
                averageSpeedKmH: try readFlat("averageSpeedKmH"),
                electricRangeKm: try readFlat("tripComputerElectricRangeKm"),
                electricDistanceKm: try readFlat("electricDistanceKm"),
                fuelDistanceKm: try readFlat("fuelDistanceKm"),
                regeneratedEnergyKwh: try readFlat("regeneratedEnergyKwh")
            )
        let fuelSystem = try values.decodeIfPresent(FuelSystemSnapshot.self, forKey: .fuelSystem)
            ?? FuelSystemSnapshot(
                levelPercent: try readFlat("fuelLevelPercent"),
                rangeKm: try readFlat("fuelRangeKm"),
                amountLiters: try readFlat("fuelAmountLiters"),
                averageConsumptionLPer100Km: try readFlat("averageFuelConsumptionLPer100Km"),
                isEngineRunning: try readFlat("isEngineRunning"),
                type: try readFlat("fuelType")
            )
        let commandState = try values.decodeIfPresent(CommandPresentationState.self, forKey: .commandState)
            ?? CommandPresentationState(receipt: try readFlat("pendingCommand"))

        self.init(
            energy: energy,
            identity: identity,
            maintenance: maintenance,
            freshness: freshness,
            commandState: commandState,
            exteriorStatus: try readFlat("exteriorStatus"),
            softwareInfo: try readFlat("softwareInfo"),
            climateStatus: try readFlat("climateStatus"),
            climateTimers: try values.decodeIfPresent([VehicleSchedule].self, forKey: .climateTimers) ?? [],
            tripComputer: tripComputer,
            connectivity: try readFlat("connectivity"),
            airQuality: try readFlat("airQuality"),
            weather: try readFlat("weather"),
            location: try readFlat("location"),
            probedCapabilities: try readFlat("probedCapabilities"),
            powertrain: try values.decodeIfPresent(PowertrainType.self, forKey: .powertrain) ?? .bev,
            fuelSystem: fuelSystem,
            otaCapabilities: try readFlat("otaCapabilities")
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(energy, forKey: .energy)
        try values.encode(identity, forKey: .identity)
        try values.encode(maintenance, forKey: .maintenance)
        try values.encode(freshness, forKey: .freshness)
        try values.encode(commandState, forKey: .commandState)
        try values.encodeIfPresent(exteriorStatus, forKey: .exteriorStatus)
        try values.encodeIfPresent(softwareInfo, forKey: .softwareInfo)
        try values.encodeIfPresent(climateStatus, forKey: .climateStatus)
        try values.encode(climateTimers, forKey: .climateTimers)
        try values.encodeIfPresent(connectivity, forKey: .connectivity)
        try values.encodeIfPresent(airQuality, forKey: .airQuality)
        try values.encodeIfPresent(weather, forKey: .weather)
        try values.encodeIfPresent(location, forKey: .location)
        try values.encodeIfPresent(probedCapabilities, forKey: .probedCapabilities)
        try values.encode(powertrain, forKey: .powertrain)
        try values.encode(fuelSystem, forKey: .fuelSystem)
        try values.encode(tripComputer, forKey: .tripComputer)
        try values.encodeIfPresent(otaCapabilities, forKey: .otaCapabilities)
    }
}
