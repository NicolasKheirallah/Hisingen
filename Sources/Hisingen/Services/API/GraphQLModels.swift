import Foundation

struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLErrorDTO]?
}

struct GraphQLErrorDTO: Decodable {
    let message: String
    let path: [String]
    let extensions: Extensions?

    struct Extensions: Decodable {
        let code: String?
        let errorType: String?
    }

    var code: String? { extensions?.code ?? extensions?.errorType }

    private enum CodingKeys: String, CodingKey { case message, path, extensions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? container.decode(String.self, forKey: .message)) ?? "GraphQL error"
        extensions = try? container.decode(Extensions.self, forKey: .extensions)
        if var pathContainer = try? container.nestedUnkeyedContainer(forKey: .path) {
            var values: [String] = []
            pathLoop: while !pathContainer.isAtEnd {
                if let value = try? pathContainer.decode(String.self) { values.append(value) }
                else if let value = try? pathContainer.decode(Int.self) { values.append(String(value)) }
                else { break pathLoop }
            }
            path = values
        } else {
            path = []
        }
    }
}

struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = Int(value); return }
        if let value = try? container.decode(String.self), let parsed = Int(value) {
            self.value = parsed
            return
        }
        throw DecodingError.typeMismatch(
            Int.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected integer-compatible value")
        )
    }
}

struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self.value = value; return }
        if let value = try? container.decode(Int.self) { self.value = Double(value); return }
        if let value = try? container.decode(String.self), let parsed = Double(value) {
            self.value = parsed
            return
        }
        throw DecodingError.typeMismatch(
            Double.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected number-compatible value")
        )
    }
}

struct StringOrInt: Decodable {
    let value: String

    init(value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value; return }
        if let value = try? container.decode(Int.self) { self.value = String(value); return }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected string-compatible value")
        )
    }
}

struct TimestampDTO: Decodable {
    let seconds: FlexibleInt?

    var date: Date? {
        guard let value = seconds?.value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}


struct FlexibleChargingStatus: Decodable {
    let value: String?


    private static let numericMapping: [String: String] = [
        "0": "CHARGING_STATUS_IDLE",
        "1": "CHARGING_STATUS_CHARGING",
        "2": "CHARGING_STATUS_FAULT",
        "3": "CHARGING_STATUS_SCHEDULED",
        "4": "CHARGING_STATUS_DISCHARGING",
        "5": "CHARGING_STATUS_DONE",
        "6": "CHARGING_STATUS_SMART_CHARGING",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.value = nil; return }
        guard let raw = try? container.decode(String.self) else {

            self.value = nil
            return
        }
        if Self.numericMapping.keys.contains(raw) {
            self.value = Self.numericMapping[raw]
        } else {
            self.value = raw
        }
    }
}


struct TelematicsPayloadDTO: Decodable {
    let carTelematicsV2: TelematicsDTO?
}


struct TelematicsDTO: Decodable {
    let battery: [BatteryDTO]?
    let odometer: [OdometerDTO]?
    let health: [HealthDTO]?
}

struct BatteryDTO: Decodable {

    let vin: String?

    let batteryChargeLevelPercentage: FlexibleDouble?

    let estimatedDistanceToEmptyKm: FlexibleInt?


    let chargingStatusV2: FlexibleChargingStatus?


    let estimatedChargingTimeToFullMinutes: FlexibleInt?

    let timestamp: TimestampDTO?
}

struct OdometerDTO: Decodable {

    let vin: String?

    let odometerMeters: FlexibleInt?

    let timestamp: TimestampDTO?
}

struct HealthDTO: Decodable {

    let vin: String?

    let daysToService: FlexibleInt?

    let distanceToServiceKm: FlexibleInt?

    let serviceWarning: String?

    let brakeFluidLevelWarning: String?

    let engineCoolantLevelWarning: String?

    let oilLevelWarning: String?

    let timestamp: TimestampDTO?
}

struct ConsumerCarsPayloadDTO: Decodable {
    let getConsumerCarsV2: [ConsumerCarDTO]?
}

