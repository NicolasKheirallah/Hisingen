import Foundation

struct FuelSystemSnapshot: Codable, Equatable, Sendable {
    var levelPercent: Double?
    var rangeKm: Int?
    var amountLiters: Double?
    var averageConsumptionLPer100Km: Double?
    var isEngineRunning: Bool?
    /// Raw provider fuel-type string ("ELECTRIC", "DIESEL", …).
    var type: String?
}


struct TripComputerSnapshot: Codable, Equatable, Sendable {
    var manualTripKm: Double?
    var automaticTripKm: Double?
    var averageSpeedKmH: Double?
    /// Average speed over the manual trip-meter period (`Odometer.average_speed_km_per_hour`,
    /// field 5), in km/h. Separate from the blended `averageSpeedKmH` so the two sources
    /// never overwrite each other. Defaults keep older persisted snapshots decodable.
    var manualAverageSpeedKmH: Int? = nil
    /// Average speed over the automatic trip-meter period
    /// (`Odometer.average_speed_km_per_hour_automatic`, field 6), in km/h.
    var automaticAverageSpeedKmH: Int? = nil
    var electricRangeKm: Int?
    var electricDistanceKm: Double?
    var fuelDistanceKm: Double?
    var regeneratedEnergyKwh: Double?
}

struct EnergyAndChargingSnapshot: Codable, Equatable, Sendable {
    var batteryPercentage: Double?
    var rangeKm: Int?
    var chargingState: ChargingState
    var estimatedTimeToFullMinutes: Int?
    var estimatedTimeToTargetMinutes: Int?
    var targetPercentage: Int?
    var powerWatts: Int?
    var currentAmps: Int?
    var voltageVolts: Int?
    var type: ChargingType
    var connection: ChargerConnection
    var currentLimitAmps: Int?
    var reportedBatteryCapacityKwh: Double?
    var diagnostics: BatteryDiagnostics?
    var schedules: [VehicleSchedule]
    var locations: [ChargeLocationSnapshot]
    var samples: [ChargingSample]
    var sessions: [ChargingSession]

    init(
        batteryPercentage: Double? = nil,
        rangeKm: Int? = nil,
        chargingState: ChargingState = .idle,
        estimatedTimeToFullMinutes: Int? = nil,
        estimatedTimeToTargetMinutes: Int? = nil,
        targetPercentage: Int? = nil,
        powerWatts: Int? = nil,
        currentAmps: Int? = nil,
        voltageVolts: Int? = nil,
        type: ChargingType = .unknown,
        connection: ChargerConnection = .unknown,
        currentLimitAmps: Int? = nil,
        reportedBatteryCapacityKwh: Double? = nil,
        diagnostics: BatteryDiagnostics? = nil,
        schedules: [VehicleSchedule] = [],
        locations: [ChargeLocationSnapshot] = [],
        samples: [ChargingSample] = [],
        sessions: [ChargingSession] = []
    ) {
        self.batteryPercentage = batteryPercentage
        self.rangeKm = rangeKm
        self.chargingState = chargingState
        self.estimatedTimeToFullMinutes = estimatedTimeToFullMinutes
        self.estimatedTimeToTargetMinutes = estimatedTimeToTargetMinutes
        self.targetPercentage = targetPercentage
        self.powerWatts = powerWatts
        self.currentAmps = currentAmps
        self.voltageVolts = voltageVolts
        self.type = type
        self.connection = connection
        self.currentLimitAmps = currentLimitAmps
        self.reportedBatteryCapacityKwh = reportedBatteryCapacityKwh
        self.diagnostics = diagnostics
        self.schedules = schedules
        self.locations = locations
        self.samples = samples
        self.sessions = sessions
    }
}
