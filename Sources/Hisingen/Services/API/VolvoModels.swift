import Foundation


struct VolvoField<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    let updatedAt: Date?
    /// Decoded but not currently used anywhere. Investigated 2026-08: every field in every real
    /// captured response this project has (all `Tests/HisingenTests/Fixtures/volvo-*.json`
    /// fixtures, sanitized from live captures) reports `"OK"`, and no Volvo documentation
    /// referenced elsewhere in this repo enumerates other values. `unavailableReason` (below) is
    /// the field this codebase already reads for "why is this unavailable" — that's likely where
    /// any real signal lives. Wiring `status` into anything beyond this would mean inventing
    /// semantics for values that have never actually been observed; needs a live capture of a
    /// genuinely degraded/erroring field (a car with a real reported fault, or a field the active
    /// API product doesn't cover) before it's safe to act on. See
    /// `docs/research/api-investigation-backlog.md` #2.
    let status: String?
    let unit: String?
    let unavailableReason: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case updatedAt
        case timestamp
        case status
        case unit
        case unavailableReason
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.value) {
            value = try? container.decodeIfPresent(Value.self, forKey: .value)
            updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt))
                ?? (try? container.decodeIfPresent(Date.self, forKey: .timestamp))
                ?? nil
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            unit = try? container.decodeIfPresent(String.self, forKey: .unit)
            unavailableReason = try? container.decodeIfPresent(String.self, forKey: .unavailableReason)
            return
        }
        let single = try decoder.singleValueContainer()
        value = try? single.decode(Value.self)
        updatedAt = nil
        status = nil
        unit = nil
        unavailableReason = nil
    }
}

private enum VolvoUnits {
    static func kilometers(_ value: Double?, unit: String?) -> Double? {
        guard let value else { return nil }
        switch unit?.lowercased() {
        case "mi", "mile", "miles": return value / 0.621371
        case "m", "meter", "meters", "metre", "metres": return value / 1_000
        default: return value
        }
    }

    static func kilometers(_ value: Int?, unit: String?) -> Int? {
        kilometers(value.map(Double.init), unit: unit).map { Int($0.rounded()) }
    }
}

private struct VolvoEnvelopeWrapper<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload
}


struct VolvoEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?

    init(from decoder: Decoder) throws {
        if let wrapped = try? VolvoEnvelopeWrapper<Payload>(from: decoder) {
            data = wrapped.data
            return
        }
        data = try? Payload(from: decoder)
    }
}


struct VolvoVehicleSummaryDTO: Decodable, Sendable {
    let vin: String
}

struct VolvoVehicleDetailsDTO: Decodable, Sendable {
    let vin: String?
    let modelYear: Int?
    let descriptions: Descriptions?
    let fuelType: String?
    let externalColour: String?
    let gearbox: String?
    let batteryCapacityKWH: Double?
    let images: Images?

    struct Descriptions: Decodable, Sendable {
        let model: String?
        let upholstery: String?
        let steering: String?
    }

    struct Images: Decodable, Sendable {
        let exteriorImageUrl: String?
        let interiorImageUrl: String?

        // Volvo's own docs disagree with themselves on this key: the Connected Vehicle API v2
        // OpenAPI schema names it "internalImageUrl", but the endpoint reference page's example
        // response uses "interiorImageUrl" with a real (non-placeholder) CDN URL. Decode either.
        private enum CodingKeys: String, CodingKey {
            case exteriorImageUrl
            case interiorImageUrl
            case internalImageUrl
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exteriorImageUrl = try container.decodeIfPresent(String.self, forKey: .exteriorImageUrl)
            interiorImageUrl = try container.decodeIfPresent(String.self, forKey: .interiorImageUrl)
                ?? (try container.decodeIfPresent(String.self, forKey: .internalImageUrl))
        }
    }
}

extension VolvoVehicleDetailsDTO {
    // Custom decoding lives in an extension so the memberwise initializer is still synthesized
    // for the placeholder built in `fetchVehicleStateImplementation`.
    private enum CodingKeys: String, CodingKey {
        case vin, modelYear, descriptions, fuelType, gearbox, batteryCapacityKWH, images
        case externalColour, externalColours
    }

