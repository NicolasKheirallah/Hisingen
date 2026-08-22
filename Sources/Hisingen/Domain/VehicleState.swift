import Foundation

struct CarSummary: Codable, Equatable, Sendable {
    let vin: String
    let title: String
    var modelName: String?
    var modelYear: String?
    var registrationNo: String?

    init(
        vin: String,
        title: String,
        modelName: String? = nil,
        modelYear: String? = nil,
        registrationNo: String? = nil
    ) {
        self.vin = vin
        self.title = title
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
    }

    @MainActor
    func displayTitle(format: VehicleLabelFormat? = nil, preferences: PreferencesStore = PreferencesStore()) -> String {
        preferences.formattedVehicleTitle(
            vin: vin,
            modelName: modelName ?? (title.contains(" · ") ? title.components(separatedBy: " · ").first : title),
            modelYear: modelYear ?? (title.contains(" · ") ? title.components(separatedBy: " · ").last : nil),
            registrationNo: registrationNo,
            format: format
        )
    }
}

enum ChargingState: Codable, Equatable, Sendable {
    case charging
    case smartCharging
    case paused
    case scheduled
    case idle
    case complete
    case discharging
    case fault
    case unknown(String)

    init(apiValue: String?) {
        let key = (apiValue ?? "")
            .replacingOccurrences(of: "CHARGING_STATUS_V2_", with: "")
            .replacingOccurrences(of: "CHARGING_STATUS_", with: "")
            .uppercased()
        switch key {
        case "CHARGING": self = .charging
        case "SMART_CHARGING": self = .smartCharging
        case "SMART_CHARGING_PAUSED": self = .paused
        case "SCHEDULED": self = .scheduled
        case "IDLE": self = .idle
        case "DONE": self = .complete
        case "DISCHARGING": self = .discharging
        case "ERROR", "FAULT": self = .fault
        default: self = .unknown(key.isEmpty ? "UNSPECIFIED" : key)
        }
    }

    var isActivelyCharging: Bool {
        self == .charging || self == .smartCharging
    }

    var displayName: String {
        switch self {
        case .charging: return L10n.text("Charging")
        case .smartCharging: return L10n.text("Smart charging")
        case .paused: return L10n.text("Charging paused")
        case .scheduled: return L10n.text("Scheduled")
        case .idle: return L10n.text("Idle")
        case .complete: return L10n.text("Complete")
        case .discharging: return L10n.text("Discharging")
        case .fault: return L10n.text("Fault")
        case .unknown(let value):
            let displayValue = value.replacingOccurrences(of: "_", with: " ").capitalized
            return L10n.format("Unknown (%@)", displayValue)
        }
    }
}

enum ChargerConnection: String, Codable, Sendable {
    case connected
    case disconnected
    case fault
    case unknown

    var displayName: String {
        switch self {
        case .connected: return L10n.text("Connected")
        case .disconnected: return L10n.text("Disconnected")
        case .fault: return L10n.text("Fault")
        case .unknown: return L10n.text("Unavailable")
        }
    }
}

enum ChargingType: String, Codable, Sendable {
    case ac
    case dc
    case wireless
    case none
    case unknown

    var displayName: String {
        switch self {
        case .ac: return "AC"
        case .dc: return "DC"
        case .wireless: return L10n.text("Wireless")
        case .none: return L10n.text("None")
        case .unknown: return L10n.text("Unavailable")
        }
    }
}

enum VehicleAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(reason: String?)
    case unknown

    var displayName: String {
        switch self {
        case .available: return L10n.text("Online")
        case .unavailable(let reason): return reason ?? L10n.text("Unavailable")
        case .unknown: return L10n.text("Unknown")
        }
    }
}

enum VehicleStateSeverity: Equatable, Sendable {
    case neutral
    case good
    case warning
    case critical
}

struct VehicleStateSummary: Equatable, Sendable {
    let message: String
    let severity: VehicleStateSeverity
}

/// Combustion/hybrid powertrain readings. Part of the staged `VehicleState` redesign:
/// clusters become nested snapshots so adding a field touches this type plus (optionally) one
/// computed shim on `VehicleState` — not the six-place ritual of the flat layout. Existing
/// call sites keep reading `state.fuelLevelPercent` etc. through compatibility accessors.
struct FuelSystemSnapshot: Codable, Equatable, Sendable {
    var levelPercent: Double?
    var rangeKm: Int?
    var amountLiters: Double?
    var averageConsumptionLPer100Km: Double?
    var isEngineRunning: Bool?
    /// Raw provider fuel-type string ("ELECTRIC", "DIESEL", …).
    var type: String?
}

struct VehicleState: Codable, Equatable, Sendable {
    var batteryPercentage: Double?
    var rangeKm: Int?
    var chargingState: ChargingState
    var estimatedChargingTimeToFullMinutes: Int?
    var chargeTargetPercentage: Int?
    var chargingPowerWatts: Int?
    var chargingCurrentAmps: Int?
    var chargingVoltageVolts: Int?
    var chargingType: ChargingType
    var chargerConnection: ChargerConnection
    let availability: VehicleAvailability
    let modelName: String?
    let modelYear: String?
    let registrationNo: String?
    let vin: String
    let ownerFirstName: String?
    let odometerKm: Int?
    let daysToService: Int?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
    let fluidWarnings: [String]
    var exteriorStatus: ExteriorSnapshot? = nil
    var healthDetails: VehicleHealthDetails? = nil
    var softwareInfo: VehicleSoftwareInfo? = nil
    var chargingSchedules: [VehicleSchedule] = []
    var climateStatus: VehicleClimateStatus? = nil
    var climateTimers: [VehicleSchedule] = []
    var tripMeterManualKm: Double? = nil
    var tripMeterAutomaticKm: Double? = nil
    var connectivity: VehicleConnectivity? = nil
    var airQuality: VehicleAirQuality? = nil
    var batteryDiagnostics: BatteryDiagnostics? = nil
    var weather: VehicleWeather? = nil
    var location: VehicleLocation? = nil
    var unavailableFeatures: [AppFeature] = []
    var probedCapabilities: VehicleProbedCapabilities? = nil
    var chargingSamples: [ChargingSample] = []
    var chargingSessions: [ChargingSession] = []



    var totalCombinedRangeKm: Int? {
        switch powertrain {
        case .bev:
            return rangeKm
        case .ice:
            return fuelRangeKm
        case .phev, .mildHybrid:
            if let e = rangeKm, let f = fuelRangeKm { return e + f }
            return rangeKm ?? fuelRangeKm
        case .unknown:
            if let e = rangeKm, let f = fuelRangeKm { return e + f }
            return rangeKm ?? fuelRangeKm
        }
    }

    var primaryRangeKm: Int? {
        totalCombinedRangeKm ?? rangeKm ?? fuelRangeKm
    }

    var primaryEnergyFraction: Double? {
        if powertrain == .ice {
            return fuelLevelPercent.map { $0 / 100.0 }
        }
        if let b = batteryPercentage {
            return b / 100.0
        }
        return fuelLevelPercent.map { $0 / 100.0 }
    }


