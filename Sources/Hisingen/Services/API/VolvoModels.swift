import Foundation


struct VolvoField<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    let updatedAt: Date?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case updatedAt
        case timestamp
        case status
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.value) {
            value = try? container.decodeIfPresent(Value.self, forKey: .value)
            updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt))
                ?? (try? container.decodeIfPresent(Date.self, forKey: .timestamp))
                ?? nil
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            return
        }
        let single = try decoder.singleValueContainer()
        value = try? single.decode(Value.self)
        updatedAt = nil
        status = nil
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
        let internalImageUrl: String?
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
    let chargerConnectionStatus: VolvoField<String>?
    let chargingPower: VolvoField<Double>?
    let chargingCurrent: VolvoField<Double>?
    let chargingVoltage: VolvoField<Double>?
    let chargingCurrentLimit: VolvoField<Double>?
    let estimatedChargingTimeToFull: VolvoField<Double>?
    let estimatedChargingTimeToTargetBatteryChargeLevel: VolvoField<Double>?
    let targetBatteryLevel: VolvoField<Double>?
    let targetBatteryChargeLevel: VolvoField<Double>?

    var rangeKm: Int? {
        electricRange?.value.map { Int($0.rounded()) }
    }

    var targetPercent: Int? {
        (targetBatteryChargeLevel?.value ?? targetBatteryLevel?.value).map { Int($0.rounded()) }
    }

    var estTimeToTargetMinutes: Int? {
        (estimatedChargingTimeToTargetBatteryChargeLevel?.value ?? estimatedChargingTimeToFull?.value).map { Int($0.rounded()) }
    }
}

struct VolvoEnergyCapabilitiesDTO: Decodable, Sendable {
    let batteryChargeLevel: VolvoCapabilityFlag?
    let electricRange: VolvoCapabilityFlag?
    let chargingStatus: VolvoCapabilityFlag?
    let chargingPower: VolvoCapabilityFlag?
    let targetBatteryLevel: VolvoCapabilityFlag?
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

    var hasServiceWarning: Bool {
        guard let raw = serviceWarning?.value?.uppercased() else { return false }
        return !raw.contains("NO_WARNING") && !raw.isEmpty
    }


    var daysToServiceApprox: Int? {
        timeToService?.value.map { $0 * 30 }
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
}


struct VolvoStatisticsDTO: Decodable, Sendable {
    let tripMeterManual: VolvoField<Double>?
    let tripMeterAutomatic: VolvoField<Double>?
    let distanceToEmptyTank: VolvoField<Int>?
    let distanceToEmptyBattery: VolvoField<Int>?
    let averageFuelConsumption: VolvoField<Double>?
    let averageEnergyConsumption: VolvoField<Double>?
    let averageSpeed: VolvoField<Double>?
}


struct VolvoFuelDTO: Decodable, Sendable {
    let fuelAmount: VolvoField<Double>?
    let fuelAmountLiters: VolvoField<Double>?
    let fuelLevelPercent: VolvoField<Double>?
    let distanceToEmptyTank: VolvoField<Int>?
    let distanceToEmpty: VolvoField<Int>?

    var liters: Double? {
        fuelAmount?.value ?? fuelAmountLiters?.value
    }

    var percentage: Double? {
        fuelLevelPercent?.value
    }

    var rangeKm: Int? {
        distanceToEmpty?.value ?? distanceToEmptyTank?.value
    }
}


struct VolvoCommandDTO: Decodable, Sendable {
    let command: String?
    let href: String?
}

struct VolvoCommandsListDTO: Decodable, Sendable {
    let commands: [VolvoCommandDTO]?
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
}

struct VolvoEngineStatusDTO: Decodable, Sendable {
    let engineStatus: VolvoField<String>?

    var isRunning: Bool {
        engineStatus?.value?.uppercased() == "RUNNING"
    }
}

struct VolvoBrakesDTO: Decodable, Sendable {
    let brakeFluidLevelWarning: VolvoField<String>?
}

struct VolvoCommandAccessibilityDTO: Decodable, Sendable {
    let availabilityStatus: VolvoField<String>?

    var isAvailable: Bool {
        availabilityStatus?.value?.uppercased() == "AVAILABLE"
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
}


struct VolvoClimatizationDTO: Decodable, Sendable {
    let status: VolvoField<String>?
    let timeRemainingMinutes: VolvoField<Int>?
    let interiorTemperatureCelsius: VolvoField<Double>?
    let targetTemperatureCelsius: VolvoField<Double>?
    let preconditioning: VolvoField<String>?

    private enum CodingKeys: String, CodingKey {
        case status
        case climatizationStatus
        case parkedClimatization
        case parkingClimateStatus
        case preconditioning
        case preConditioningStatus
        case state

        case timeRemaining
        case timeRemainingMinutes
        case timeRemainingInMinutes
        case durationMinutes

        case interiorTemperature
        case interiorTemperatureCelsius
        case cabinTemperature
        case temperature

        case targetTemperature
        case targetTemperatureCelsius
        case setTemperature
        case requestedTemperature
    }

    init(
        status: VolvoField<String>? = nil,
        timeRemainingMinutes: VolvoField<Int>? = nil,
        interiorTemperatureCelsius: VolvoField<Double>? = nil,
        targetTemperatureCelsius: VolvoField<Double>? = nil,
        preconditioning: VolvoField<String>? = nil
    ) {
        self.status = status
        self.timeRemainingMinutes = timeRemainingMinutes
        self.interiorTemperatureCelsius = interiorTemperatureCelsius
        self.targetTemperatureCelsius = targetTemperatureCelsius
        self.preconditioning = preconditioning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Status field fallback cascade
        self.status = try container.decodeIfPresent(VolvoField<String>.self, forKey: .status)
            ?? container.decodeIfPresent(VolvoField<String>.self, forKey: .climatizationStatus)
            ?? container.decodeIfPresent(VolvoField<String>.self, forKey: .parkedClimatization)
            ?? container.decodeIfPresent(VolvoField<String>.self, forKey: .parkingClimateStatus)
            ?? container.decodeIfPresent(VolvoField<String>.self, forKey: .state)

        // Preconditioning fallback
        self.preconditioning = try container.decodeIfPresent(VolvoField<String>.self, forKey: .preconditioning)
            ?? container.decodeIfPresent(VolvoField<String>.self, forKey: .preConditioningStatus)

        // Time remaining fallback
        self.timeRemainingMinutes = try container.decodeIfPresent(VolvoField<Int>.self, forKey: .timeRemaining)
            ?? container.decodeIfPresent(VolvoField<Int>.self, forKey: .timeRemainingMinutes)
            ?? container.decodeIfPresent(VolvoField<Int>.self, forKey: .timeRemainingInMinutes)
            ?? container.decodeIfPresent(VolvoField<Int>.self, forKey: .durationMinutes)

        // Interior temperature fallback
        self.interiorTemperatureCelsius = try container.decodeIfPresent(VolvoField<Double>.self, forKey: .interiorTemperature)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .interiorTemperatureCelsius)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .cabinTemperature)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .temperature)

        // Target temperature fallback
        self.targetTemperatureCelsius = try container.decodeIfPresent(VolvoField<Double>.self, forKey: .targetTemperature)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .targetTemperatureCelsius)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .setTemperature)
            ?? container.decodeIfPresent(VolvoField<Double>.self, forKey: .requestedTemperature)
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