    private struct ColourEntry: Decodable {
        let value: String?
        let name: String?
        let description: String?
        var label: String? { value ?? name ?? description }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vin = try c.decodeIfPresent(String.self, forKey: .vin)
        modelYear = try c.decodeIfPresent(Int.self, forKey: .modelYear)
        descriptions = try c.decodeIfPresent(Descriptions.self, forKey: .descriptions)
        fuelType = try c.decodeIfPresent(String.self, forKey: .fuelType)
        gearbox = try c.decodeIfPresent(String.self, forKey: .gearbox)
        batteryCapacityKWH = try c.decodeIfPresent(Double.self, forKey: .batteryCapacityKWH)
        images = try c.decodeIfPresent(Images.self, forKey: .images)
        // The Connected Vehicle API v2 vehicle-details payload has been seen both as a flat
        // `externalColour` string and as an `externalColours` array (of `{value}`/`{name}`
        // objects, or bare strings). Collapse either to the single display string the app uses.
        if let flat = try? c.decodeIfPresent(String.self, forKey: .externalColour), !flat.isEmpty {
            externalColour = flat
        } else if let entries = try? c.decodeIfPresent([ColourEntry].self, forKey: .externalColours) {
            externalColour = entries.compactMap(\.label).first
        } else if let strings = try? c.decodeIfPresent([String].self, forKey: .externalColours) {
            externalColour = strings.first(where: { !$0.isEmpty })
        } else {
            externalColour = nil
        }
    }
}


enum VolvoPowertrain {
    static func classify(fuelType: String?) -> PowertrainType {
        guard let raw = fuelType?.uppercased() else { return .unknown }
        let hasElectric = raw.contains("ELECTRIC") || raw.contains("BEV") || raw.contains("EV")
        let hasFuel = raw.contains("PETROL") || raw.contains("DIESEL") || raw.contains("GASOLINE") || raw.contains("BENZIN")
        let isPlugIn = raw.contains("PLUG") || raw.contains("PHEV") || (raw.contains("RECHARGE") && hasFuel)
        let isMildHybrid = raw.contains("MHEV") || raw.contains("MILD") || (raw.contains("HYBRID") && !isPlugIn)
        if raw == "NONE" && hasElectric { return .bev }
        if hasElectric && hasFuel { return isMildHybrid ? .mildHybrid : .phev }
        if isPlugIn { return .phev }
        if isMildHybrid { return .mildHybrid }
        if hasElectric { return .bev }
        if hasFuel { return .ice }
        return .unknown
    }
}


struct VolvoEnergyStateDTO: Decodable, Sendable {
    let batteryChargeLevel: VolvoField<Double>?
    let electricRange: VolvoField<Double>?
    let chargingStatus: VolvoField<String>?
    let chargingSystemStatus: VolvoField<String>?
    let chargerConnectionStatus: VolvoField<String>?
    let chargingType: VolvoField<String>?
    let chargerPowerStatus: VolvoField<String>?
    let chargingPower: VolvoField<Double>?
    let chargingCurrent: VolvoField<Double>?
    let chargingVoltage: VolvoField<Double>?
    let chargingCurrentLimit: VolvoField<Double>?
    let estimatedChargingTimeToFull: VolvoField<Double>?
    let estimatedChargingTimeToTargetBatteryChargeLevel: VolvoField<Double>?
    let targetBatteryLevel: VolvoField<Double>?
    let targetBatteryChargeLevel: VolvoField<Double>?

    var rangeKm: Int? {
        guard let value = electricRange?.value else { return nil }
        switch electricRange?.unit?.lowercased() {
        case "mi", "mile", "miles": return Int((value / 0.621371).rounded())
        default: return Int(value.rounded())
        }
    }

    var targetPercent: Int? {
        (targetBatteryChargeLevel?.value ?? targetBatteryLevel?.value).map { Int($0.rounded()) }
    }

    var estTimeToTargetMinutes: Int? {
        (estimatedChargingTimeToTargetBatteryChargeLevel?.value ?? estimatedChargingTimeToFull?.value).map { Int($0.rounded()) }
    }

    var chargingStateValue: String? {
        chargingSystemStatus?.value ?? chargingStatus?.value
    }

    var chargingPowerWatts: Int? {
        guard let value = chargingPower?.value else { return nil }
        switch chargingPower?.unit?.lowercased() {
        case "kw", "kilowatt", "kilowatts": return Int((value * 1_000).rounded())
        default: return Int(value.rounded())
        }
    }
}

struct VolvoEnergyCapabilitiesDTO: Decodable, Sendable {
    let batteryChargeLevel: VolvoCapabilityFlag?
    let electricRange: VolvoCapabilityFlag?
    let chargerConnectionStatus: VolvoCapabilityFlag?
    let chargingSystemStatus: VolvoCapabilityFlag?
    let chargingType: VolvoCapabilityFlag?
    let chargerPowerStatus: VolvoCapabilityFlag?
    let estimatedChargingTimeToTargetBatteryChargeLevel: VolvoCapabilityFlag?
    let chargingPower: VolvoCapabilityFlag?
    let chargingCurrentLimit: VolvoCapabilityFlag?
    let targetBatteryChargeLevel: VolvoCapabilityFlag?

