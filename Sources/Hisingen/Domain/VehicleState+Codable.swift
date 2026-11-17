import Foundation

extension VehicleState {
    /// Written into every snapshot this build encodes. Nothing in this build reads it: every
    /// cluster is decoded strictly, so a truncated or hand-edited payload fails instead of
    /// becoming a half-empty vehicle. It stays so that a build rolled back to one that still
    /// reads the flat layout can tell this payload is not flat.
    static let encodedSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case energy, identity, maintenance, freshness, commandState
        case tripComputer, fuelSystem
        case exteriorStatus, softwareInfo, climateStatus, climateTimers, connectivity
        case airQuality, weather, location, probedCapabilities, powertrain, otaCapabilities
    }

    /// Payloads older than the clustered layout (2.0.1 and earlier) are not decoded: they are
    /// past the seven-day cache retention, so `loadSnapshot` would discard them anyway.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            energy: try values.decode(EnergyAndChargingSnapshot.self, forKey: .energy),
            identity: try values.decode(VehicleIdentitySnapshot.self, forKey: .identity),
            maintenance: try values.decode(MaintenanceAndHealthSnapshot.self, forKey: .maintenance),
            freshness: try values.decode(SnapshotFreshness.self, forKey: .freshness),
            commandState: try values.decode(CommandPresentationState.self, forKey: .commandState),
            exteriorStatus: try values.decodeIfPresent(ExteriorSnapshot.self, forKey: .exteriorStatus),
            softwareInfo: try values.decodeIfPresent(VehicleSoftwareInfo.self, forKey: .softwareInfo),
            climateStatus: try values.decodeIfPresent(VehicleClimateStatus.self, forKey: .climateStatus),
            climateTimers: try values.decodeIfPresent([VehicleSchedule].self, forKey: .climateTimers) ?? [],
            tripComputer: try values.decode(TripComputerSnapshot.self, forKey: .tripComputer),
            connectivity: try values.decodeIfPresent(VehicleConnectivity.self, forKey: .connectivity),
            airQuality: try values.decodeIfPresent(VehicleAirQuality.self, forKey: .airQuality),
            weather: try values.decodeIfPresent(VehicleWeather.self, forKey: .weather),
            location: try values.decodeIfPresent(VehicleLocation.self, forKey: .location),
            probedCapabilities: try values.decodeIfPresent(VehicleProbedCapabilities.self, forKey: .probedCapabilities),
            powertrain: try values.decodeIfPresent(PowertrainType.self, forKey: .powertrain) ?? .bev,
            fuelSystem: try values.decode(FuelSystemSnapshot.self, forKey: .fuelSystem),
            otaCapabilities: try values.decodeIfPresent(VehicleOTACapabilities.self, forKey: .otaCapabilities)
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