    /// Provider-reported pack specification. This is not a measured battery-health value.
    var reportedBatteryCapacityKwh: Double? = nil
    var externalColour: String? = nil
    var gearbox: String? = nil
    var engineHoursToService: Int? = nil
    var averageSpeedKmH: Double? = nil
    var structureWeek: String? = nil
    var internalVehicleIdentifier: String? = nil
    var pno34: String? = nil
    var accountMarket: String? = nil
    var upholstery: String? = nil
    var wheels: String? = nil
    var packages: [String] = []
    var steeringOrientation: String? = nil
    var serviceTrigger: String? = nil
    var tripComputerElectricRangeKm: Int? = nil
    var chargingCurrentLimitAmps: Int? = nil
    /// Saved charging locations from Polestar's Chronos ChargeLocationService. Populated when
    /// remote-charging features are enabled; empty for Volvo (no official equivalent).
    var chargeLocations: [ChargeLocationSnapshot] = []
    var interiorImageData: Data? = nil
    var warrantyInfo: VehicleWarrantyInfo? = nil
    var optimisticCommandLockUntil: Date? = nil
    var electricDistanceKm: Double? = nil
    var fuelDistanceKm: Double? = nil
    var regeneratedEnergyKwh: Double? = nil
    var frontBrakePadStatus: String? = nil
    var rearBrakePadStatus: String? = nil
    var preferredWorkshopId: String? = nil
    var preferredWorkshopName: String? = nil
    var vehicleErrors: [VehicleChronosError] = []
    var otaCapabilities: VehicleOTACapabilities? = nil

    // MARK: Fuel/engine
    // Clustered storage: the persisted snapshot format encodes `fuelSystem` as one nested
    // value (see `encode(to:)`); the decoder still accepts the flat legacy keys so snapshots
    // written before the migration keep loading.

    var powertrain: PowertrainType = .bev
    var fuelSystem: FuelSystemSnapshot = .init()

    /// Compatibility accessors over the cluster. Existing call sites and tests read/write
    /// these; prefer `state.fuelSystem.<field>` in new code.
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

    /// True when this state came from the on-disk snapshot rather than a live fetch.
    ///
    /// `cacheableCopy` drops most telemetry, so a cached state is not "the vehicle has no
    /// tyres data" — it is "we could not ask". Cards use this to show an unavailable badge
    /// instead of silently disappearing.
    var isCachedSnapshot: Bool = false
    let imageData: Data?
    var fetchedAt: Date
    var vehicleReportedAt: Date?
    let dataWarnings: [String]
    var retainedDataCategories: [AppFeature] = []
    var retainedDataAt: Date? = nil

    mutating func applyLiveUpdate(_ update: VehicleLiveUpdate, receivedAt: Date = Date()) {
        switch update {
        case .battery(let battery):
            batteryPercentage = battery.batteryPercentage ?? batteryPercentage
            rangeKm = battery.rangeKm ?? rangeKm
            estimatedChargingTimeToFullMinutes = battery.estimatedChargingTimeToFullMinutes
                ?? estimatedChargingTimeToFullMinutes
            chargingState = battery.chargingState ?? chargingState
            if battery.chargerConnection != .unknown { chargerConnection = battery.chargerConnection }
            if battery.chargingType != .unknown { chargingType = battery.chargingType }
            chargingPowerWatts = battery.chargingPowerWatts ?? chargingPowerWatts
            chargingCurrentAmps = battery.chargingCurrentAmps ?? chargingCurrentAmps
            chargingVoltageVolts = battery.chargingVoltageVolts ?? chargingVoltageVolts
            batteryDiagnostics = battery.diagnostics
            vehicleReportedAt = battery.reportedAt ?? vehicleReportedAt
        case .exterior(let exterior, let reportedAt):
            exteriorStatus = exterior.merging(previous: exteriorStatus)
            vehicleReportedAt = reportedAt ?? vehicleReportedAt
        }
        fetchedAt = receivedAt
        isCachedSnapshot = false
    }