    var targetBatteryLevel: VolvoCapabilityFlag? { targetBatteryChargeLevel }

    private struct EnergyStateCapabilities: Decodable {
        let batteryChargeLevel: VolvoCapabilityFlag?
        let electricRange: VolvoCapabilityFlag?
        let chargerConnectionStatus: VolvoCapabilityFlag?
        let chargingSystemStatus: VolvoCapabilityFlag?
        let chargingStatus: VolvoCapabilityFlag?
        let chargingType: VolvoCapabilityFlag?
        let chargerPowerStatus: VolvoCapabilityFlag?
        let estimatedChargingTimeToTargetBatteryChargeLevel: VolvoCapabilityFlag?
        let chargingPower: VolvoCapabilityFlag?
        let chargingCurrentLimit: VolvoCapabilityFlag?
        let targetBatteryChargeLevel: VolvoCapabilityFlag?
        let targetBatteryLevel: VolvoCapabilityFlag?
    }

    private enum CodingKeys: String, CodingKey {
        case getEnergyState
        case batteryChargeLevel, electricRange, chargerConnectionStatus
        case chargingSystemStatus, chargingStatus, chargingType, chargerPowerStatus
        case estimatedChargingTimeToTargetBatteryChargeLevel, chargingPower, chargingCurrentLimit
        case targetBatteryChargeLevel, targetBatteryLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.decodeIfPresent(EnergyStateCapabilities.self, forKey: .getEnergyState)
        let flatBattery = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .batteryChargeLevel)
        let flatRange = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .electricRange)
        let flatConnection = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargerConnectionStatus)
        let flatSystemStatus = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargingSystemStatus)
        let flatStatus = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargingStatus)
        let flatType = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargingType)
        let flatPowerStatus = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargerPowerStatus)
        let flatEstimatedTime = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .estimatedChargingTimeToTargetBatteryChargeLevel)
        let flatPower = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargingPower)
        let flatCurrentLimit = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .chargingCurrentLimit)
        let flatTarget = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .targetBatteryChargeLevel)
        let legacyFlatTarget = try container.decodeIfPresent(VolvoCapabilityFlag.self, forKey: .targetBatteryLevel)

        batteryChargeLevel = nested?.batteryChargeLevel ?? flatBattery
        electricRange = nested?.electricRange ?? flatRange
        chargerConnectionStatus = nested?.chargerConnectionStatus ?? flatConnection
        chargingSystemStatus = nested?.chargingSystemStatus ?? nested?.chargingStatus ?? flatSystemStatus ?? flatStatus
        chargingType = nested?.chargingType ?? flatType
        chargerPowerStatus = nested?.chargerPowerStatus ?? flatPowerStatus
        estimatedChargingTimeToTargetBatteryChargeLevel = nested?.estimatedChargingTimeToTargetBatteryChargeLevel ?? flatEstimatedTime
        chargingPower = nested?.chargingPower ?? flatPower
        chargingCurrentLimit = nested?.chargingCurrentLimit ?? flatCurrentLimit
        targetBatteryChargeLevel = nested?.targetBatteryChargeLevel ?? nested?.targetBatteryLevel ?? flatTarget ?? legacyFlatTarget
    }
}

struct VolvoCapabilityFlag: Decodable, Sendable {
    let isSupported: Bool?
}

extension ChargingState {


    init(volvoChargingStatus raw: String?) {
        guard let raw else { self = .unknown("UNSPECIFIED"); return }
        switch raw.uppercased() {
        case "CHARGING": self = .charging
        case "SMART_CHARGING": self = .smartCharging
        case "CHARGING_PAUSED", "PAUSED": self = .paused
        case "SCHEDULED": self = .scheduled
        case "IDLE", "NOT_CHARGING": self = .idle
        case "DONE", "CHARGING_COMPLETE", "FULLY_CHARGED": self = .complete
        case "DISCHARGING": self = .discharging
        case "FAULT", "ERROR", "CHARGING_ERROR": self = .fault
        default: self = .unknown(raw.uppercased())
        }
    }
}

extension ChargerConnection {
    init(volvoConnectionStatus raw: String?) {
        guard let raw else { self = .unknown; return }
        switch raw.uppercased() {
        case "CONNECTED", "PLUGGED_IN": self = .connected
        case "DISCONNECTED", "NOT_CONNECTED", "UNPLUGGED": self = .disconnected
        case "FAULT", "CONNECTION_ERROR": self = .fault
        default: self = .unknown
        }
    }
}

extension ChargingType {
    init(volvoChargingType raw: String?) {
        switch raw?.uppercased() {
        case "AC": self = .ac
        case "DC": self = .dc
        case "NONE": self = .none
        case "WIRELESS": self = .wireless
        default: self = .unknown
        }
    }
}

