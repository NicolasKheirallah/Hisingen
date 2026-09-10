import Foundation
@testable import Hisingen

extension VehicleState {
    init(
        batteryPercentage: Double?, rangeKm: Int?, chargingState: ChargingState,
        estimatedChargingTimeToFullMinutes: Int?, chargeTargetPercentage: Int?,
        chargingPowerWatts: Int?, chargingCurrentAmps: Int?, chargingVoltageVolts: Int?,
        chargingType: ChargingType, chargerConnection: ChargerConnection,
        availability: VehicleAvailability, modelName: String?, modelYear: String?,
        registrationNo: String?, vin: String, ownerFirstName: String?, odometerKm: Int?,
        daysToService: Int? = nil, distanceToServiceKm: Int? = nil, serviceWarning: Bool = false,
        fluidWarnings: [String] = [], exteriorStatus: ExteriorSnapshot? = nil,
        healthDetails: VehicleHealthDetails? = nil, softwareInfo: VehicleSoftwareInfo? = nil,
        chargingSchedules: [VehicleSchedule] = [], climateStatus: VehicleClimateStatus? = nil,
        climateTimers: [VehicleSchedule] = [], tripMeterManualKm: Double? = nil,
        tripMeterAutomaticKm: Double? = nil, connectivity: VehicleConnectivity? = nil,
        airQuality: VehicleAirQuality? = nil, batteryDiagnostics: BatteryDiagnostics? = nil,
        weather: VehicleWeather? = nil, location: VehicleLocation? = nil,
        unavailableFeatures: [AppFeature] = [],
        probedCapabilities: VehicleProbedCapabilities? = nil,
        chargingSamples: [ChargingSample] = [], chargingSessions: [ChargingSession] = [],
        powertrain: PowertrainType = .bev,
        fuelLevelPercent: Double? = nil, fuelRangeKm: Int? = nil,
        reportedBatteryCapacityKwh: Double? = nil,
        imageData: Data?, fetchedAt: Date,
        vehicleReportedAt: Date?, dataWarnings: [String]
    ) {
        self.init(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: batteryPercentage,
                rangeKm: rangeKm,
                chargingState: chargingState,
                estimatedTimeToFullMinutes: estimatedChargingTimeToFullMinutes,
                targetPercentage: chargeTargetPercentage,
                powerWatts: chargingPowerWatts,
                currentAmps: chargingCurrentAmps,
                voltageVolts: chargingVoltageVolts,
                type: chargingType,
                connection: chargerConnection,
                reportedBatteryCapacityKwh: reportedBatteryCapacityKwh,
                diagnostics: batteryDiagnostics,
                schedules: chargingSchedules,
                samples: chargingSamples,
                sessions: chargingSessions
            ),
            identity: VehicleIdentitySnapshot(
                availability: availability,
                modelName: modelName,
                modelYear: modelYear,
                registrationNo: registrationNo,
                vin: vin,
                ownerFirstName: ownerFirstName,
                imageData: imageData
            ),
            maintenance: MaintenanceAndHealthSnapshot(
                odometerKm: odometerKm,
                details: healthDetails,
                service: ServiceSnapshot(
                    daysToService: daysToService,
                    distanceToServiceKm: distanceToServiceKm,
                    serviceWarning: serviceWarning,
                    fluidWarnings: fluidWarnings
                )
            ),
            freshness: SnapshotFreshness(
                fetchedAt: fetchedAt,
                vehicleReportedAt: vehicleReportedAt,
                dataWarnings: dataWarnings,
                unavailableFeatures: unavailableFeatures
            ),
            exteriorStatus: exteriorStatus,
            softwareInfo: softwareInfo,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripComputer: TripComputerSnapshot(
                manualTripKm: tripMeterManualKm,
                automaticTripKm: tripMeterAutomaticKm
            ),
            connectivity: connectivity,
            airQuality: airQuality,
            weather: weather,
            location: location,
            probedCapabilities: probedCapabilities,
            powertrain: powertrain,
            fuelSystem: FuelSystemSnapshot(levelPercent: fuelLevelPercent, rangeKm: fuelRangeKm)
        )
    }
}
