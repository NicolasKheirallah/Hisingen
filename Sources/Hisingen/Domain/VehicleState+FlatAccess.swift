import Foundation

/// The flat surface is the presentation read path: views, formatters and insights read Vehicle
/// State field by field, and widening the cluster vocabulary would push cluster names into every
/// view.
///
/// It is deliberately read-only. Writing field by field used to be possible too, which meant the
/// merge policy, the assembly, and one-off patches all had a second way to write the same field –
/// and a field added to a cluster could be forgotten in the flat setter's mirror. Writes go
/// through the cluster that owns the field, so `VehicleState+Merging.swift` is the only production
/// code that composes a state field by field, and adding a field touches one representation.
extension VehicleState {
    var batteryPercentage: Double? { energy.batteryPercentage }
    var rangeKm: Int? { energy.rangeKm }
    var chargingState: ChargingState { energy.chargingState }
    var estimatedChargingTimeToFullMinutes: Int? { energy.estimatedTimeToFullMinutes }
    var estimatedChargingTimeToTargetMinutes: Int? { energy.estimatedTimeToTargetMinutes }
    var chargeTargetPercentage: Int? { energy.targetPercentage }
    var chargingPowerWatts: Int? { energy.powerWatts }
    var chargingCurrentAmps: Int? { energy.currentAmps }
    var chargingVoltageVolts: Int? { energy.voltageVolts }
    var chargingType: ChargingType { energy.type }
    var chargerConnection: ChargerConnection { energy.connection }
    var chargingCurrentLimitAmps: Int? { energy.currentLimitAmps }
    var reportedBatteryCapacityKwh: Double? { energy.reportedBatteryCapacityKwh }
    var batteryDiagnostics: BatteryDiagnostics? { energy.diagnostics }
    var chargingSchedules: [VehicleSchedule] { energy.schedules }
    var chargeLocations: [ChargeLocationSnapshot] { energy.locations }
    var chargingSamples: [ChargingSample] { energy.samples }
    var chargingSessions: [ChargingSession] { energy.sessions }

    var availability: VehicleAvailability { identity.availability }
    var modelName: String? { identity.modelName }
    var modelYear: String? { identity.modelYear }
    var registrationNo: String? { identity.registrationNo }
    var vin: String { identity.vin }
    var ownerFirstName: String? { identity.ownerFirstName }
    var externalColour: String? { identity.externalColour }
    var gearbox: String? { identity.gearbox }
    var structureWeek: String? { identity.structureWeek }
    var internalVehicleIdentifier: String? { identity.internalVehicleIdentifier }
    var pno34: String? { identity.pno34 }
    var accountMarket: String? { identity.accountMarket }
    var upholstery: String? { identity.upholstery }
    var steeringOrientation: String? { identity.steeringOrientation }
    var imageData: Data? { identity.imageData }
    var interiorImageData: Data? { identity.interiorImageData }

    var odometerKm: Int? { maintenance.odometerKm }
    var healthDetails: VehicleHealthDetails? { maintenance.details }
    var serviceInfo: ServiceSnapshot { maintenance.service }
    var warrantyInfo: VehicleWarrantyInfo? { maintenance.warranty }
    var frontBrakePadStatus: String? { maintenance.frontBrakePadStatus }
    var rearBrakePadStatus: String? { maintenance.rearBrakePadStatus }

    var isCachedSnapshot: Bool { freshness.isCached }
    var fetchedAt: Date { freshness.fetchedAt }
    var vehicleReportedAt: Date? { freshness.vehicleReportedAt }
    var readingDates: [VehicleReading: Date] { freshness.readingDates }
    var dataWarnings: [String] { freshness.dataWarnings }
    var unavailableFeatures: [AppFeature] { freshness.unavailableFeatures }
    var retainedDataCategories: [AppFeature] { freshness.retainedDataCategories }
    var retainedDataAt: Date? { freshness.retainedDataAt }

    var optimisticCommandLockUntil: Date? { commandState.optimisticLockUntil }

    var daysToService: Int? { serviceInfo.daysToService }
    var distanceToServiceKm: Int? { serviceInfo.distanceToServiceKm }
    var serviceWarning: Bool { serviceInfo.serviceWarning }
    var fluidWarnings: [String] { serviceInfo.fluidWarnings }
    var engineHoursToService: Int? { serviceInfo.engineHoursToService }
    var serviceTrigger: String? { serviceInfo.trigger }
    var preferredWorkshopId: String? { serviceInfo.preferredWorkshopID }
    var preferredWorkshopName: String? { serviceInfo.preferredWorkshopName }

    var tripMeterManualKm: Double? { tripComputer.manualTripKm }
    var tripMeterAutomaticKm: Double? { tripComputer.automaticTripKm }
    var averageSpeedKmH: Double? { tripComputer.averageSpeedKmH }
    var tripManualAverageSpeedKmH: Int? { tripComputer.manualAverageSpeedKmH }
    var tripAutomaticAverageSpeedKmH: Int? { tripComputer.automaticAverageSpeedKmH }
    var tripComputerElectricRangeKm: Int? { tripComputer.electricRangeKm }
    var electricDistanceKm: Double? { tripComputer.electricDistanceKm }
    var fuelDistanceKm: Double? { tripComputer.fuelDistanceKm }
    var regeneratedEnergyKwh: Double? { tripComputer.regeneratedEnergyKwh }

    var fuelLevelPercent: Double? { fuelSystem.levelPercent }
    var fuelRangeKm: Int? { fuelSystem.rangeKm }
    var fuelAmountLiters: Double? { fuelSystem.amountLiters }
    var averageFuelConsumptionLPer100Km: Double? { fuelSystem.averageConsumptionLPer100Km }
    var isEngineRunning: Bool? { fuelSystem.isEngineRunning }
    var fuelType: String? { fuelSystem.type }
}
