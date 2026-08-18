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
    case good
    case warning
    case critical
}

struct VehicleStateSummary: Equatable, Sendable {
    let message: String
    let severity: VehicleStateSeverity
}

struct VehicleState: Codable, Equatable, Sendable {
    let batteryPercentage: Double?
    let rangeKm: Int?
    let chargingState: ChargingState
    let estimatedChargingTimeToFullMinutes: Int?
    var chargeTargetPercentage: Int?
    let chargingPowerWatts: Int?
    var chargingCurrentAmps: Int?
    let chargingVoltageVolts: Int?
    let chargingType: ChargingType
    let chargerConnection: ChargerConnection
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


    var powertrain: PowertrainType = .bev
    var fuelLevelPercent: Double? = nil
    var fuelRangeKm: Int? = nil
    var fuelAmountLiters: Double? = nil
    var averageFuelConsumptionLPer100Km: Double? = nil
    var isEngineRunning: Bool? = nil
    var fuelType: String? = nil

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

    /// True when this state came from the on-disk snapshot rather than a live fetch.
    ///
    /// `cacheableCopy` drops most telemetry, so a cached state is not "the vehicle has no
    /// tyres data" — it is "we could not ask". Cards use this to show an unavailable badge
    /// instead of silently disappearing.
    var isCachedSnapshot: Bool = false
    let imageData: Data?
    var fetchedAt: Date
    let vehicleReportedAt: Date?
    let dataWarnings: [String]

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
        self.fuelLevelPercent = fuelLevelPercent
        self.fuelRangeKm = fuelRangeKm
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
        case powertrain, fuelLevelPercent, fuelRangeKm, reportedBatteryCapacityKwh
        case externalColour, gearbox, engineHoursToService, averageSpeedKmH
        case fuelAmountLiters, averageFuelConsumptionLPer100Km, isEngineRunning, fuelType
        case structureWeek, internalVehicleIdentifier, pno34, accountMarket
        case upholstery, wheels, packages, steeringOrientation, serviceTrigger, tripComputerElectricRangeKm, chargingCurrentLimitAmps
        case interiorImageData, warrantyInfo
        case electricDistanceKm, fuelDistanceKm, regeneratedEnergyKwh, frontBrakePadStatus, rearBrakePadStatus
        case preferredWorkshopId, preferredWorkshopName
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
            fuelLevelPercent: try values.decodeIfPresent(Double.self, forKey: .fuelLevelPercent),
            fuelRangeKm: try values.decodeIfPresent(Int.self, forKey: .fuelRangeKm),
            reportedBatteryCapacityKwh: try values.decodeIfPresent(Double.self, forKey: .reportedBatteryCapacityKwh),
            imageData: try values.decodeIfPresent(Data.self, forKey: .imageData),
            fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
            vehicleReportedAt: try values.decodeIfPresent(Date.self, forKey: .vehicleReportedAt),
            dataWarnings: try values.decode([String].self, forKey: .dataWarnings)
        )
        self.externalColour = try values.decodeIfPresent(String.self, forKey: .externalColour)
        self.gearbox = try values.decodeIfPresent(String.self, forKey: .gearbox)
        self.engineHoursToService = try values.decodeIfPresent(Int.self, forKey: .engineHoursToService)
        self.averageSpeedKmH = try values.decodeIfPresent(Double.self, forKey: .averageSpeedKmH)
        self.fuelAmountLiters = try values.decodeIfPresent(Double.self, forKey: .fuelAmountLiters)
        self.averageFuelConsumptionLPer100Km = try values.decodeIfPresent(Double.self, forKey: .averageFuelConsumptionLPer100Km)
        self.isEngineRunning = try values.decodeIfPresent(Bool.self, forKey: .isEngineRunning)
        self.fuelType = try values.decodeIfPresent(String.self, forKey: .fuelType)
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

    var effectiveWarrantyInfo: VehicleWarrantyInfo {
        if let explicit = warrantyInfo {
            return explicit
        }
        let calendar = Calendar.current
        let isVolvo = (modelName?.lowercased().contains("volvo") == true) || (vin.uppercased().hasPrefix("YV"))

        let baselineDeliveryDate: Date = {
            if let rawWeek = structureWeek?.trimmingCharacters(in: .whitespacesAndNewlines),
               rawWeek.count >= 6,
               let year = Int(rawWeek.prefix(4)),
               let week = Int(rawWeek.suffix(2)) {
                var components = DateComponents()
                components.yearForWeekOfYear = year
                components.weekOfYear = week
                components.weekday = 2
                if let buildDate = calendar.date(from: components) {
                    return calendar.date(byAdding: .weekOfYear, value: 4, to: buildDate) ?? buildDate
                }
            }

            let yearInt = modelYear.flatMap { Int($0.filter(\.isNumber)) } ?? 2023
            var components = DateComponents()
            components.year = yearInt
            components.month = 6
            components.day = 1
            return calendar.date(from: components) ?? Date()
        }()

        let factoryEnd = calendar.date(byAdding: .year, value: 3, to: baselineDeliveryDate)
        let batteryEnd = calendar.date(byAdding: .year, value: 8, to: baselineDeliveryDate)
        let roadsideEnd = calendar.date(byAdding: .year, value: 3, to: baselineDeliveryDate)
        let digitalServicesEnd = calendar.date(byAdding: .year, value: 3, to: baselineDeliveryDate)
        let corrosionEnd = calendar.date(byAdding: .year, value: 12, to: baselineDeliveryDate)

        let plan = isVolvo ? "Care by Volvo" : "Polestar Care"
        let assistanceName = isVolvo ? "Volvo Assistance" : "Polestar Assistance"

        return VehicleWarrantyInfo(
            planName: plan,
            status: L10n.text("Active"),
            factoryWarrantyValidUntil: factoryEnd,
            batteryWarrantyValidUntil: powertrain.hasElectricRange ? batteryEnd : nil,
            batteryWarrantyKm: powertrain.hasElectricRange ? 160_000 : nil,
            roadsideAssistanceValidUntil: roadsideEnd,
            includedMaintenance: true,
            corrosionWarrantyValidUntil: corrosionEnd,
            digitalServicesValidUntil: digitalServicesEnd,
            assistanceContact: assistanceName
        )
    }

    var factoryNominalBatteryCapacityKwh: Double {
        if let explicit = reportedBatteryCapacityKwh, explicit > 0 {
            if explicit >= 77.0 { return 82.0 }
            if explicit >= 72.0 { return 78.0 }
            if explicit >= 60.0 { return 69.0 }
            if explicit >= 14.0 { return 18.8 }
            if explicit >= 8.0 { return 11.6 }
            return explicit
        }
        let yearInt = Int(modelYear ?? "") ?? 2023
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40) && yearInt >= 2024 {
            return 82.0
        }
        if powertrain == .phev {
            return yearInt >= 2022 ? 18.8 : 11.6
        }
        return model.nominalBatteryCapacityKwh > 0 ? model.nominalBatteryCapacityKwh : 78.0
    }

    var factoryUsableBatteryCapacityKwh: Double {
        if let explicit = reportedBatteryCapacityKwh, explicit > 0 {
            if explicit >= 77.0 { return 79.0 }
            if explicit >= 72.0 { return 75.0 }
            if explicit >= 60.0 { return 64.0 }
            if explicit >= 14.0 { return 14.9 }
            if explicit >= 8.0 { return 9.1 }
        }
        let yearInt = Int(modelYear ?? "") ?? 2023
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40) && yearInt >= 2024 {
            return 79.0
        }
        if powertrain == .phev {
            return yearInt >= 2022 ? 14.9 : 9.1
        }
        return model.nominalUsableCapacityKwh > 0 ? model.nominalUsableCapacityKwh : 75.0
    }

    var effectiveNominalBatteryCapacityKwh: Double {
        factoryNominalBatteryCapacityKwh
    }

    var batteryDegradationPercent: Double? {
        guard powertrain.hasElectricRange else { return nil }
        if let explicit = reportedBatteryCapacityKwh, explicit > 0 {
            let factoryUsable = factoryUsableBatteryCapacityKwh
            let measuredDeg = max(0.0, ((factoryUsable - explicit) / factoryUsable) * 100.0)
            return ((measuredDeg * 10).rounded()) / 10.0
        }

        // Empirical degradation calculation based on vehicle calendar age and odometer cycle throughput
        var calendarDegradation = 0.0
        let yearInt = Int(modelYear ?? "") ?? 2023
        var vehicleAgeYears = max(0.5, Double(Calendar.current.component(.year, from: Date()) - yearInt))
        if let sw = structureWeek, sw.count >= 6, let swYear = Double(sw.prefix(4)), let swWeek = Double(sw.suffix(2)) {
            let approximateBuildDate = swYear + (swWeek / 52.0)
            let currentYearFraction = Double(Calendar.current.component(.year, from: Date())) + (Double(Calendar.current.component(.month, from: Date())) / 12.0)
            vehicleAgeYears = max(0.2, currentYearFraction - approximateBuildDate)
        }
        // Lithium-ion NMC calendar aging curve (~1.35% * sqrt(years))
        calendarDegradation = min(8.0, 1.35 * sqrt(vehicleAgeYears))

        var cycleDegradation = 0.0
        if let odo = odometerKm, odo > 0 {
            // High-voltage pack cycle aging (~4.2% per 100,000 km for Polestar 2 / Volvo CMA & SPA platform)
            cycleDegradation = min(12.0, (Double(odo) / 100_000.0) * 4.2)
        }

        let totalDeg = calendarDegradation + cycleDegradation
        return max(0.2, ((totalDeg * 10).rounded()) / 10.0)
    }

    var batteryStateOfHealthPercent: Double? {
        guard powertrain.hasElectricRange, let deg = batteryDegradationPercent else { return nil }
        let soh = max(50.0, min(100.0, 100.0 - deg))
        return ((soh * 10).rounded()) / 10.0
    }

    var effectiveUsableBatteryCapacityKwh: Double {
        if let reported = reportedBatteryCapacityKwh, reported > 0 {
            return reported
        }
        let factoryUsable = factoryUsableBatteryCapacityKwh
        guard let soh = batteryStateOfHealthPercent else { return factoryUsable }
        let currentUsable = factoryUsable * (soh / 100.0)
        return ((currentUsable * 10).rounded()) / 10.0
    }

    var batteryPackDescription: String {
        let nominal = factoryNominalBatteryCapacityKwh
        switch model {
        case .polestar2:
            if nominal >= 80.0 {
                return L10n.text("82.0 kWh Long Range (CATL · 27 Modules / 324 Cells · 400V)")
            } else if nominal >= 75.0 {
                return L10n.text("78.0 kWh Long Range (LG Energy / CATL · 27 Modules / 324 Cells · 400V)")
            } else {
                return L10n.text("69.0 kWh Standard Range (CATL · 24 Modules / 288 Cells · 400V)")
            }
        case .polestar3:
            return L10n.text("111.0 kWh Extended Range (CATL · 17 Modules / 204 Cells · 400V)")
        case .polestar4:
            return L10n.text("100.0 kWh Long Range (CATL / VREMT · 102 kWh Nominal · 400V)")
        case .polestar1:
            return L10n.text("34.0 kWh High-Output Hybrid (30.0 kWh Usable · Triple Pack)")
        case .volvoEX30:
            if nominal >= 65.0 {
                return L10n.text("69.0 kWh Extended Range (NMC · 64.0 kWh Usable · 400V)")
            } else {
                return L10n.text("51.0 kWh Standard Range (LFP · 49.0 kWh Usable · 400V)")
            }
        case .volvoEX90, .volvoES90:
            return L10n.text("111.0 kWh Extended Range (CATL · 107.0 kWh Usable · 400V)")
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40:
            if nominal >= 80.0 {
                return L10n.text("82.0 kWh Long Range (CATL · 79.0 kWh Usable · 400V)")
            } else if nominal >= 75.0 {
                return L10n.text("78.0 kWh Long Range (LG Energy / CATL · 75.0 kWh Usable · 400V)")
            } else {
                return L10n.text("69.0 kWh Standard Range (CATL · 64.0 kWh Usable · 400V)")
            }
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90:
            if powertrain == .phev {
                if nominal >= 16.0 {
                    return L10n.text("18.8 kWh T8 Recharge PHEV (96 Cells · 14.9 kWh Usable)")
                } else {
                    return L10n.text("11.6 kWh T8 Twin Engine PHEV (9.1 kWh Usable)")
                }
            }
            return L10n.format("%.1f kWh High-Voltage Pack", nominal)
        default:
            if nominal > 0 {
                return L10n.format("%.1f kWh Lithium-ion Pack", nominal)
            }
            return L10n.text("High-Voltage Traction Battery")
        }
    }

    var batteryHealthStatus: String {
        guard let soh = batteryStateOfHealthPercent else { return L10n.text("Normal") }
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
        if softwareInfo?.state == .failed {
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
        return VehicleStateSummary(message: L10n.text("No issues detected"), severity: .good)
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

    var estimatedRangeHealth: (percentage: Double, rating: String)? {
        guard model.hasVerifiedNominalSpecs,
              let battery = batteryPercentage, battery > 10,
              let range = rangeKm, range > 0 else { return nil }
        let nominalRange = model.nominalWltpRangeKm
        let expectedRangeAtCurrentSoC = nominalRange * (battery / 100.0)
        let ratio = Double(range) / expectedRangeAtCurrentSoC
        let clampedRatio = min(max(ratio, 0.70), 1.05)
        let soh = min(100.0, max(80.0, (clampedRatio >= 1.0 ? 99.5 : (85.0 + (clampedRatio - 0.70) / 0.30 * 14.5))))
        let rating: String
        if soh >= 95.0 { rating = L10n.text("Excellent") }
        else if soh >= 90.0 { rating = L10n.text("Good") }
        else if soh >= 80.0 { rating = L10n.text("Normal") }
        else { rating = L10n.text("Degraded") }
        return (percentage: (soh * 10).rounded() / 10, rating: rating)
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

        var samples = previous.chargingSamples
        if merged.isCharging, let pct = merged.batteryPercentage {
            let sample = ChargingSample(timestamp: fetchedAt, batteryPercentage: pct, powerWatts: merged.chargingPowerWatts)
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
