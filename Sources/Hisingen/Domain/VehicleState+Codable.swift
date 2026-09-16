import Foundation

extension VehicleState {
    /// Written into every snapshot this build encodes. A payload carrying it is the current
    /// format, whose clusters are the only place its state lives; a payload without it was
    /// written before the clusters existed and is the only one the flat member keys may answer
    /// for. The distinction is what makes those keys deletable once the pre-marker payloads have
    /// aged out of the seven-day cache and the plist mirror migration has been dropped.
    static let encodedSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
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
        // decoder's legacy fallback – the explicit `encode(to:)` never writes them.
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
        let isCurrentFormat =
            try values.decodeIfPresent(Int.self, forKey: .schemaVersion) == Self.encodedSchemaVersion

        /// Reads a member under its own flat key. That key is the current encoding for the
        /// top-level members below, and the pre-marker encoding for the cluster members, whose
        /// callers pass this through the legacy closure of `cluster(_:_:legacy:)`.
        func readFlat<T: Decodable>(_ key: String) throws -> T? {
            guard let key = CodingKeys(stringValue: key) else { return nil }
            return try values.decodeIfPresent(T.self, forKey: key)
        }

        /// A current payload decodes its cluster strictly – a truncated or hand-edited one fails
        /// here instead of decoding into a state assembled from whatever keys happened to be
        /// present – while a pre-marker payload may still be rescued by its flat members.
        func cluster<Value: Decodable>(
            _ type: Value.Type, _ key: CodingKeys, legacy: () throws -> Value
        ) throws -> Value {
            if isCurrentFormat { return try values.decode(type, forKey: key) }
            return try values.decodeIfPresent(type, forKey: key) ?? legacy()
        }

        let energy = try cluster(EnergyAndChargingSnapshot.self, .energy) {
            EnergyAndChargingSnapshot(
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
        }
        let identity = try cluster(VehicleIdentitySnapshot.self, .identity) {
            VehicleIdentitySnapshot(
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
        }
        // `service` has no top-level key of its own in the current format: it travels inside
        // `maintenance`. Only a pre-marker payload wrote the service block flat, which is why the
        // legacy branch reconstructs the maintenance cluster around the service it just read.
        let maintenance: MaintenanceAndHealthSnapshot
        if isCurrentFormat {
            maintenance = try values.decode(MaintenanceAndHealthSnapshot.self, forKey: .maintenance)
        } else {
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
            maintenance = try values.decodeIfPresent(MaintenanceAndHealthSnapshot.self, forKey: .maintenance)
                ?? MaintenanceAndHealthSnapshot(
                    odometerKm: try readFlat("odometerKm"),
                    details: try readFlat("healthDetails"),
                    service: service,
                    warranty: try readFlat("warrantyInfo"),
                    frontBrakePadStatus: try readFlat("frontBrakePadStatus"),
                    rearBrakePadStatus: try readFlat("rearBrakePadStatus")
                )
        }
        let freshness = try cluster(SnapshotFreshness.self, .freshness) {
            SnapshotFreshness(
                isCached: try values.decodeIfPresent(Bool.self, forKey: .isCachedSnapshot) ?? false,
                fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
                vehicleReportedAt: try readFlat("vehicleReportedAt"),
                readingDates: try values.decodeIfPresent([VehicleReading: Date].self, forKey: .readingDates) ?? [:],
                dataWarnings: try values.decode([String].self, forKey: .dataWarnings),
                unavailableFeatures: try values.decodeIfPresent([AppFeature].self, forKey: .unavailableFeatures) ?? [],
                retainedDataCategories: try values.decodeIfPresent([AppFeature].self, forKey: .retainedDataCategories) ?? [],
                retainedDataAt: try readFlat("retainedDataAt")
            )
        }
        let tripComputer = try cluster(TripComputerSnapshot.self, .tripComputer) {
            TripComputerSnapshot(
                manualTripKm: try readFlat("tripMeterManualKm"),
                automaticTripKm: try readFlat("tripMeterAutomaticKm"),
                averageSpeedKmH: try readFlat("averageSpeedKmH"),
                electricRangeKm: try readFlat("tripComputerElectricRangeKm"),
                electricDistanceKm: try readFlat("electricDistanceKm"),
                fuelDistanceKm: try readFlat("fuelDistanceKm"),
                regeneratedEnergyKwh: try readFlat("regeneratedEnergyKwh")
            )
        }
        let fuelSystem = try cluster(FuelSystemSnapshot.self, .fuelSystem) {
            FuelSystemSnapshot(
                levelPercent: try readFlat("fuelLevelPercent"),
                rangeKm: try readFlat("fuelRangeKm"),
                amountLiters: try readFlat("fuelAmountLiters"),
                averageConsumptionLPer100Km: try readFlat("averageFuelConsumptionLPer100Km"),
                isEngineRunning: try readFlat("isEngineRunning"),
                type: try readFlat("fuelType")
            )
        }
        let commandState = try cluster(CommandPresentationState.self, .commandState) {
            CommandPresentationState(receipt: try readFlat("pendingCommand"))
        }

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
        try values.encode(Self.encodedSchemaVersion, forKey: .schemaVersion)
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
