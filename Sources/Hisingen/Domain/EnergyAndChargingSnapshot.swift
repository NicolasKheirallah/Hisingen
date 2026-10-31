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
    var sinceChargeTripKm: Double? = nil
    var sinceChargeAverageSpeedKmH: Int? = nil
}

struct EnergyAndChargingSnapshot: Codable, Equatable, Sendable {
    var batteryPercentage: Double?
    var rangeKm: Int?
    var chargingState: ChargingState
    /// Whether the car's own schedule predicts completion. `nil` when the token did not
    /// carry a verdict, not when the verdict is good.
    var scheduleOutcome: ChargingScheduleOutcome? = nil
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
    var chargeNowActive: Bool?
    var samples: [ChargingSample]
    var sessions: [ChargingSession]
    /// Portal-queued location additions not yet confirmed by the vehicle.
    /// `nil` when none are queued; older snapshots decode as nil.
    var pendingChargeLocationCount: Int? = nil
    /// Portal-queued location deletions awaiting vehicle pickup.
    var pendingChargeLocationDeletionCount: Int? = nil
    /// True when a global charge-timer update is queued behind the car's next wake.
    var pendingGlobalChargeTimer: Bool? = nil
    /// Queued charge-now override value. Nil when nothing is queued; compared
    /// against `chargeNowActive` so an applied value reads as applied, not queued.
    var pendingChargeNowOverride: Bool? = nil
    /// Portal-queued climate-timer additions.
    var pendingClimateTimerCount: Int? = nil
    /// Portal-queued climate-timer deletions.
    var pendingClimateTimerDeletionCount: Int? = nil
    /// True when timer comfort settings are queued but not yet applied.
    var pendingTimerSettings: Bool? = nil
    /// Payload fields the PCCS charge-target read (GetTargetSoc) returned beyond the decoded
    /// field 1, kept raw for diagnostics. `nil` when none were sent; older snapshots decode
    /// as nil.
    var targetSocUnknownFields: [VehicleRawWireField]? = nil
    /// Payload fields the PCCS current-limit read (GetAmpLimit) returned beyond the decoded
    /// field 1. `nil` when none were sent; older snapshots decode as nil.
    var ampLimitUnknownFields: [VehicleRawWireField]? = nil

    init(
        batteryPercentage: Double? = nil,
        rangeKm: Int? = nil,
        chargingState: ChargingState = .idle,
        scheduleOutcome: ChargingScheduleOutcome? = nil,
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
        chargeNowActive: Bool? = nil,
        samples: [ChargingSample] = [],
        sessions: [ChargingSession] = [],
        pendingChargeLocationCount: Int? = nil,
        pendingChargeLocationDeletionCount: Int? = nil,
        pendingGlobalChargeTimer: Bool? = nil,
        pendingChargeNowOverride: Bool? = nil,
        pendingClimateTimerCount: Int? = nil,
        pendingClimateTimerDeletionCount: Int? = nil,
        pendingTimerSettings: Bool? = nil
    ) {
        self.batteryPercentage = batteryPercentage
        self.rangeKm = rangeKm
        self.chargingState = chargingState
        self.scheduleOutcome = scheduleOutcome
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
        self.chargeNowActive = chargeNowActive
        self.samples = samples
        self.sessions = sessions
        self.pendingChargeLocationCount = pendingChargeLocationCount
        self.pendingChargeLocationDeletionCount = pendingChargeLocationDeletionCount
        self.pendingGlobalChargeTimer = pendingGlobalChargeTimer
        self.pendingChargeNowOverride = pendingChargeNowOverride
        self.pendingClimateTimerCount = pendingClimateTimerCount
        self.pendingClimateTimerDeletionCount = pendingClimateTimerDeletionCount
        self.pendingTimerSettings = pendingTimerSettings
    }

    var hasPendingLocationChanges: Bool {
        (pendingChargeLocationCount ?? 0) > 0 || (pendingChargeLocationDeletionCount ?? 0) > 0
    }

    var hasPendingScheduleChanges: Bool {
        pendingGlobalChargeTimer == true
            || (pendingClimateTimerCount ?? 0) > 0
            || (pendingClimateTimerDeletionCount ?? 0) > 0
            || pendingTimerSettings == true
    }

    func unappliedChargeNowOverride(current: Bool?) -> Bool? {
        guard let pendingChargeNowOverride else { return nil }
        return pendingChargeNowOverride == current ? nil : pendingChargeNowOverride
    }
}