extension ChargerPowerState {
    init(volvoPowerStatus raw: String?) {
        switch raw?.uppercased() {
        // `NO_POWER_AVAILABLE` is what `/energy/v2/state` actually returns for an unplugged
        // car (verified live); the shorter spellings are kept for older/other shapes.
        case "NO_POWER", "NO_POWER_AVAILABLE", "UNAVAILABLE": self = .noPower
        case "INITIALIZING", "PREPARING": self = .initializing
        case "AVAILABLE", "READY": self = .available
        case "PROVIDING_POWER", "POWER_AVAILABLE", "CHARGING": self = .providingPower
        case "FAULT", "ERROR": self = .fault
        default: self = .unknown
        }
    }
}


struct VolvoDoorsDTO: Decodable, Sendable {
    let centralLock: VolvoField<String>?
    let frontLeftDoor: VolvoField<String>?
    let frontRightDoor: VolvoField<String>?
    let rearLeftDoor: VolvoField<String>?
    let rearRightDoor: VolvoField<String>?
    let hood: VolvoField<String>?
    let tailgate: VolvoField<String>?


    let tankLid: VolvoField<String>?

    var isLocked: Bool? {
        guard let raw = centralLock?.value?.uppercased() else { return nil }
        if raw.contains("LOCKED") && !raw.contains("UNLOCKED") { return true }
        if raw.contains("UNLOCKED") { return false }
        return nil
    }
}

struct VolvoWindowsDTO: Decodable, Sendable {
    let frontLeftWindow: VolvoField<String>?
    let frontRightWindow: VolvoField<String>?
    let rearLeftWindow: VolvoField<String>?
    let rearRightWindow: VolvoField<String>?
    let sunroof: VolvoField<String>?
}


extension OpeningState {
    init?(volvoStatus raw: String?) {
        guard let raw = raw?.uppercased() else { return nil }
        if raw.contains("AJAR") { self = .ajar; return }
        if raw.contains("CLOSED") { self = .closed; return }
        if raw.contains("OPEN") { self = .open; return }
        return nil
    }
}


struct VolvoTyresDTO: Decodable, Sendable {
    let frontLeft: VolvoField<String>?
    let frontRight: VolvoField<String>?
    let rearLeft: VolvoField<String>?
    let rearRight: VolvoField<String>?


    var readings: [TyrePressure] {
        [(TyrePosition.frontLeft, frontLeft), (.frontRight, frontRight),
         (.rearLeft, rearLeft), (.rearRight, rearRight)]
            .map { position, field in
                TyrePressure(position: position, kilopascals: nil, warning: Self.warning(from: field?.value))
            }
    }

    private static func warning(from raw: String?) -> TyrePressureWarning {
        guard let raw = raw?.uppercased() else { return .unknown }
        if raw.contains("NO_WARNING") { return .none }
        // TPMS hardware problems are not pressure readings — surface them as a distinct state
        // rather than a false "low pressure" alarm or an indistinguishable "unknown".
        if raw.contains("NO_SENSOR") || raw.contains("NOSENSOR")
            || raw.contains("SYSTEM_FAULT") || raw.contains("SYSTEMFAULT")
            || raw.contains("SENSOR_FAULT") { return .sensorFault }
        if raw.contains("VERY_LOW") { return .veryLow }
        if raw.contains("LOW") { return .low }
        if raw.contains("HIGH") { return .high }
        return .unknown
    }
}


struct VolvoDiagnosticsDTO: Decodable, Sendable {
    let serviceWarning: VolvoField<String>?
    let serviceTrigger: VolvoField<String>?
    let timeToService: VolvoField<Int>?
    let distanceToService: VolvoField<Int>?
    let engineHoursToService: VolvoField<Int>?
    let brakeFluidLevelWarning: VolvoField<String>?
    let engineCoolantLevelWarning: VolvoField<String>?
    let oilLevelWarning: VolvoField<String>?
    let washerFluidLevelWarning: VolvoField<String>?
    let batteryChargeLevelWarning: VolvoField<String>?
    let workshopId: VolvoField<String>?
    let workshopName: VolvoField<String>?

