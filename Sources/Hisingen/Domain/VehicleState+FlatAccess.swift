import Foundation

extension VehicleState {
    var batteryPercentage: Double? { get { energy.batteryPercentage } set { energy.batteryPercentage = newValue } }
    var rangeKm: Int? { get { energy.rangeKm } set { energy.rangeKm = newValue } }
    var chargingState: ChargingState { get { energy.chargingState } set { energy.chargingState = newValue } }
    var estimatedChargingTimeToFullMinutes: Int? { get { energy.estimatedTimeToFullMinutes } set { energy.estimatedTimeToFullMinutes = newValue } }
    var estimatedChargingTimeToTargetMinutes: Int? { get { energy.estimatedTimeToTargetMinutes } set { energy.estimatedTimeToTargetMinutes = newValue } }
    var chargeTargetPercentage: Int? { get { energy.targetPercentage } set { energy.targetPercentage = newValue } }
    var chargingPowerWatts: Int? { get { energy.powerWatts } set { energy.powerWatts = newValue } }
    var chargingCurrentAmps: Int? { get { energy.currentAmps } set { energy.currentAmps = newValue } }
    var chargingVoltageVolts: Int? { get { energy.voltageVolts } set { energy.voltageVolts = newValue } }
    var chargingType: ChargingType { get { energy.type } set { energy.type = newValue } }
    var chargerConnection: ChargerConnection { get { energy.connection } set { energy.connection = newValue } }
    var chargingCurrentLimitAmps: Int? { get { energy.currentLimitAmps } set { energy.currentLimitAmps = newValue } }
    var reportedBatteryCapacityKwh: Double? { get { energy.reportedBatteryCapacityKwh } set { energy.reportedBatteryCapacityKwh = newValue } }
    var batteryDiagnostics: BatteryDiagnostics? { get { energy.diagnostics } set { energy.diagnostics = newValue } }
    var chargingSchedules: [VehicleSchedule] { get { energy.schedules } set { energy.schedules = newValue } }
    var chargeLocations: [ChargeLocationSnapshot] { get { energy.locations } set { energy.locations = newValue } }
    var chargingSamples: [ChargingSample] { get { energy.samples } set { energy.samples = newValue } }
    var chargingSessions: [ChargingSession] { get { energy.sessions } set { energy.sessions = newValue } }

    var availability: VehicleAvailability { get { identity.availability } set { identity.availability = newValue } }
    var modelName: String? { get { identity.modelName } set { identity.modelName = newValue } }
    var modelYear: String? { get { identity.modelYear } set { identity.modelYear = newValue } }
    var registrationNo: String? { get { identity.registrationNo } set { identity.registrationNo = newValue } }
    var vin: String { get { identity.vin } set { identity.vin = newValue } }
    var ownerFirstName: String? { get { identity.ownerFirstName } set { identity.ownerFirstName = newValue } }
    var externalColour: String? { get { identity.externalColour } set { identity.externalColour = newValue } }
    var gearbox: String? { get { identity.gearbox } set { identity.gearbox = newValue } }
    var structureWeek: String? { get { identity.structureWeek } set { identity.structureWeek = newValue } }
    var internalVehicleIdentifier: String? { get { identity.internalVehicleIdentifier } set { identity.internalVehicleIdentifier = newValue } }
    var pno34: String? { get { identity.pno34 } set { identity.pno34 = newValue } }
    var accountMarket: String? { get { identity.accountMarket } set { identity.accountMarket = newValue } }
    var upholstery: String? { get { identity.upholstery } set { identity.upholstery = newValue } }
    var steeringOrientation: String? { get { identity.steeringOrientation } set { identity.steeringOrientation = newValue } }
    var imageData: Data? { get { identity.imageData } set { identity.imageData = newValue } }
    var interiorImageData: Data? { get { identity.interiorImageData } set { identity.interiorImageData = newValue } }

    var odometerKm: Int? { get { maintenance.odometerKm } set { maintenance.odometerKm = newValue } }
    var healthDetails: VehicleHealthDetails? { get { maintenance.details } set { maintenance.details = newValue } }
    var serviceInfo: ServiceSnapshot { get { maintenance.service } set { maintenance.service = newValue } }
    var warrantyInfo: VehicleWarrantyInfo? { get { maintenance.warranty } set { maintenance.warranty = newValue } }
    var frontBrakePadStatus: String? { get { maintenance.frontBrakePadStatus } set { maintenance.frontBrakePadStatus = newValue } }
    var rearBrakePadStatus: String? { get { maintenance.rearBrakePadStatus } set { maintenance.rearBrakePadStatus = newValue } }

