import Foundation

struct VehicleState: Codable, Equatable, Sendable {
    var energy: EnergyAndChargingSnapshot
    var identity: VehicleIdentitySnapshot
    var maintenance: MaintenanceAndHealthSnapshot
    var freshness: SnapshotFreshness
    var commandState = CommandPresentationState()
    var exteriorStatus: ExteriorSnapshot? = nil
    var softwareInfo: VehicleSoftwareInfo? = nil
    var climateStatus: VehicleClimateStatus? = nil
    var climateTimers: [VehicleSchedule] = []
    var tripComputer = TripComputerSnapshot()
    var connectivity: VehicleConnectivity? = nil
    var airQuality: VehicleAirQuality? = nil
    var weather: VehicleWeather? = nil
    var location: VehicleLocation? = nil
    var probedCapabilities: VehicleProbedCapabilities? = nil

    var otaCapabilities: VehicleOTACapabilities? = nil
    var powertrain: PowertrainType = .bev
    var fuelSystem: FuelSystemSnapshot = .init()

    init(
        energy: EnergyAndChargingSnapshot,
        identity: VehicleIdentitySnapshot,
        maintenance: MaintenanceAndHealthSnapshot = .init(),
        freshness: SnapshotFreshness,
        commandState: CommandPresentationState = .init(),
        exteriorStatus: ExteriorSnapshot? = nil,
        softwareInfo: VehicleSoftwareInfo? = nil,
        climateStatus: VehicleClimateStatus? = nil,
        climateTimers: [VehicleSchedule] = [],
        tripComputer: TripComputerSnapshot = .init(),
        connectivity: VehicleConnectivity? = nil,
        airQuality: VehicleAirQuality? = nil,
        weather: VehicleWeather? = nil,
        location: VehicleLocation? = nil,
        probedCapabilities: VehicleProbedCapabilities? = nil,
        powertrain: PowertrainType = .bev,
        fuelSystem: FuelSystemSnapshot = .init(),
        otaCapabilities: VehicleOTACapabilities? = nil
    ) {
        self.energy = energy
        self.identity = identity
        self.maintenance = maintenance
        self.freshness = freshness
        self.commandState = commandState
        self.exteriorStatus = exteriorStatus
        self.softwareInfo = softwareInfo
        self.climateStatus = climateStatus
        self.climateTimers = climateTimers
        self.tripComputer = tripComputer
        self.connectivity = connectivity
        self.airQuality = airQuality
        self.weather = weather
        self.location = location
        self.probedCapabilities = probedCapabilities
        self.powertrain = powertrain
        self.fuelSystem = fuelSystem
        self.otaCapabilities = otaCapabilities
    }

    var cacheableCopy: VehicleState {
        var cachedEnergy = energy
        cachedEnergy.locations = []
        cachedEnergy.sessions = []

        var cachedIdentity = identity
        cachedIdentity.registrationNo = nil
        cachedIdentity.ownerFirstName = nil
        cachedIdentity.imageData = nil
        cachedIdentity.interiorImageData = nil

        var cachedFreshness = freshness
        cachedFreshness.unavailableFeatures = []
        cachedFreshness.readingDates[.location] = nil

        return VehicleState(
            energy: cachedEnergy,
            identity: cachedIdentity,
            maintenance: maintenance,
            freshness: cachedFreshness,
            exteriorStatus: exteriorStatus,
            softwareInfo: softwareInfo,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripComputer: tripComputer,
            connectivity: connectivity,
            airQuality: airQuality,
            weather: weather,
            probedCapabilities: probedCapabilities,
            powertrain: powertrain,
            fuelSystem: fuelSystem
        )
    }
}