    private enum CodingKeys: String, CodingKey {
        case serviceWarning, serviceTrigger, timeToService, distanceToService, distanceToServiceKm
        case engineHoursToService, brakeFluidLevelWarning, engineCoolantLevelWarning
        case oilLevelWarning, washerFluidLevelWarning, batteryChargeLevelWarning
        case workshopId, workshopName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .serviceWarning)
        serviceTrigger = try container.decodeIfPresent(VolvoField<String>.self, forKey: .serviceTrigger)
        timeToService = try container.decodeIfPresent(VolvoField<Int>.self, forKey: .timeToService)
        distanceToService = try container.decodeIfPresent(VolvoField<Int>.self, forKey: .distanceToServiceKm)
            ?? container.decodeIfPresent(VolvoField<Int>.self, forKey: .distanceToService)
        engineHoursToService = try container.decodeIfPresent(VolvoField<Int>.self, forKey: .engineHoursToService)
        brakeFluidLevelWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .brakeFluidLevelWarning)
        engineCoolantLevelWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .engineCoolantLevelWarning)
        oilLevelWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .oilLevelWarning)
        washerFluidLevelWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .washerFluidLevelWarning)
        batteryChargeLevelWarning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .batteryChargeLevelWarning)
        workshopId = try container.decodeIfPresent(VolvoField<String>.self, forKey: .workshopId)
        workshopName = try container.decodeIfPresent(VolvoField<String>.self, forKey: .workshopName)
    }

    var hasServiceWarning: Bool {
        guard let raw = serviceWarning?.value?.uppercased() else { return false }
        return !raw.contains("NO_WARNING") && !raw.isEmpty
    }


    var daysToServiceApprox: Int? {
        guard let value = timeToService?.value else { return nil }
        switch timeToService?.unit?.lowercased() {
        case "day", "days": return value
        case "month", "months": return value * 30
        default: return value
        }
    }

    var distanceToServiceKm: Int? {
        VolvoUnits.kilometers(distanceToService?.value, unit: distanceToService?.unit)
    }

    var fluidWarnings: [String] {
        let named: [(String?, String)] = [
            (brakeFluidLevelWarning?.value, L10n.text("Brake fluid")),
            (engineCoolantLevelWarning?.value, L10n.text("Coolant")),
            (oilLevelWarning?.value, L10n.text("Oil")),
            (washerFluidLevelWarning?.value, L10n.text("Washer fluid"))
        ]
        return named.compactMap { raw, label in
            guard let raw = raw?.uppercased(), !raw.contains("NO_WARNING"), !raw.isEmpty else { return nil }
            return label
        }
    }

    var vehicleWarnings: [VehicleWarning] {
        let candidates: [(String?, VehicleWarning)] = [
            (brakeFluidLevelWarning?.value, .brakeFluid), (engineCoolantLevelWarning?.value, .engineCoolant),
            (oilLevelWarning?.value, .oil), (washerFluidLevelWarning?.value, .washerFluid),
            (batteryChargeLevelWarning?.value, .lowVoltageBattery)
        ]
        var result = candidates.compactMap { raw, warning -> VehicleWarning? in
            guard let raw = raw?.uppercased(), !raw.contains("NO_WARNING"), !raw.isEmpty else { return nil }
            return warning
        }
        if hasServiceWarning { result.append(.service) }
        return result
    }
}


struct VolvoOdometerDTO: Decodable, Sendable {
    let odometer: VolvoField<Int>?

    var odometerKm: Int? { VolvoUnits.kilometers(odometer?.value, unit: odometer?.unit) }
}


struct VolvoStatisticsDTO: Decodable, Sendable {
    let tripMeterManual: VolvoField<Double>?
    let tripMeterAutomatic: VolvoField<Double>?
    let distanceToEmptyTank: VolvoField<Int>?
    let distanceToEmptyBattery: VolvoField<Int>?
    let averageFuelConsumption: VolvoField<Double>?
    let averageFuelConsumptionAutomatic: VolvoField<Double>?
    let averageEnergyConsumption: VolvoField<Double>?
    let averageEnergyConsumptionAutomatic: VolvoField<Double>?
    let averageEnergyConsumptionSinceCharge: VolvoField<Double>?
    let averageSpeed: VolvoField<Double>?
    let averageSpeedAutomatic: VolvoField<Double>?
    let electricDistance: VolvoField<Double>?
    let fuelDistance: VolvoField<Double>?
    let regeneratedEnergy: VolvoField<Double>?

    var tripMeterManualKm: Double? { VolvoUnits.kilometers(tripMeterManual?.value, unit: tripMeterManual?.unit) }
    var tripMeterAutomaticKm: Double? { VolvoUnits.kilometers(tripMeterAutomatic?.value, unit: tripMeterAutomatic?.unit) }
    var distanceToEmptyTankKm: Int? { VolvoUnits.kilometers(distanceToEmptyTank?.value, unit: distanceToEmptyTank?.unit) }
    var distanceToEmptyBatteryKm: Int? { VolvoUnits.kilometers(distanceToEmptyBattery?.value, unit: distanceToEmptyBattery?.unit) }
    var electricDistanceKm: Double? { VolvoUnits.kilometers(electricDistance?.value, unit: electricDistance?.unit) }
    var fuelDistanceKm: Double? { VolvoUnits.kilometers(fuelDistance?.value, unit: fuelDistance?.unit) }

