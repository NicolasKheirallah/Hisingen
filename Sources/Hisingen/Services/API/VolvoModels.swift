import Foundation


struct VolvoField<Value: Decodable>: Decodable {
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

private struct VolvoEnvelopeWrapper<Payload: Decodable>: Decodable {
    let data: Payload
}


struct VolvoEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?

    init(from decoder: Decoder) throws {
        if let wrapped = try? VolvoEnvelopeWrapper<Payload>(from: decoder) {
            data = wrapped.data
            return
        }
        data = try? Payload(from: decoder)
    }
}


struct VolvoVehicleSummaryDTO: Decodable {
    let vin: String
}

struct VolvoVehicleDetailsDTO: Decodable {
    let vin: String?
    let modelYear: Int?
    let descriptions: Descriptions?
    let fuelType: String?
    let batteryCapacityKWH: Double?
    let images: Images?

    struct Descriptions: Decodable {
        let model: String?
        let upholstery: String?
        let steering: String?
    }

    struct Images: Decodable {
        let exteriorImageUrl: String?
    }
}


enum VolvoPowertrain {
    static func classify(fuelType: String?) -> PowertrainType {
        guard let raw = fuelType?.uppercased() else { return .unknown }
        let hasElectric = raw.contains("ELECTRIC")
        let hasFuel = raw.contains("PETROL") || raw.contains("DIESEL")
        let isMildHybrid = raw.contains("MHEV") || raw.contains("HYBRID") && !raw.contains("PLUG")
        if raw == "NONE" && hasElectric { return .bev }
        if hasElectric && hasFuel { return isMildHybrid ? .mildHybrid : .phev }
        if hasElectric { return .bev }
        if hasFuel { return .ice }
        return .unknown
    }
}


struct VolvoEnergyStateDTO: Decodable {
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

struct VolvoEnergyCapabilitiesDTO: Decodable {
    let batteryChargeLevel: VolvoCapabilityFlag?
    let electricRange: VolvoCapabilityFlag?
    let chargingStatus: VolvoCapabilityFlag?
    let chargingPower: VolvoCapabilityFlag?
    let targetBatteryLevel: VolvoCapabilityFlag?
}

struct VolvoCapabilityFlag: Decodable {
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


struct VolvoDoorsDTO: Decodable {
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

struct VolvoWindowsDTO: Decodable {
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


struct VolvoTyresDTO: Decodable {
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


struct VolvoDiagnosticsDTO: Decodable {
    let serviceWarning: VolvoField<String>?


    let timeToService: VolvoField<Int>?


    let distanceToService: VolvoField<Int>?
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


struct VolvoOdometerDTO: Decodable {
    let odometer: VolvoField<Int>?
}


struct VolvoStatisticsDTO: Decodable {
    let tripMeterManual: VolvoField<Double>?
    let tripMeterAutomatic: VolvoField<Double>?
    let distanceToEmptyTank: VolvoField<Int>?
    let distanceToEmptyBattery: VolvoField<Int>?
    let averageFuelConsumption: VolvoField<Double>?
    let averageEnergyConsumption: VolvoField<Double>?
    let averageSpeed: VolvoField<Double>?
}


struct VolvoFuelDTO: Decodable {
    let fuelAmount: VolvoField<Double>?
}


struct VolvoCommandDTO: Decodable {
    let command: String?
    let href: String?
}

struct VolvoCommandsListDTO: Decodable {
    let commands: [VolvoCommandDTO]?
}


struct VolvoLocationDTO: Decodable {
    struct Properties: Decodable {
        let heading: String?
        let timestamp: Date?
    }
    struct Geometry: Decodable {
        let coordinates: [Double]?
    }
    let properties: Properties?
    let geometry: Geometry?
}


struct VolvoTokenResponseDTO: Decodable {
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