    var isCachedSnapshot: Bool { get { freshness.isCached } set { freshness.isCached = newValue } }
    var fetchedAt: Date { get { freshness.fetchedAt } set { freshness.fetchedAt = newValue } }
    var vehicleReportedAt: Date? { get { freshness.vehicleReportedAt } set { freshness.vehicleReportedAt = newValue } }
    var readingDates: [VehicleReading: Date] { get { freshness.readingDates } set { freshness.readingDates = newValue } }
    var dataWarnings: [String] { get { freshness.dataWarnings } set { freshness.dataWarnings = newValue } }
    var unavailableFeatures: [AppFeature] { get { freshness.unavailableFeatures } set { freshness.unavailableFeatures = newValue } }
    var retainedDataCategories: [AppFeature] { get { freshness.retainedDataCategories } set { freshness.retainedDataCategories = newValue } }
    var retainedDataAt: Date? { get { freshness.retainedDataAt } set { freshness.retainedDataAt = newValue } }

    var optimisticCommandLockUntil: Date? { get { commandState.optimisticLockUntil } set { commandState.optimisticLockUntil = newValue } }

    var daysToService: Int? {
        get { serviceInfo.daysToService }
        set { serviceInfo.daysToService = newValue }
    }
    var distanceToServiceKm: Int? {
        get { serviceInfo.distanceToServiceKm }
        set { serviceInfo.distanceToServiceKm = newValue }
    }
    var serviceWarning: Bool {
        get { serviceInfo.serviceWarning }
        set { serviceInfo.serviceWarning = newValue }
    }
    var fluidWarnings: [String] {
        get { serviceInfo.fluidWarnings }
        set { serviceInfo.fluidWarnings = newValue }
    }
    var engineHoursToService: Int? {
        get { serviceInfo.engineHoursToService }
        set { serviceInfo.engineHoursToService = newValue }
    }
    var serviceTrigger: String? {
        get { serviceInfo.trigger }
        set { serviceInfo.trigger = newValue }
    }
    var preferredWorkshopId: String? {
        get { serviceInfo.preferredWorkshopID }
        set { serviceInfo.preferredWorkshopID = newValue }
    }
    var preferredWorkshopName: String? {
        get { serviceInfo.preferredWorkshopName }
        set { serviceInfo.preferredWorkshopName = newValue }
    }

    var tripMeterManualKm: Double? {
        get { tripComputer.manualTripKm }
        set { tripComputer.manualTripKm = newValue }
    }
    var tripMeterAutomaticKm: Double? {
        get { tripComputer.automaticTripKm }
        set { tripComputer.automaticTripKm = newValue }
    }
    var averageSpeedKmH: Double? {
        get { tripComputer.averageSpeedKmH }
        set { tripComputer.averageSpeedKmH = newValue }
    }
    var tripManualAverageSpeedKmH: Int? {
        get { tripComputer.manualAverageSpeedKmH }
        set { tripComputer.manualAverageSpeedKmH = newValue }
    }
    var tripAutomaticAverageSpeedKmH: Int? {
        get { tripComputer.automaticAverageSpeedKmH }
        set { tripComputer.automaticAverageSpeedKmH = newValue }
    }
    var tripComputerElectricRangeKm: Int? {
        get { tripComputer.electricRangeKm }
        set { tripComputer.electricRangeKm = newValue }
    }
    var electricDistanceKm: Double? {
        get { tripComputer.electricDistanceKm }
        set { tripComputer.electricDistanceKm = newValue }
    }
    var fuelDistanceKm: Double? {
        get { tripComputer.fuelDistanceKm }
        set { tripComputer.fuelDistanceKm = newValue }
    }
    var regeneratedEnergyKwh: Double? {
        get { tripComputer.regeneratedEnergyKwh }
        set { tripComputer.regeneratedEnergyKwh = newValue }
    }

    var fuelLevelPercent: Double? {
        get { fuelSystem.levelPercent }
        set { fuelSystem.levelPercent = newValue }
    }
    var fuelRangeKm: Int? {
        get { fuelSystem.rangeKm }
        set { fuelSystem.rangeKm = newValue }
    }
    var fuelAmountLiters: Double? {
        get { fuelSystem.amountLiters }
        set { fuelSystem.amountLiters = newValue }
    }
    var averageFuelConsumptionLPer100Km: Double? {
        get { fuelSystem.averageConsumptionLPer100Km }
        set { fuelSystem.averageConsumptionLPer100Km = newValue }
    }
    var isEngineRunning: Bool? {
        get { fuelSystem.isEngineRunning }
        set { fuelSystem.isEngineRunning = newValue }
    }
    var fuelType: String? {
        get { fuelSystem.type }
        set { fuelSystem.type = newValue }
    }
}