    init(
        batteryPercentage: Double?, rangeKm: Int?, chargingState: ChargingState,
        estimatedChargingTimeToFullMinutes: Int?, chargeTargetPercentage: Int?,
        chargingPowerWatts: Int?, chargingCurrentAmps: Int?, chargingVoltageVolts: Int?,
        chargingType: ChargingType, chargerConnection: ChargerConnection,
        availability: VehicleAvailability, modelName: String?, modelYear: String?,
        registrationNo: String?, vin: String, ownerFirstName: String?, odometerKm: Int?,
        daysToService: Int?, distanceToServiceKm: Int?, serviceWarning: Bool,
        fluidWarnings: [String], exteriorStatus: ExteriorSnapshot? = nil,
        healthDetails: VehicleHealthDetails? = nil, softwareInfo: VehicleSoftwareInfo? = nil,
        chargingSchedules: [VehicleSchedule] = [], climateStatus: VehicleClimateStatus? = nil,
        climateTimers: [VehicleSchedule] = [], tripMeterManualKm: Double? = nil,
        tripMeterAutomaticKm: Double? = nil, connectivity: VehicleConnectivity? = nil,
        airQuality: VehicleAirQuality? = nil, batteryDiagnostics: BatteryDiagnostics? = nil,
        weather: VehicleWeather? = nil,
        location: VehicleLocation? = nil,
        unavailableFeatures: [AppFeature] = [],
        probedCapabilities: VehicleProbedCapabilities? = nil,
        chargingSamples: [ChargingSample] = [],
        chargingSessions: [ChargingSession] = [],
        powertrain: PowertrainType = .bev,
        fuelLevelPercent: Double? = nil,
        fuelRangeKm: Int? = nil,
        reportedBatteryCapacityKwh: Double? = nil,
        imageData: Data?, fetchedAt: Date,
        vehicleReportedAt: Date?, dataWarnings: [String]
    ) {
        self.batteryPercentage = batteryPercentage
        self.rangeKm = rangeKm
        self.chargingState = chargingState
        self.estimatedChargingTimeToFullMinutes = estimatedChargingTimeToFullMinutes
        self.chargeTargetPercentage = chargeTargetPercentage
        self.chargingPowerWatts = chargingPowerWatts
        self.chargingCurrentAmps = chargingCurrentAmps
        self.chargingVoltageVolts = chargingVoltageVolts
        self.chargingType = chargingType
        self.chargerConnection = chargerConnection
        self.availability = availability
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
        self.vin = vin
        self.ownerFirstName = ownerFirstName
        self.odometerKm = odometerKm
        self.daysToService = daysToService
        self.distanceToServiceKm = distanceToServiceKm
        self.serviceWarning = serviceWarning
        self.fluidWarnings = fluidWarnings
        self.exteriorStatus = exteriorStatus
        self.healthDetails = healthDetails
        self.softwareInfo = softwareInfo
        self.chargingSchedules = chargingSchedules
        self.climateStatus = climateStatus
        self.climateTimers = climateTimers
        self.tripMeterManualKm = tripMeterManualKm
        self.tripMeterAutomaticKm = tripMeterAutomaticKm
        self.connectivity = connectivity
        self.airQuality = airQuality
        self.batteryDiagnostics = batteryDiagnostics
        self.weather = weather
        self.location = location
        self.unavailableFeatures = unavailableFeatures
        self.probedCapabilities = probedCapabilities
        self.chargingSamples = chargingSamples
        self.chargingSessions = chargingSessions
        self.powertrain = powertrain
        fuelSystem = FuelSystemSnapshot(
            levelPercent: fuelLevelPercent,
            rangeKm: fuelRangeKm
        )
        self.reportedBatteryCapacityKwh = reportedBatteryCapacityKwh
        self.imageData = imageData
        self.fetchedAt = fetchedAt
        self.vehicleReportedAt = vehicleReportedAt
        self.dataWarnings = dataWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case batteryPercentage, rangeKm, chargingState, estimatedChargingTimeToFullMinutes
        case chargeTargetPercentage, chargingPowerWatts, chargingCurrentAmps, chargingVoltageVolts
        case chargingType, chargerConnection, availability, modelName, modelYear, registrationNo
        case vin, ownerFirstName, odometerKm, daysToService, distanceToServiceKm, serviceWarning
        case fluidWarnings, exteriorStatus, healthDetails, softwareInfo, chargingSchedules
        case climateStatus, climateTimers, tripMeterManualKm, tripMeterAutomaticKm, connectivity
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
        case upholstery, wheels, packages, steeringOrientation, serviceTrigger, tripComputerElectricRangeKm, chargingCurrentLimitAmps
        case interiorImageData, warrantyInfo
        case chargeLocations
        case electricDistanceKm, fuelDistanceKm, regeneratedEnergyKwh, frontBrakePadStatus, rearBrakePadStatus
        case preferredWorkshopId, preferredWorkshopName
        case retainedDataCategories, retainedDataAt
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            batteryPercentage: try values.decodeIfPresent(Double.self, forKey: .batteryPercentage),
            rangeKm: try values.decodeIfPresent(Int.self, forKey: .rangeKm),
            chargingState: try values.decode(ChargingState.self, forKey: .chargingState),
            estimatedChargingTimeToFullMinutes: try values.decodeIfPresent(Int.self, forKey: .estimatedChargingTimeToFullMinutes),
            chargeTargetPercentage: try values.decodeIfPresent(Int.self, forKey: .chargeTargetPercentage),
            chargingPowerWatts: try values.decodeIfPresent(Int.self, forKey: .chargingPowerWatts),
            chargingCurrentAmps: try values.decodeIfPresent(Int.self, forKey: .chargingCurrentAmps),
            chargingVoltageVolts: try values.decodeIfPresent(Int.self, forKey: .chargingVoltageVolts),
            chargingType: try values.decode(ChargingType.self, forKey: .chargingType),
            chargerConnection: try values.decode(ChargerConnection.self, forKey: .chargerConnection),
            availability: try values.decode(VehicleAvailability.self, forKey: .availability),
            modelName: try values.decodeIfPresent(String.self, forKey: .modelName),
            modelYear: try values.decodeIfPresent(String.self, forKey: .modelYear),
            registrationNo: try values.decodeIfPresent(String.self, forKey: .registrationNo),
            vin: try values.decode(String.self, forKey: .vin),
            ownerFirstName: try values.decodeIfPresent(String.self, forKey: .ownerFirstName),
            odometerKm: try values.decodeIfPresent(Int.self, forKey: .odometerKm),
            daysToService: try values.decodeIfPresent(Int.self, forKey: .daysToService),
            distanceToServiceKm: try values.decodeIfPresent(Int.self, forKey: .distanceToServiceKm),
            serviceWarning: try values.decode(Bool.self, forKey: .serviceWarning),
            fluidWarnings: try values.decode([String].self, forKey: .fluidWarnings),
            exteriorStatus: try values.decodeIfPresent(ExteriorSnapshot.self, forKey: .exteriorStatus),
            healthDetails: try values.decodeIfPresent(VehicleHealthDetails.self, forKey: .healthDetails),
            softwareInfo: try values.decodeIfPresent(VehicleSoftwareInfo.self, forKey: .softwareInfo),
            chargingSchedules: try values.decodeIfPresent([VehicleSchedule].self, forKey: .chargingSchedules) ?? [],
            climateStatus: try values.decodeIfPresent(VehicleClimateStatus.self, forKey: .climateStatus),
            climateTimers: try values.decodeIfPresent([VehicleSchedule].self, forKey: .climateTimers) ?? [],
            tripMeterManualKm: try values.decodeIfPresent(Double.self, forKey: .tripMeterManualKm),
            tripMeterAutomaticKm: try values.decodeIfPresent(Double.self, forKey: .tripMeterAutomaticKm),
            connectivity: try values.decodeIfPresent(VehicleConnectivity.self, forKey: .connectivity),
            airQuality: try values.decodeIfPresent(VehicleAirQuality.self, forKey: .airQuality),
            batteryDiagnostics: try values.decodeIfPresent(BatteryDiagnostics.self, forKey: .batteryDiagnostics),
            weather: try values.decodeIfPresent(VehicleWeather.self, forKey: .weather),
            location: try values.decodeIfPresent(VehicleLocation.self, forKey: .location),
            unavailableFeatures: try values.decodeIfPresent([AppFeature].self, forKey: .unavailableFeatures) ?? [],
            probedCapabilities: try values.decodeIfPresent(VehicleProbedCapabilities.self, forKey: .probedCapabilities),
            chargingSamples: try values.decodeIfPresent([ChargingSample].self, forKey: .chargingSamples) ?? [],
            chargingSessions: try values.decodeIfPresent([ChargingSession].self, forKey: .chargingSessions) ?? [],
            powertrain: try values.decodeIfPresent(PowertrainType.self, forKey: .powertrain) ?? .bev,
            fuelLevelPercent: nil,
            fuelRangeKm: nil,
            reportedBatteryCapacityKwh: try values.decodeIfPresent(Double.self, forKey: .reportedBatteryCapacityKwh),
            imageData: try values.decodeIfPresent(Data.self, forKey: .imageData),
            fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
            vehicleReportedAt: try values.decodeIfPresent(Date.self, forKey: .vehicleReportedAt),
            dataWarnings: try values.decode([String].self, forKey: .dataWarnings)
        )
        self.chargeLocations = try values.decodeIfPresent([ChargeLocationSnapshot].self, forKey: .chargeLocations) ?? []
        self.externalColour = try values.decodeIfPresent(String.self, forKey: .externalColour)
        self.gearbox = try values.decodeIfPresent(String.self, forKey: .gearbox)
        self.engineHoursToService = try values.decodeIfPresent(Int.self, forKey: .engineHoursToService)
        self.averageSpeedKmH = try values.decodeIfPresent(Double.self, forKey: .averageSpeedKmH)
        // Fuel/engine cluster: prefer the nested encoding; fall back to the flat legacy keys
        // so snapshots persisted before the migration keep decoding.
        if let clustered = try values.decodeIfPresent(FuelSystemSnapshot.self, forKey: .fuelSystem) {
            fuelSystem = clustered
        } else {
            func read<T: Decodable>(_ key: String) throws -> T? {
                guard let key = CodingKeys(stringValue: key) else { return nil }
                return try values.decodeIfPresent(T.self, forKey: key)
            }
            fuelSystem = FuelSystemSnapshot(
                levelPercent: try read("fuelLevelPercent"),
                rangeKm: try read("fuelRangeKm"),
                amountLiters: try read("fuelAmountLiters"),
                averageConsumptionLPer100Km: try read("averageFuelConsumptionLPer100Km"),
                isEngineRunning: try read("isEngineRunning"),
                type: try read("fuelType")
            )
        }
        self.structureWeek = try values.decodeIfPresent(String.self, forKey: .structureWeek)
        self.internalVehicleIdentifier = try values.decodeIfPresent(String.self, forKey: .internalVehicleIdentifier)
        self.pno34 = try values.decodeIfPresent(String.self, forKey: .pno34)
        self.accountMarket = try values.decodeIfPresent(String.self, forKey: .accountMarket)
        self.upholstery = try values.decodeIfPresent(String.self, forKey: .upholstery)
        self.wheels = try values.decodeIfPresent(String.self, forKey: .wheels)
        self.packages = try values.decodeIfPresent([String].self, forKey: .packages) ?? []
        self.steeringOrientation = try values.decodeIfPresent(String.self, forKey: .steeringOrientation)
        self.serviceTrigger = try values.decodeIfPresent(String.self, forKey: .serviceTrigger)
        self.tripComputerElectricRangeKm = try values.decodeIfPresent(Int.self, forKey: .tripComputerElectricRangeKm)
        self.chargingCurrentLimitAmps = try values.decodeIfPresent(Int.self, forKey: .chargingCurrentLimitAmps)
        self.interiorImageData = try values.decodeIfPresent(Data.self, forKey: .interiorImageData)
        self.warrantyInfo = try values.decodeIfPresent(VehicleWarrantyInfo.self, forKey: .warrantyInfo)
        self.electricDistanceKm = try values.decodeIfPresent(Double.self, forKey: .electricDistanceKm)
        self.fuelDistanceKm = try values.decodeIfPresent(Double.self, forKey: .fuelDistanceKm)
        self.regeneratedEnergyKwh = try values.decodeIfPresent(Double.self, forKey: .regeneratedEnergyKwh)
        self.frontBrakePadStatus = try values.decodeIfPresent(String.self, forKey: .frontBrakePadStatus)
        self.rearBrakePadStatus = try values.decodeIfPresent(String.self, forKey: .rearBrakePadStatus)
        self.preferredWorkshopId = try values.decodeIfPresent(String.self, forKey: .preferredWorkshopId)
        self.preferredWorkshopName = try values.decodeIfPresent(String.self, forKey: .preferredWorkshopName)
        self.retainedDataCategories = try values.decodeIfPresent([AppFeature].self, forKey: .retainedDataCategories) ?? []
        self.retainedDataAt = try values.decodeIfPresent(Date.self, forKey: .retainedDataAt)
    }

    /// Encodes the clustered layout only (`fuelSystem` under its own key). The flat legacy
    /// fuel keys are decode-only; re-encoding them is unnecessary since every writer of a
    /// snapshot also understands the nested form.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(batteryPercentage, forKey: .batteryPercentage)
        try values.encode(rangeKm, forKey: .rangeKm)
        try values.encode(chargingState, forKey: .chargingState)
        try values.encode(estimatedChargingTimeToFullMinutes, forKey: .estimatedChargingTimeToFullMinutes)
        try values.encode(chargeTargetPercentage, forKey: .chargeTargetPercentage)
        try values.encode(chargingPowerWatts, forKey: .chargingPowerWatts)
        try values.encode(chargingCurrentAmps, forKey: .chargingCurrentAmps)
        try values.encode(chargingVoltageVolts, forKey: .chargingVoltageVolts)
        try values.encode(chargingType, forKey: .chargingType)
        try values.encode(chargerConnection, forKey: .chargerConnection)
        try values.encode(availability, forKey: .availability)
        try values.encode(modelName, forKey: .modelName)
        try values.encode(modelYear, forKey: .modelYear)
        try values.encode(registrationNo, forKey: .registrationNo)
        try values.encode(vin, forKey: .vin)
        try values.encode(ownerFirstName, forKey: .ownerFirstName)
        try values.encode(odometerKm, forKey: .odometerKm)
        try values.encode(daysToService, forKey: .daysToService)
        try values.encode(distanceToServiceKm, forKey: .distanceToServiceKm)
        try values.encode(serviceWarning, forKey: .serviceWarning)
        try values.encode(fluidWarnings, forKey: .fluidWarnings)
        try values.encodeIfPresent(exteriorStatus, forKey: .exteriorStatus)
        try values.encodeIfPresent(healthDetails, forKey: .healthDetails)
        try values.encodeIfPresent(softwareInfo, forKey: .softwareInfo)
        try values.encode(chargingSchedules, forKey: .chargingSchedules)
        try values.encodeIfPresent(climateStatus, forKey: .climateStatus)
        try values.encode(climateTimers, forKey: .climateTimers)
        try values.encode(tripMeterManualKm, forKey: .tripMeterManualKm)
        try values.encode(tripMeterAutomaticKm, forKey: .tripMeterAutomaticKm)
        try values.encodeIfPresent(connectivity, forKey: .connectivity)
        try values.encodeIfPresent(airQuality, forKey: .airQuality)
        try values.encodeIfPresent(batteryDiagnostics, forKey: .batteryDiagnostics)
        try values.encodeIfPresent(weather, forKey: .weather)
        try values.encodeIfPresent(location, forKey: .location)
        try values.encode(unavailableFeatures, forKey: .unavailableFeatures)
        try values.encodeIfPresent(probedCapabilities, forKey: .probedCapabilities)
        try values.encode(chargingSamples, forKey: .chargingSamples)
        try values.encode(chargingSessions, forKey: .chargingSessions)
        try values.encode(imageData, forKey: .imageData)
        try values.encode(fetchedAt, forKey: .fetchedAt)
        try values.encode(vehicleReportedAt, forKey: .vehicleReportedAt)
        try values.encode(dataWarnings, forKey: .dataWarnings)
        try values.encode(powertrain, forKey: .powertrain)
        // Nested cluster is the current persisted layout; flat fuel keys are decode-only.
        try values.encode(fuelSystem, forKey: .fuelSystem)
        try values.encode(reportedBatteryCapacityKwh, forKey: .reportedBatteryCapacityKwh)
        try values.encodeIfPresent(externalColour, forKey: .externalColour)
        try values.encodeIfPresent(gearbox, forKey: .gearbox)
        try values.encodeIfPresent(engineHoursToService, forKey: .engineHoursToService)
        try values.encodeIfPresent(averageSpeedKmH, forKey: .averageSpeedKmH)
        try values.encodeIfPresent(structureWeek, forKey: .structureWeek)
        try values.encodeIfPresent(internalVehicleIdentifier, forKey: .internalVehicleIdentifier)
        try values.encodeIfPresent(pno34, forKey: .pno34)
        try values.encodeIfPresent(accountMarket, forKey: .accountMarket)
        try values.encodeIfPresent(upholstery, forKey: .upholstery)
        try values.encodeIfPresent(wheels, forKey: .wheels)
        try values.encode(packages, forKey: .packages)
        try values.encodeIfPresent(steeringOrientation, forKey: .steeringOrientation)
        try values.encodeIfPresent(serviceTrigger, forKey: .serviceTrigger)
        try values.encode(tripComputerElectricRangeKm, forKey: .tripComputerElectricRangeKm)
        try values.encode(chargingCurrentLimitAmps, forKey: .chargingCurrentLimitAmps)
        try values.encodeIfPresent(interiorImageData, forKey: .interiorImageData)
        try values.encodeIfPresent(warrantyInfo, forKey: .warrantyInfo)
        try values.encode(chargeLocations, forKey: .chargeLocations)
        try values.encode(electricDistanceKm, forKey: .electricDistanceKm)
        try values.encode(fuelDistanceKm, forKey: .fuelDistanceKm)
        try values.encode(regeneratedEnergyKwh, forKey: .regeneratedEnergyKwh)
        try values.encode(frontBrakePadStatus, forKey: .frontBrakePadStatus)
        try values.encode(rearBrakePadStatus, forKey: .rearBrakePadStatus)
        try values.encodeIfPresent(preferredWorkshopId, forKey: .preferredWorkshopId)
        try values.encodeIfPresent(preferredWorkshopName, forKey: .preferredWorkshopName)
        try values.encode(retainedDataCategories, forKey: .retainedDataCategories)
        try values.encode(retainedDataAt, forKey: .retainedDataAt)
    }

    var formattedBuildWeek: String? {
        guard let raw = structureWeek?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 6 else {
            return structureWeek
        }
        let year = raw.prefix(4)
        let week = raw.suffix(2)
        return "\(year) · W\(week)"
    }

    var formattedServiceTrigger: String? {
        guard let raw = serviceTrigger?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.contains("CALENDAR") || raw.contains("TIME") {
            return L10n.text("Time")
        } else if raw.contains("DISTANCE") || raw.contains("MILE") || raw.contains("KM") {
            return L10n.text("Distance")
        } else if raw.contains("HOUR") || raw.contains("ENGINE") {
            return L10n.text("Operating hours")
        }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var formattedSteeringOrientation: String? {
        guard let raw = steeringOrientation?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if upper == "LEFT" || upper.contains("LHD") {
            return L10n.text("Left-hand drive")
        } else if upper == "RIGHT" || upper.contains("RHD") {
            return L10n.text("Right-hand drive")
        }
        return raw.capitalized
    }

    var isCharging: Bool { chargingState.isActivelyCharging }

    var isClimateActive: Bool {
        guard let activity = climateStatus?.activity else { return false }
        return activity == .active || activity == .heating || activity == .cooling || activity == .ventilating || activity == .starting
    }

    /// Year/powertrain-aware refinement on top of `VehicleModelFamily.nominalBatteryCapacityKwh`
    /// (the base per-model table) — not an independent capacity table. Falls through to the base
    /// table for anything without a known year-specific pack revision or a PHEV-specific figure.
    var factoryNominalBatteryCapacityKwh: Double {
        guard model.isKnown else { return 0.0 }
        let yearInt = modelYear.flatMap(Int.init)
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40),
           let yearInt, yearInt >= 2024 {
            return 82.0
        }
        if powertrain == .phev {
            guard let yearInt else { return model.nominalBatteryCapacityKwh }
            return yearInt >= 2022 ? 18.8 : 11.6
        }
        return model.nominalBatteryCapacityKwh
    }

    var factoryUsableBatteryCapacityKwh: Double {
        guard model.isKnown else { return 0.0 }
        let yearInt = modelYear.flatMap(Int.init)
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40),
           let yearInt, yearInt >= 2024 {
            return 79.0
        }
        if powertrain == .phev {
            guard let yearInt else { return model.nominalUsableCapacityKwh }
            return yearInt >= 2022 ? 14.9 : 9.1
        }
        return model.nominalUsableCapacityKwh
    }

    var effectiveNominalBatteryCapacityKwh: Double {
        factoryNominalBatteryCapacityKwh
    }

    var batteryDegradationPercent: Double? {
        // Neither provider exposes a validated *measured* capacity or SoH value — this property
        // specifically represents that absence and must stay `nil` rather than infer one from
        // age, mileage, or a specification capacity. A separate, clearly-labeled *calculated*
        // estimate that does combine those signals exists at `BatteryHealthEstimator.estimate` —
        // it returns a distinct `BatteryHealthEstimate` type precisely so a calculated figure can
        // never be mistaken for what this property represents.
        return nil
    }

    var batteryStateOfHealthPercent: Double? {
        guard powertrain.hasElectricRange, let deg = batteryDegradationPercent else { return nil }
        let soh = max(50.0, min(100.0, 100.0 - deg))
        return ((soh * 10).rounded()) / 10.0
    }

    var configuredUsableBatteryCapacityKwh: Double {
        // This value is suitable for nominal charging-energy estimates only.
        return factoryUsableBatteryCapacityKwh
    }

    /// Every capacity figure below is interpolated from `factoryNominalBatteryCapacityKwh`/
    /// `factoryUsableBatteryCapacityKwh` — the same computed values shown elsewhere in the UI —
    /// rather than restated as separate hardcoded numbers, so this description can't silently
    /// drift out of sync with them. Only the chemistry/module/voltage prose is hand-authored.
    ///
    /// Some branches below (Polestar 2 and Volvo XC40-family "Standard Range," Volvo EX30
    /// "Standard Range") describe real-world pack variants that exist in the market but that
    /// `VehicleModelFamily.nominalBatteryCapacityKwh` has no signal to distinguish from the
    /// higher-capacity variant of the same model — the current capacity table only knows one
    /// figure per model family (plus year), not per-trim. Those branches are therefore currently
    /// unreachable; they're left in place, clearly labelled, rather than silently deleted, in
    /// case a future capability signal makes the distinction possible.
    var batteryPackDescription: String {
        let nominal = factoryNominalBatteryCapacityKwh
        let usable = factoryUsableBatteryCapacityKwh
        // Formatted with the plain (locale-invariant) `String(format:)` overload — matching
        // `Format.swift`'s convention for every other numeric readout in the app — rather than
        // `L10n.format`, whose `locale:` argument follows the interface language/system region
        // and would otherwise render these as "78,0 kWh" under a comma-decimal locale.
        let nominalText = String(format: "%.1f", nominal)
        let usableText = String(format: "%.1f", usable)
        let nominalWhole = String(format: "%.0f", nominal)
        switch model {
        case .polestar2:
            if nominal >= 80.0 {
                return L10n.format("%@ kWh Long Range (CATL · 27 Modules / 324 Cells · 400V)", nominalText)
            } else if nominal >= 75.0 {
                return L10n.format("%@ kWh Long Range (LG Energy / CATL · 27 Modules / 324 Cells · 400V)", nominalText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("69.0 kWh Standard Range (CATL · 24 Modules / 288 Cells · 400V)")
            }
        case .polestar3:
            return L10n.format("%@ kWh Extended Range (CATL · 17 Modules / 204 Cells · 400V)", nominalText)
        case .polestar4:
            return L10n.format("%@ kWh Long Range (CATL / VREMT · %@ kWh Nominal · 400V)", nominalWhole, nominalWhole)
        case .polestar1:
            return L10n.format("%@ kWh High-Output Hybrid (%@ kWh Usable · Triple Pack)", nominalText, usableText)
        case .volvoEX30:
            if nominal >= 65.0 {
                return L10n.format("%@ kWh Extended Range (NMC · %@ kWh Usable · 400V)", nominalText, usableText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("51.0 kWh Standard Range (LFP · 49.0 kWh Usable · 400V)")
            }
        case .volvoEX90, .volvoES90:
            return L10n.format("%@ kWh Extended Range (CATL · %@ kWh Usable · 400V)", nominalText, usableText)
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40:
            if nominal >= 80.0 {
                return L10n.format("%@ kWh Long Range (CATL · %@ kWh Usable · 400V)", nominalText, usableText)
            } else if nominal >= 75.0 {
                return L10n.format("%@ kWh Long Range (LG Energy / CATL · %@ kWh Usable · 400V)", nominalText, usableText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("69.0 kWh Standard Range (CATL · 64.0 kWh Usable · 400V)")
            }
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90:
            if powertrain == .phev {
                if nominal >= 16.0 {
                    return L10n.format("%@ kWh T8 Recharge PHEV (96 Cells · %@ kWh Usable)", nominalText, usableText)
                } else {
                    return L10n.format("%@ kWh T8 Twin Engine PHEV (%@ kWh Usable)", nominalText, usableText)
                }
            }
            return L10n.format("%@ kWh High-Voltage Pack", nominalText)
        default:
            if nominal > 0 {
                return L10n.format("%@ kWh Lithium-ion Pack", nominalText)
            }
            return L10n.text("High-Voltage Traction Battery")
        }
    }

    var batteryHealthStatus: String {
        guard let soh = batteryStateOfHealthPercent else { return L10n.text("Unavailable") }
        if soh >= 95.0 { return L10n.text("Optimal") }
        if soh >= 85.0 { return L10n.text("Good") }
        if soh >= 75.0 { return L10n.text("Normal") }
        return L10n.text("Service Advised")
    }

    var stateSummary: VehicleStateSummary {
        if exteriorStatus?.alarmTriggered == true {
            return VehicleStateSummary(message: L10n.text("Alarm triggered"), severity: .critical)
        }
        if let battery = batteryPercentage, battery <= 15, !isCharging, powertrain.hasElectricRange {
            return VehicleStateSummary(message: L10n.text("Low battery"), severity: .critical)
        }
        if let fuel = fuelLevelPercent, fuel <= 12, powertrain.hasFuelRange {
            return VehicleStateSummary(message: L10n.text("Low fuel"), severity: .critical)
        }
        if let openings = exteriorStatus?.itemsNeedingAttention, !openings.isEmpty {
            if openings.count == 1, let only = openings.first {
                return VehicleStateSummary(message: L10n.format("%@ open", only.displayName), severity: .warning)
            }
            return VehicleStateSummary(message: L10n.format("%d items open", openings.count), severity: .warning)
        }
        if exteriorStatus?.isLocked == false {
            return VehicleStateSummary(message: L10n.text("Unlocked"), severity: .warning)
        }
        if chargingState == .fault {
            return VehicleStateSummary(message: L10n.text("Charging fault"), severity: .warning)
        }
        if serviceWarning {
            return VehicleStateSummary(message: L10n.text("Service warning"), severity: .warning)
        }
        if let fluid = fluidWarnings.first {
            return VehicleStateSummary(message: fluid, severity: .warning)
        }
        if let warning = healthDetails?.warnings.first {
            return VehicleStateSummary(message: warning.displayName, severity: .warning)
        }
        if healthDetails?.tyres.contains(where: { $0.warning.needsAttention }) == true {
            return VehicleStateSummary(message: L10n.text("Tyre pressure warning"), severity: .warning)
        }
        if softwareInfo?.hasActionableFailure() == true {
            return VehicleStateSummary(message: L10n.text("Software update failed"), severity: .warning)
        }
        if case .unavailable = availability {
            return VehicleStateSummary(message: availability.displayName, severity: .warning)
        }
        if isEngineRunning == true {
            return VehicleStateSummary(message: L10n.text("Engine running"), severity: .good)
        }
        if exteriorStatus?.isLocked == true {
            return VehicleStateSummary(message: L10n.text("Vehicle secured"), severity: .good)
        }
        return VehicleStateSummary(message: L10n.text("No active warnings reported"), severity: .neutral)
    }

    var capabilityProfile: VehicleCapabilityProfile {
        VehicleCapabilityProfile(modelName: modelName, vin: vin, probed: probedCapabilities)
    }

    var isPluggedIn: Bool? {
        switch chargerConnection {
        case .connected, .fault: return true
        case .disconnected: return false
        case .unknown: return nil
        }
    }

    var isComplete: Bool {
        if chargingState == .complete { return true }
        guard let batteryPercentage else { return false }
        if let chargeTargetPercentage {
            return batteryPercentage >= Double(chargeTargetPercentage) - 0.5
        }
        return batteryPercentage >= 99.5
    }

    var model: VehicleModel { VehicleModel(modelName: modelName) }

    var isVolvo: Bool {
        vin.uppercased().hasPrefix("YV")
    }

    /// Current vehicle-reported range at the present SOC compared with a WLTP reference at the
    /// same SOC — the model-family table, or a VIN-specific `specification` override entered in
    /// Settings when one exists. This is a range comparison, not battery State of Health.
    /// `battery >= 20` matches the same low-SOC cutoff `BatteryHealthEstimator`'s range signal
    /// uses, since the vehicle's own range readout gets noisier as it approaches empty.
    func currentRangeVsModelWltpPercent(specification: VehicleSpecificationOverride? = nil) -> Double? {
        guard let battery = batteryPercentage, battery >= 20,
              let range = rangeKm, range > 0 else { return nil }
        let referenceRange = specification?.wltpRangeKm
            ?? (model.hasModelReferenceSpecs ? model.nominalWltpRangeKm : nil)
        guard let referenceRange, referenceRange > 0 else { return nil }
        let expectedRangeAtCurrentSoC = referenceRange * (battery / 100.0)
        guard expectedRangeAtCurrentSoC > 0 else { return nil }
        return (Double(range) / expectedRangeAtCurrentSoC * 1000).rounded() / 10
    }

    var estimatedChargingCompletion: Date? {
        guard isCharging, let minutes = estimatedChargingTimeToFullMinutes, minutes > 0 else { return nil }
        guard !isStale() else { return nil }
        let completion = (vehicleReportedAt ?? fetchedAt).addingTimeInterval(TimeInterval(minutes * 60))
        return completion > Date() ? completion : nil
    }

    var formattedCompletionTime: String? {
        guard let minutes = estimatedChargingTimeToFullMinutes, minutes > 0, isCharging else { return nil }
        return Format.completionTime(from: minutes, baseDate: vehicleReportedAt ?? fetchedAt)
    }

    func formattedChargingRate(unit: DistanceUnit) -> String? {
        guard let watts = chargingPowerWatts, watts > 0, isCharging else { return nil }


        guard let consumption = model.averageConsumptionWhPerKm else { return nil }
        return Format.chargingRateFormatted(powerWatts: watts, consumptionWhPerKm: consumption, unit: unit)
    }

    @MainActor
    var formattedChargingRate: String? {
        formattedChargingRate(unit: PreferencesStore().distanceUnit)
    }

    var freshnessDescription: String {
        if isStale() {
            return L10n.format("Vehicle asleep · Updated %@", Format.relativeAge(since: dataTimestamp))
        }
        return L10n.format("Updated %@", Format.relativeAge(since: dataTimestamp))
    }

    var dataTimestamp: Date { vehicleReportedAt ?? fetchedAt }

    func isStale(at date: Date = Date()) -> Bool {


        if date.timeIntervalSince(fetchedAt) < 120 { return false }
        let threshold: TimeInterval = isCharging ? 15 * 60 : 60 * 60
        return date.timeIntervalSince(dataTimestamp) > threshold
    }

    var cacheableCopy: VehicleState {
        var copy = VehicleState(
            batteryPercentage: batteryPercentage,
            rangeKm: rangeKm,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: estimatedChargingTimeToFullMinutes,
            chargeTargetPercentage: chargeTargetPercentage,
            chargingPowerWatts: chargingPowerWatts,
            chargingCurrentAmps: chargingCurrentAmps,
            chargingVoltageVolts: chargingVoltageVolts,
            chargingType: chargingType,
            chargerConnection: chargerConnection,
            availability: availability,
            modelName: modelName,
            modelYear: modelYear,
            registrationNo: nil,
            vin: vin,
            ownerFirstName: nil,
            odometerKm: odometerKm,
            daysToService: daysToService,
            distanceToServiceKm: distanceToServiceKm,
            serviceWarning: serviceWarning,
            fluidWarnings: fluidWarnings,
            exteriorStatus: exteriorStatus,
            healthDetails: healthDetails,
            softwareInfo: softwareInfo,
            chargingSchedules: chargingSchedules,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripMeterManualKm: tripMeterManualKm,
            tripMeterAutomaticKm: tripMeterAutomaticKm,
            connectivity: connectivity,
            airQuality: airQuality,
            batteryDiagnostics: batteryDiagnostics,
            weather: weather,
            location: nil,
            unavailableFeatures: [],
            probedCapabilities: probedCapabilities,
            chargingSamples: chargingSamples,
            chargingSessions: chargingSessions,
            powertrain: powertrain,
            fuelLevelPercent: fuelLevelPercent,
            fuelRangeKm: fuelRangeKm,
            reportedBatteryCapacityKwh: reportedBatteryCapacityKwh,
            imageData: nil,
            fetchedAt: fetchedAt,
            vehicleReportedAt: vehicleReportedAt,
            dataWarnings: dataWarnings
        )
        copy.externalColour = externalColour
        copy.gearbox = gearbox
        copy.engineHoursToService = engineHoursToService
        copy.averageSpeedKmH = averageSpeedKmH
        copy.fuelAmountLiters = fuelAmountLiters
        copy.averageFuelConsumptionLPer100Km = averageFuelConsumptionLPer100Km
        copy.isEngineRunning = isEngineRunning
        copy.fuelType = fuelType
        copy.structureWeek = structureWeek
        copy.internalVehicleIdentifier = internalVehicleIdentifier
        copy.pno34 = pno34
        copy.accountMarket = accountMarket
        copy.upholstery = upholstery
        copy.wheels = wheels
        copy.packages = packages
        copy.steeringOrientation = steeringOrientation
        copy.serviceTrigger = serviceTrigger
        copy.tripComputerElectricRangeKm = tripComputerElectricRangeKm
        copy.chargingCurrentLimitAmps = chargingCurrentLimitAmps
        copy.warrantyInfo = warrantyInfo
        copy.retainedDataCategories = retainedDataCategories
        copy.retainedDataAt = retainedDataAt
        return copy
    }

    func mergingLastKnown(from previous: VehicleState?, features: FeatureSelection,
                           imageCache: CarImageCache = CarImageCache()) -> VehicleState {
        guard let previous, previous.vin == vin else { return self }
        let failed = Set(unavailableFeatures)
        func keep(_ feature: AppFeature) -> Bool {
            features.contains(feature) && failed.contains(feature)
        }
        let previousChargingState: ChargingState? = {
            if case .unknown = chargingState { return previous.chargingState }
            return nil
        }()
        let mergedAvailability: VehicleAvailability = {
            guard features.contains(.vehicleAvailability), case .unknown = availability else { return availability }
            return previous.availability
        }()
        let mergedProbes: VehicleProbedCapabilities? = {
            guard let probedCapabilities else { return previous.probedCapabilities }
            return previous.probedCapabilities?.merging(newerProbe: probedCapabilities) ?? probedCapabilities
        }()
        // Polestar reports a single version string whose meaning flips once an update is
        // pending, so the running version drops out of the payload for the whole rollout.
        // Carry the last settled reading forward — otherwise "Installed Version" disappears
        // from the moment an update is offered until it finishes installing.
        let mergedSoftware: VehicleSoftwareInfo? = {
            guard var current = softwareInfo else {
                return keep(.softwareUpdates) ? previous.softwareInfo : nil
            }
            if current.installedVersion == nil {
                current.installedVersion = previous.softwareInfo?.installedVersion
            }
            return current
        }()

        let isCommandLocked = (previous.optimisticCommandLockUntil ?? .distantPast) > Date()
        let mergedClimate: VehicleClimateStatus? = {
            guard let prevClimate = previous.climateStatus else {
                return climateStatus ?? (features.contains(.climateStatus) ? previous.climateStatus : nil)
            }
            if isCommandLocked {
                if prevClimate.activity == .heating || prevClimate.activity == .cooling || prevClimate.activity == .ventilating || prevClimate.activity == .active {
                    if let incoming = climateStatus, incoming.activity == .heating || incoming.activity == .cooling || incoming.activity == .ventilating || incoming.activity == .active {
                        return incoming
                    }
                    return prevClimate
                } else if prevClimate.activity == .idle {
                    if let incoming = climateStatus, incoming.activity == .idle {
                        return incoming
                    }
                    return prevClimate
                }
            }
            return climateStatus ?? (features.contains(.climateStatus) ? previous.climateStatus : nil)
        }()

        let mergedChargeTarget: Int? = {
            if isCommandLocked, let prevTarget = previous.chargeTargetPercentage {
                return prevTarget
            }
            return chargeTargetPercentage ?? previous.chargeTargetPercentage
        }()

        let mergedCurrentAmps: Int? = {
            if isCommandLocked, let prevAmps = previous.chargingCurrentAmps {
                return prevAmps
            }
            return chargingCurrentAmps ?? previous.chargingCurrentAmps
        }()

        var merged = VehicleState(
            batteryPercentage: batteryPercentage ?? previous.batteryPercentage,
            rangeKm: rangeKm ?? previous.rangeKm,
            chargingState: previousChargingState ?? chargingState,
            estimatedChargingTimeToFullMinutes: estimatedChargingTimeToFullMinutes
                ?? previous.estimatedChargingTimeToFullMinutes,
            chargeTargetPercentage: mergedChargeTarget,
            chargingPowerWatts: chargingPowerWatts ?? previous.chargingPowerWatts,
            chargingCurrentAmps: mergedCurrentAmps,
            chargingVoltageVolts: chargingVoltageVolts ?? previous.chargingVoltageVolts,
            chargingType: chargingType == .unknown ? previous.chargingType : chargingType,
            chargerConnection: chargerConnection == .unknown ? previous.chargerConnection : chargerConnection,
            availability: mergedAvailability,
            modelName: modelName ?? (features.contains(.vehicleIdentity) ? previous.modelName : nil),
            modelYear: modelYear ?? (features.contains(.vehicleIdentity) ? previous.modelYear : nil),
            registrationNo: registrationNo ?? (features.contains(.vehicleIdentity) ? previous.registrationNo : nil),
            vin: vin,
            ownerFirstName: ownerFirstName ?? (features.contains(.ownerGreeting) ? previous.ownerFirstName : nil),
            odometerKm: odometerKm ?? (features.contains(.vehicleHealth) ? previous.odometerKm : nil),
            daysToService: daysToService ?? (features.contains(.vehicleHealth) ? previous.daysToService : nil),
            distanceToServiceKm: distanceToServiceKm
                ?? (features.contains(.vehicleHealth) ? previous.distanceToServiceKm : nil),


            serviceWarning: !serviceWarning && keep(.vehicleHealth) ? previous.serviceWarning : serviceWarning,
            fluidWarnings: fluidWarnings.isEmpty && keep(.vehicleHealth) ? previous.fluidWarnings : fluidWarnings,
            exteriorStatus: exteriorStatus ?? (features.contains(.exteriorStatus) ? previous.exteriorStatus : nil),
            healthDetails: healthDetails ?? (features.contains(.tyreAndWarnings) ? previous.healthDetails : nil),
            softwareInfo: mergedSoftware,
            chargingSchedules: !chargingSchedules.isEmpty ? chargingSchedules
                : (features.contains(.chargingSchedule) ? previous.chargingSchedules : []),
            climateStatus: mergedClimate,
            climateTimers: !climateTimers.isEmpty ? climateTimers
                : (features.contains(.climateStatus) ? previous.climateTimers : []),
            tripMeterManualKm: tripMeterManualKm ?? (features.contains(.tripMeters) ? previous.tripMeterManualKm : nil),
            tripMeterAutomaticKm: tripMeterAutomaticKm ?? (features.contains(.tripMeters) ? previous.tripMeterAutomaticKm : nil),
            connectivity: connectivity ?? (features.contains(.connectivityDiagnostics) ? previous.connectivity : nil),
            airQuality: airQuality ?? (features.contains(.airQuality) ? previous.airQuality : nil),
            batteryDiagnostics: batteryDiagnostics
                ?? (features.contains(.batteryDiagnostics) ? previous.batteryDiagnostics : nil),
            weather: weather ?? (features.contains(.vehicleWeather) ? previous.weather : nil),
            location: location ?? (features.contains(.vehicleLocation) ? previous.location : nil),
            unavailableFeatures: unavailableFeatures,
            probedCapabilities: mergedProbes,
            chargingSessions: previous.chargingSessions,
            powertrain: powertrain == .unknown ? previous.powertrain : powertrain,
            fuelLevelPercent: fuelLevelPercent ?? previous.fuelLevelPercent,
            fuelRangeKm: fuelRangeKm ?? previous.fuelRangeKm,
            reportedBatteryCapacityKwh: reportedBatteryCapacityKwh ?? previous.reportedBatteryCapacityKwh,
            imageData: imageData ?? (features.contains(.vehicleImage) ? (previous.imageData ?? imageCache.image(for: vin)) : nil),
            fetchedAt: fetchedAt,
            vehicleReportedAt: vehicleReportedAt ?? previous.vehicleReportedAt,
            dataWarnings: dataWarnings
        )
        merged.externalColour = externalColour ?? previous.externalColour
        merged.gearbox = gearbox ?? previous.gearbox
        merged.engineHoursToService = engineHoursToService ?? previous.engineHoursToService
        merged.averageSpeedKmH = averageSpeedKmH ?? previous.averageSpeedKmH
        merged.fuelAmountLiters = fuelAmountLiters ?? previous.fuelAmountLiters
        merged.averageFuelConsumptionLPer100Km = averageFuelConsumptionLPer100Km ?? previous.averageFuelConsumptionLPer100Km
        merged.isEngineRunning = isEngineRunning ?? previous.isEngineRunning
        merged.fuelType = fuelType ?? previous.fuelType
        merged.structureWeek = structureWeek ?? previous.structureWeek
        merged.internalVehicleIdentifier = internalVehicleIdentifier ?? previous.internalVehicleIdentifier
        merged.pno34 = pno34 ?? previous.pno34
        merged.accountMarket = accountMarket ?? previous.accountMarket
        merged.upholstery = upholstery ?? previous.upholstery
        merged.wheels = wheels ?? previous.wheels
        merged.packages = !packages.isEmpty ? packages : previous.packages
        merged.steeringOrientation = steeringOrientation ?? previous.steeringOrientation
        merged.serviceTrigger = serviceTrigger ?? previous.serviceTrigger
        merged.tripComputerElectricRangeKm = tripComputerElectricRangeKm ?? previous.tripComputerElectricRangeKm
        merged.chargingCurrentLimitAmps = chargingCurrentLimitAmps ?? previous.chargingCurrentLimitAmps
        // Locations are only re-shown when this fetch actually returned them; an empty result
        // after a backend hiccup should not wipe the list the controls tab is rendering.
        merged.chargeLocations = chargeLocations.isEmpty ? previous.chargeLocations : chargeLocations
        merged.warrantyInfo = warrantyInfo ?? previous.warrantyInfo
        merged.interiorImageData = interiorImageData
            ?? (features.contains(.vehicleImage) ? (previous.interiorImageData ?? imageCache.interiorImage(for: vin)) : nil)
        merged.optimisticCommandLockUntil = isCommandLocked ? previous.optimisticCommandLockUntil : nil
        merged.electricDistanceKm = electricDistanceKm ?? previous.electricDistanceKm
        merged.fuelDistanceKm = fuelDistanceKm ?? previous.fuelDistanceKm
        merged.regeneratedEnergyKwh = regeneratedEnergyKwh ?? previous.regeneratedEnergyKwh
        merged.frontBrakePadStatus = frontBrakePadStatus ?? previous.frontBrakePadStatus
        merged.rearBrakePadStatus = rearBrakePadStatus ?? previous.rearBrakePadStatus
        merged.preferredWorkshopId = preferredWorkshopId ?? previous.preferredWorkshopId
        merged.preferredWorkshopName = preferredWorkshopName ?? previous.preferredWorkshopName

        var retained = Set<AppFeature>()
        func markRetained(_ feature: AppFeature, currentIsMissing: Bool, previousWasPresent: Bool) {
            if features.contains(feature), currentIsMissing, previousWasPresent {
                retained.insert(feature)
            }
        }
        markRetained(.exteriorStatus, currentIsMissing: exteriorStatus == nil, previousWasPresent: previous.exteriorStatus != nil)
        markRetained(.tyreAndWarnings, currentIsMissing: healthDetails == nil, previousWasPresent: previous.healthDetails != nil)
        markRetained(.softwareUpdates, currentIsMissing: softwareInfo == nil, previousWasPresent: previous.softwareInfo != nil)
        markRetained(.climateStatus, currentIsMissing: climateStatus == nil, previousWasPresent: previous.climateStatus != nil)
        markRetained(.tripMeters, currentIsMissing: tripMeterManualKm == nil && tripMeterAutomaticKm == nil,
                     previousWasPresent: previous.tripMeterManualKm != nil || previous.tripMeterAutomaticKm != nil)
        markRetained(.connectivityDiagnostics, currentIsMissing: connectivity == nil, previousWasPresent: previous.connectivity != nil)
        markRetained(.airQuality, currentIsMissing: airQuality == nil, previousWasPresent: previous.airQuality != nil)
        markRetained(.batteryDiagnostics, currentIsMissing: batteryDiagnostics == nil, previousWasPresent: previous.batteryDiagnostics != nil)
        markRetained(.vehicleWeather, currentIsMissing: weather == nil, previousWasPresent: previous.weather != nil)
        markRetained(.vehicleLocation, currentIsMissing: location == nil, previousWasPresent: previous.location != nil)
        retained.formUnion(failed.filter { features.contains($0) })
        merged.retainedDataCategories = retained.sorted { $0.title < $1.title }
        merged.retainedDataAt = retained.isEmpty ? nil : (previous.retainedDataAt ?? previous.vehicleReportedAt ?? previous.fetchedAt)

        var samples = previous.chargingSamples
        if merged.isCharging, let pct = merged.batteryPercentage {
            let sample = ChargingSample(
                timestamp: fetchedAt, batteryPercentage: pct, powerWatts: merged.chargingPowerWatts,
                chargingType: merged.chargingType
            )
            if let last = samples.last {
                if sample.timestamp.timeIntervalSince(last.timestamp) >= 20 || abs(sample.batteryPercentage - last.batteryPercentage) >= 0.2 {
                    samples.append(sample)
                }
            } else {
                samples.append(sample)
            }
            if samples.count > 50 {
                samples.removeFirst(samples.count - 50)
            }
        } else if !merged.isCharging {
            samples.removeAll()
        }
        merged.chargingSamples = samples
        return merged
    }
}