    func energyConsumptionKwhPer100Km(_ field: VolvoField<Double>?) -> Double? {
        guard let value = field?.value else { return nil }
        switch field?.unit?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "wh/km": return value / 10
        case "kwh/km": return value * 100
        case "kwh/100mi", "kwh/100miles": return value / 1.609344
        default: return value
        }
    }

    var averageEnergyConsumptionKwhPer100Km: Double? {
        energyConsumptionKwhPer100Km(averageEnergyConsumption)
    }

    var averageEnergyConsumptionSinceChargeKwhPer100Km: Double? {
        energyConsumptionKwhPer100Km(averageEnergyConsumptionSinceCharge)
    }

    /// Average electric consumption over the automatic trip-meter period — pairs with
    /// `tripMeterAutomaticKm`, the same way `averageSpeedAutomatic` pairs with it.
    var averageEnergyConsumptionAutomaticKwhPer100Km: Double? {
        energyConsumptionKwhPer100Km(averageEnergyConsumptionAutomatic)
    }

    var averageSpeedKmH: Double? {
        let field = averageSpeedAutomatic ?? averageSpeed
        guard let value = field?.value else { return nil }
        return field?.unit?.lowercased() == "mph" ? value / 0.621371 : value
    }

    var regeneratedEnergyKwh: Double? {
        guard let value = regeneratedEnergy?.value else { return nil }
        switch regeneratedEnergy?.unit?.lowercased() {
        case "wh", "watt-hour", "watt-hours": return value / 1_000
        default: return value
        }
    }
}


struct VolvoFuelDTO: Decodable, Sendable {
    let fuelAmount: VolvoField<Double>?
    let fuelAmountLiters: VolvoField<Double>?
    let fuelLevelPercent: VolvoField<Double>?
    let batteryChargeLevel: VolvoField<Double>?
    let distanceToEmptyTank: VolvoField<Int>?
    let distanceToEmpty: VolvoField<Int>?

    var liters: Double? {
        fuelAmount?.value ?? fuelAmountLiters?.value
    }

    var percentage: Double? {
        fuelLevelPercent?.value
    }

    var rangeKm: Int? {
        if let distanceToEmpty {
            return VolvoUnits.kilometers(distanceToEmpty.value, unit: distanceToEmpty.unit)
        }
        return VolvoUnits.kilometers(distanceToEmptyTank?.value, unit: distanceToEmptyTank?.unit)
    }
}


struct VolvoCommandDTO: Decodable, Sendable {
    let command: String?
    let href: String?

    /// The last path segment of `href` is the *actual* invocation endpoint name and is what
    /// `dispatchCommand` POSTs to — prefer it. `command` (e.g. `HONK_AND_FLASH` while `href`
    /// ends `/honk-flash`, verified live) is only a display label and is the fallback.
    var normalizedName: String? {
        let source = href?.split(separator: "/").last.map(String.init) ?? command
        guard let source else { return nil }
        return source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}


struct VolvoLocationDTO: Decodable, Sendable {
    struct Properties: Decodable, Sendable {
        let heading: String?
        let timestamp: Date?
    }
    struct Geometry: Decodable, Sendable {
        let coordinates: [Double]?
    }
    let properties: Properties?
    let geometry: Geometry?

    var altitudeMeters: Double? {
        guard let coordinates = geometry?.coordinates, coordinates.count >= 3 else { return nil }
        return coordinates[2]
    }
}

struct VolvoEngineStatusDTO: Decodable, Sendable {
    let engineStatus: VolvoField<String>?

    var isRunning: Bool? {
        switch engineStatus?.value?.uppercased() {
        case "RUNNING": return true
        case "STOPPED": return false
        default: return nil
        }
    }
}

struct VolvoBrakesDTO: Decodable, Sendable {
    let brakeFluidLevelWarning: VolvoField<String>?
    let frontBrakePadStatus: VolvoField<String>?
    let rearBrakePadStatus: VolvoField<String>?
    let parkingBrakeStatus: VolvoField<String>?
}

struct VolvoCommandAccessibilityDTO: Decodable, Sendable {
    let availabilityStatus: VolvoField<String>?

    var isAvailable: Bool {
        availabilityStatus?.value?.uppercased() == "AVAILABLE"
    }