struct ConsumerCarDTO: Decodable {
    let vin: String?
    let internalVehicleIdentifier: String?
    let modelName: String?
    let modelYear: StringOrInt?
    let registrationNo: String?
    let pno34: String?
    let structureWeek: StringOrInt?
    let exteriorColorName: String?
    let upholsteryName: String?
    let wheelsName: String?
    let packageNames: [String]

    init(vin: String?, internalVehicleIdentifier: String? = nil,
         modelName: String?, modelYear: StringOrInt?, registrationNo: String?,
         pno34: String?, structureWeek: StringOrInt?,
         exteriorColorName: String? = nil, upholsteryName: String? = nil,
         wheelsName: String? = nil, packageNames: [String] = []) {
        self.vin = vin
        self.internalVehicleIdentifier = internalVehicleIdentifier
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
        self.pno34 = pno34
        self.structureWeek = structureWeek
        self.exteriorColorName = exteriorColorName
        self.upholsteryName = upholsteryName
        self.wheelsName = wheelsName
        self.packageNames = packageNames
    }

    private enum CodingKeys: String, CodingKey {
        case vin, internalVehicleIdentifier, modelName, modelYear
        case registrationNo, pno34, structureWeek, exteriorColorName, upholsteryName, wheelsName, packageNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = try container.decodeIfPresent(String.self, forKey: .vin)
        internalVehicleIdentifier = try container.decodeIfPresent(String.self, forKey: .internalVehicleIdentifier)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        modelYear = try container.decodeIfPresent(StringOrInt.self, forKey: .modelYear)
        registrationNo = try container.decodeIfPresent(String.self, forKey: .registrationNo)
        pno34 = try container.decodeIfPresent(String.self, forKey: .pno34)
        structureWeek = try container.decodeIfPresent(StringOrInt.self, forKey: .structureWeek)
        exteriorColorName = try container.decodeIfPresent(String.self, forKey: .exteriorColorName)
        upholsteryName = try container.decodeIfPresent(String.self, forKey: .upholsteryName)
        wheelsName = try container.decodeIfPresent(String.self, forKey: .wheelsName)
        packageNames = try container.decodeIfPresent([String].self, forKey: .packageNames) ?? []
    }
}

struct AppBackendCarsPayloadDTO: Decodable {
    let vdms: VDMSCarsDTO?
}

struct VDMSCarsDTO: Decodable {
    let getVehiclesInformation: [AppBackendCarDTO]?
}

struct AppBackendCarDTO: Decodable {
    let vin: String?
    let internalVehicleIdentifier: String?
    let registrationNo: String?
    let modelYear: StringOrInt?
    let content: Content?

    struct Content: Decodable {
        let model: Model?
        let exterior: NamedOption?
        let exteriorColor: NamedOption?
        let interior: NamedOption?
        let upholstery: NamedOption?
        let wheels: NamedOption?
        let packages: [NamedOption]?

        private enum CodingKeys: String, CodingKey {
            case model, exterior, exteriorColor, interior, upholstery, wheels, packages
        }
    }

    struct NamedOption: Decodable {
        let name: String?
    }

    struct Model: Decodable {
        let name: String?
    }

    var consumerCar: ConsumerCarDTO {
        ConsumerCarDTO(
            vin: vin,
            internalVehicleIdentifier: internalVehicleIdentifier,
            modelName: content?.model?.name,
            modelYear: modelYear,
            registrationNo: registrationNo,
            pno34: nil,
            structureWeek: nil,
            exteriorColorName: content?.exterior?.name ?? content?.exteriorColor?.name,
            upholsteryName: content?.interior?.name ?? content?.upholstery?.name,
            wheelsName: content?.wheels?.name,
            packageNames: content?.packages?.compactMap(\.name) ?? []
        )
    }
}

struct UserInfoDTO: Decodable {
    let givenName: String?
    let firstName: String?
    let market: String?

    private enum CodingKeys: String, CodingKey {
        case givenName = "given_name"
        case firstName = "firstname"
        case market
    }
}

struct TokenResponseDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try container.decode(FlexibleInt.self, forKey: .expiresIn).value
    }
}


