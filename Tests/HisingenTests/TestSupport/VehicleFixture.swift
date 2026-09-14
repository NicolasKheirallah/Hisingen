import Foundation
@testable import Hisingen

/// Shared VehicleState fixture builder (TESTS-12): the one seam every suite constructs
/// observations with, instead of nine per-file re-declarations of the 25-line initializer.
/// The defaults reproduce what the old FormattingTests-local builder pinned; commonly
/// re-pinned fields (exterior, weather, climate, location, service, samples, ...) are
/// optional parameters so per-file builders can collapse to thin wrappers.
func vehicle(
    vin: String = "YSMTEST",
    battery: Double? = 50,
    rangeKm: Int? = 200,
    state: ChargingState = .idle,
    connection: ChargerConnection = .disconnected,
    chargingType: ChargingType = .unknown,
    powerWatts: Int? = nil,
    currentAmps: Int? = nil,
    voltageVolts: Int? = nil,
    target: Int? = 80,
    estimatedTimeToFullMinutes: Int? = nil,
    availability: VehicleAvailability = .available,
    brand: VehicleBrand? = nil,
    modelName: String? = nil,
    modelYear: String? = "2023",
    registrationNo: String? = nil,
    ownerFirstName: String? = nil,
    odometerKm: Int? = nil,
    daysToService: Int? = nil,
    distanceToServiceKm: Int? = nil,
    serviceWarning: Bool = false,
    fluidWarnings: [String] = [],
    exteriorStatus: ExteriorSnapshot? = nil,
    climateStatus: VehicleClimateStatus? = nil,
    airQuality: VehicleAirQuality? = nil,
    weather: VehicleWeather? = nil,
    location: VehicleLocation? = nil,
    unavailableFeatures: [AppFeature] = [],
    reportedBatteryCapacityKwh: Double? = nil,
    chargingSamples: [ChargingSample] = [],
    powertrain: PowertrainType = .bev,
    imageData: Data? = nil,
    fetchedAt: Date = Date(),
    reportedAt: Date? = Date(),
    dataWarnings: [String] = []
) -> VehicleState {
    // `VehicleState.model` derives its family from the model name, so an explicit brand
    // request maps to a representative model name rather than forcing a field that does
    // not exist on the state.
    let resolvedModelName: String
    switch brand {
    case .volvo: resolvedModelName = modelName ?? "XC40"
    case .polestar, nil: resolvedModelName = modelName ?? "Polestar 2"
    }
    return VehicleState(
        batteryPercentage: battery, rangeKm: rangeKm, chargingState: state,
        estimatedChargingTimeToFullMinutes: estimatedTimeToFullMinutes,
        chargeTargetPercentage: target,
        chargingPowerWatts: powerWatts, chargingCurrentAmps: currentAmps,
        chargingVoltageVolts: voltageVolts,
        chargingType: chargingType, chargerConnection: connection,
        availability: availability,
        modelName: resolvedModelName, modelYear: modelYear,
        registrationNo: registrationNo, vin: vin,
        ownerFirstName: ownerFirstName, odometerKm: odometerKm,
        daysToService: daysToService, distanceToServiceKm: distanceToServiceKm,
        serviceWarning: serviceWarning, fluidWarnings: fluidWarnings,
        exteriorStatus: exteriorStatus,
        climateStatus: climateStatus,
        airQuality: airQuality, weather: weather, location: location,
        unavailableFeatures: unavailableFeatures,
        chargingSamples: chargingSamples,
        powertrain: powertrain,
        reportedBatteryCapacityKwh: reportedBatteryCapacityKwh,
        imageData: imageData,
        fetchedAt: fetchedAt, vehicleReportedAt: reportedAt,
        dataWarnings: dataWarnings
    )
}