    var reason: String? {
        guard let raw = availabilityStatus?.unavailableReason?.uppercased() else { return nil }
        switch raw {
        case "NO_INTERNET": return L10n.text("Vehicle has no internet connection")
        case "POWER_SAVING_MODE": return L10n.text("Vehicle is in power-saving mode")
        case "CAR_IN_USE": return L10n.text("Vehicle is currently in use")
        case "UNSPECIFIED": return nil
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct VolvoWarningsDTO: Decodable, Sendable {
    let brakeLightCenterWarning: VolvoField<String>?
    let brakeLightLeftWarning: VolvoField<String>?
    let brakeLightRightWarning: VolvoField<String>?
    let fogLightFrontWarning: VolvoField<String>?
    let fogLightRearWarning: VolvoField<String>?
    let positionLightFrontLeftWarning: VolvoField<String>?
    let positionLightFrontRightWarning: VolvoField<String>?
    let positionLightRearLeftWarning: VolvoField<String>?
    let positionLightRearRightWarning: VolvoField<String>?
    let highBeamLeftWarning: VolvoField<String>?
    let highBeamRightWarning: VolvoField<String>?
    let lowBeamLeftWarning: VolvoField<String>?
    let lowBeamRightWarning: VolvoField<String>?
    let daytimeRunningLightLeftWarning: VolvoField<String>?
    let daytimeRunningLightRightWarning: VolvoField<String>?
    let turnIndicationFrontLeftWarning: VolvoField<String>?
    let turnIndicationFrontRightWarning: VolvoField<String>?
    let turnIndicationRearLeftWarning: VolvoField<String>?
    let turnIndicationRearRightWarning: VolvoField<String>?
    let registrationPlateLightWarning: VolvoField<String>?
    let sideMarkLightsWarning: VolvoField<String>?
    let hazardLightsWarning: VolvoField<String>?
    let reverseLightsWarning: VolvoField<String>?

    var activeWarnings: [String] {
        let list: [(VolvoField<String>?, String)] = [
            (brakeLightCenterWarning, L10n.text("Center brake light")),
            (brakeLightLeftWarning, L10n.text("Left brake light")),
            (brakeLightRightWarning, L10n.text("Right brake light")),
            (fogLightFrontWarning, L10n.text("Front fog light")),
            (fogLightRearWarning, L10n.text("Rear fog light")),
            (positionLightFrontLeftWarning, L10n.text("Front left position light")),
            (positionLightFrontRightWarning, L10n.text("Front right position light")),
            (positionLightRearLeftWarning, L10n.text("Rear left position light")),
            (positionLightRearRightWarning, L10n.text("Rear right position light")),
            (highBeamLeftWarning, L10n.text("Left high beam")),
            (highBeamRightWarning, L10n.text("Right high beam")),
            (lowBeamLeftWarning, L10n.text("Left low beam")),
            (lowBeamRightWarning, L10n.text("Right low beam")),
            (daytimeRunningLightLeftWarning, L10n.text("Left DRL")),
            (daytimeRunningLightRightWarning, L10n.text("Right DRL")),
            (turnIndicationFrontLeftWarning, L10n.text("Front left turn indicator")),
            (turnIndicationFrontRightWarning, L10n.text("Front right turn indicator")),
            (turnIndicationRearLeftWarning, L10n.text("Rear left turn indicator")),
            (turnIndicationRearRightWarning, L10n.text("Rear right turn indicator")),
            (registrationPlateLightWarning, L10n.text("License plate light")),
            (sideMarkLightsWarning, L10n.text("Side marker lights")),
            (hazardLightsWarning, L10n.text("Hazard warning lights")),
            (reverseLightsWarning, L10n.text("Reverse light"))
        ]
        return list.compactMap { field, name in
            guard let val = field?.value?.uppercased(), !val.contains("NO_WARNING"), val != "UNSPECIFIED", !val.isEmpty else { return nil }
            return "\(name): \(val)"
        }
    }

    var hasReportedLightStatus: Bool {
        let fields: [VolvoField<String>?] = [
            brakeLightCenterWarning, brakeLightLeftWarning, brakeLightRightWarning,
            fogLightFrontWarning, fogLightRearWarning,
            positionLightFrontLeftWarning, positionLightFrontRightWarning,
            positionLightRearLeftWarning, positionLightRearRightWarning,
            highBeamLeftWarning, highBeamRightWarning, lowBeamLeftWarning, lowBeamRightWarning,
            daytimeRunningLightLeftWarning, daytimeRunningLightRightWarning,
            turnIndicationFrontLeftWarning, turnIndicationFrontRightWarning,
            turnIndicationRearLeftWarning, turnIndicationRearRightWarning,
            registrationPlateLightWarning, sideMarkLightsWarning, hazardLightsWarning,
            reverseLightsWarning
        ]
        return fields.contains { field in
            guard let value = field?.value?.uppercased() else { return false }
            return !value.isEmpty && value != "UNSPECIFIED"
        }
    }
}


struct VolvoTokenResponseDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}



/// Response body of `POST /connected-vehicle/v2/vehicles/{vin}/commands/{name}`. Connected
/// Vehicle API v2 commands are synchronous — there is no `GET .../commands/{id}` status poll —
/// so the response's `invokeStatus` is the final word and `commandId` is not carried.
///
/// Previously parsed with untyped `JSONSerialization` dictionary lookups while every read-path
/// DTO was `Decodable`, which meant a shape change on Volvo's side degraded silently to a
/// generic `.accepted` instead of surfacing a decode error.
struct VolvoCommandResponseDTO: Decodable, Sendable {
    let invokeStatus: String?
    let message: String?
    let readyToUnlock: Bool?
    let readyToUnlockUntil: Int?

    /// Blank-normalised accessor — the API returns `""` as often as it omits the key, and
    /// an empty string surfaced to the UI reads as a missing message rather than no message.
    var text: String? { message?.blankAsNil }

    /// Volvo's documented `invokeStatus` values, upper-cased before comparison because the
    /// API has been observed returning both cases. The Connected Vehicle API v2 command docs
    /// enumerate exactly: RUNNING, WAITING, COMPLETED, REJECTED, UNKNOWN, TIMEOUT,
    /// CONNECTION_FAILURE, VEHICLE_IN_SLEEP, DELIVERED, CAR_ERROR, NOT_ALLOWED_PRIVACY_ENABLED,
    /// NOT_ALLOWED_WRONG_USAGE_MODE. The extra values below (`SUCCESS`, `NOT_ALLOWED`,
    /// `UNLOCK_TIME_FRAME_PASSED`, `UNABLE_TO_LOCK_DOOR_OPEN`, `FAILED`) are tolerated
    /// defensively — older captures and sibling APIs have returned them.
    var outcome: RemoteCommandOutcome? {
        switch invokeStatus?.uppercased() {
        case "COMPLETED", "SUCCESS": return .completed
        case "DELIVERED": return .delivered
        case "RUNNING", "WAITING", "ACCEPTED": return .accepted
        default: return nil
        }
    }

    /// A user-facing explanation when `invokeStatus` is a documented failure, or `nil` when the
    /// command was accepted / is still in progress. `UNKNOWN` is deliberately *not* a failure —
    /// it means "the vehicle's final state is not known yet", not "it was rejected".
    var failureReason: String? {
        switch invokeStatus?.uppercased() {
        case "REJECTED", "NOT_ALLOWED", "FAILED":
            return L10n.text("The vehicle rejected the command.")
        case "TIMEOUT":
            return L10n.text("The vehicle did not respond in time — it may be parked somewhere with no reception.")
        case "CONNECTION_FAILURE":
            return L10n.text("Hisingen could not reach the vehicle. It may be in an area with no connectivity.")
        case "VEHICLE_IN_SLEEP":
            return L10n.text("The vehicle is in sleep mode and did not receive the command. Try again in a few minutes.")
        case "CAR_ERROR":
            return L10n.text("The vehicle reported an internal error while handling the command.")
        case "NOT_ALLOWED_PRIVACY_ENABLED":
            return L10n.text("Remote commands are blocked while privacy mode is enabled in the vehicle.")
        case "NOT_ALLOWED_WRONG_USAGE_MODE":
            return L10n.text("The vehicle is not in a state that allows this command (for example, while it is being driven).")
        case "UNLOCK_TIME_FRAME_PASSED":
            return L10n.text("The unlock confirmation window passed before a door was opened. Send the command again.")
        case "UNABLE_TO_LOCK_DOOR_OPEN":
            return L10n.text("The vehicle could not lock because a door, the hood, or the tailgate is open.")
        default:
            return nil
        }
    }

    var isFailure: Bool { failureReason != nil }
}

/// Error envelope returned alongside a non-2xx command response.
struct VolvoCommandErrorDTO: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let message: String?
        let description: String?
    }
    let error: Detail?

    var text: String? {
        let value = error?.description ?? error?.message
        return value?.isEmpty == false ? value : nil
    }
}

extension String {
    /// Treats a whitespace-only string as absent, so `""` from the API and a missing key
    /// reach the UI the same way.
    var blankAsNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// Volvo's Connected Vehicle API v2 sometimes serialises an absent descriptor as the
    /// literal string `"null"` (confirmed live on `descriptions.upholstery`) rather than a
    /// JSON null. Collapse that — and blank strings — to a real `nil` so nothing renders it.
    var volvoMeaningful: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("null") != .orderedSame,
              trimmed.caseInsensitiveCompare("undefined") != .orderedSame
        else { return nil }
        return trimmed
    }
}
