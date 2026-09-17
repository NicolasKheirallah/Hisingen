import Foundation

// MARK: - Envelopes and Common Types

struct PolestarDataPortalTimestamp: Codable, Sendable, Equatable {
    let seconds: String?
    let nanos: Int?

    var date: Date? {
        guard let seconds, let sec = Double(seconds) else { return nil }
        let nanoOffset = Double(nanos ?? 0) / 1_000_000_000.0
        return Date(timeIntervalSince1970: sec + nanoOffset)
    }
}

struct PolestarDataPortalMeta: Codable, Sendable, Equatable {
    let vin: String
    let domain: String
}

struct PolestarDataPortalEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T?
    let meta: PolestarDataPortalMeta?
}

typealias PolestarDataPortalBatteryDTO = PolestarBatteryDTO
typealias PolestarDataPortalExteriorDTO = PolestarExteriorDTO
typealias PolestarDataPortalHealthDTO = PolestarHealthDTO
typealias PolestarDataPortalAvailabilityDTO = PolestarAvailabilityDTO
typealias PolestarDataPortalOdometerDTO = PolestarOdometerDTO
typealias PolestarDataPortalLocationDTO = PolestarLocationDTO

struct PolestarDataPortalTokenResponse: Codable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresIn
        case tokenType
    }
}

struct PolestarDataPortalTokenError: Codable, Sendable {
    let error: String
    let errorDescription: String?
    let requestId: String?
    let timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case requestId
        case timestamp
    }
}

struct PolestarDataPortalAPIError: Codable, Sendable {
    struct ErrorBody: Codable, Sendable {
        let code: String
        let message: String
        let httpStatus: Int?
        let requestId: String?
        let timestamp: String?
    }
    let error: ErrorBody
}

// MARK: - Vehicle Discovery

struct PolestarDataPortalVehiclesDTO: Codable, Sendable {
    let vins: [String]

    init(vins: [String]) {
        self.vins = vins
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let stringList = try? container.decode([String].self) {
            self.vins = stringList
            return
        }
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKeys.self) {
            if let dataKey = DynamicCodingKeys(stringValue: "data") {
                if let list = try? keyed.decode([String].self, forKey: dataKey) {
                    self.vins = list
                    return
                }
                if let objList = try? keyed.decode([VINObject].self, forKey: dataKey) {
                    self.vins = objList.map(\.vin)
                    return
                }
            }
        }
        self.vins = []
    }

    private struct VINObject: Decodable {
        let vin: String
    }

    private struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Telemetry DTOs

struct PolestarAvailabilityDTO: Codable, Sendable, Equatable {
    let vin: String
    let timestamp: PolestarDataPortalTimestamp?
    let availabilityStatus: String?
    let unavailableReason: String?
    let usageMode: String?
    let metaReceivedAt: String?
    let metaEventId: String?
}

struct PolestarDischargeInfoDTO: Codable, Sendable, Equatable {
    let energyAvailable: Double?
    let energyAvailableIncrease: Double?
    let powerLimit: Double?
}

struct PolestarEnergyBreakdownDTO: Codable, Sendable, Equatable {
    let driving: Double?
    let climate: Double?
    let battery: Double?
    let other: Double?
}

struct PolestarPreconditioningDTO: Codable, Sendable, Equatable {
    let preconditioningStatus: String?
    let unavailableReason: String?
    let startedAt: PolestarDataPortalTimestamp?
    let endingAt: PolestarDataPortalTimestamp?
}

struct PolestarBatteryDTO: Codable, Sendable, Equatable {
    let vin: String
    let timestamp: PolestarDataPortalTimestamp?
    let averageEnergyConsumptionKwhPer100Km: Double?
    let averageEnergyConsumptionKwhPer100KmAutomatic: Double?
    let averageEnergyConsumptionKwhPer100KmSinceCharge: Double?
    let batteryChargeLevelPercentage: Double?
    let chargerConnectionStatus: String?
    let chargerPowerStatus: String?
    let chargingCurrentAmps: Double?
    let chargingPowerWatts: Double?
    let chargingStatus: String?
    let chargingStatusV2: String?
    let chargingType: String?
    let chargingVoltageVolts: Double?
    let dischargeInfo: PolestarDischargeInfoDTO?
    let energyConsumptionPercentageManual: PolestarEnergyBreakdownDTO?
    let energyConsumptionPercentageAutomatic: PolestarEnergyBreakdownDTO?
    let energyConsumptionPercentageSinceCharge: PolestarEnergyBreakdownDTO?
    let energyConsumptionWhManual: PolestarEnergyBreakdownDTO?
    let energyConsumptionWhAutomatic: PolestarEnergyBreakdownDTO?
    let energyConsumptionWhSinceCharge: PolestarEnergyBreakdownDTO?
    let estimatedChargingTimeToFullMinutes: Double?
    let estimatedChargingTimeMinutesToTargetDistance: Double?
    let estimatedChargingTimeMinutesToMinimumSoc: Double?
    let estimatedDistanceToEmptyKm: Double?
    let estimatedDistanceToEmptyMiles: Double?
    let manualPreconditioning: PolestarPreconditioningDTO?
    let totalEnergyConsumptionWh: Double?
    let totalEnergyConsumptionWhAutomatic: Double?
    let totalEnergyConsumptionWhSinceCharge: Double?
    let metaReceivedAt: String?
    let metaEventId: String?
}

struct PolestarExteriorDTO: Codable, Sendable, Equatable {
    let vin: String
    let timestamp: PolestarDataPortalTimestamp?
    let centralLock: String?
    let frontLeftDoor: String?
    let frontRightDoor: String?
    let rearLeftDoor: String?
    let rearRightDoor: String?
    let frontLeftWindow: String?
    let frontRightWindow: String?
    let rearLeftWindow: String?
    let rearRightWindow: String?
    let hood: String?
    let tailgate: String?
    let tankLid: String?
    let sunroof: String?
    let alarm: String?
    let tailgateLock: String?
    let metaReceivedAt: String?
    let metaEventId: String?
}

struct PolestarHealthDTO: Codable, Sendable, Equatable {
    let vin: String
    let timestamp: PolestarDataPortalTimestamp?
    let engineHoursToService: Double?
    let daysToService: Double?
    let distanceToServiceKm: Double?
    let serviceWarning: String?
    let brakeFluidLevelWarning: String?
    let engineCoolantLevelWarning: String?
    let oilLevelWarning: String?
    let washerFluidLevelWarning: String?
    let frontLeftTyrePressureWarning: String?
    let frontRightTyrePressureWarning: String?
    let rearLeftTyrePressureWarning: String?
    let rearRightTyrePressureWarning: String?
    let frontLeftTyrePressureKpa: Double?
    let frontRightTyrePressureKpa: Double?
    let rearLeftTyrePressureKpa: Double?
    let rearRightTyrePressureKpa: Double?
    let frontTyresReferencePressureKpa: Double?
    let rearTyresReferencePressureKpa: Double?
    let lowVoltageBatteryWarning: String?
    let lightWarnings: [String: String]?
    let metaReceivedAt: String?
    let metaEventId: String?
}

// MARK: - Domain Mappers

extension PolestarBatteryDTO {
    func toEnergySnapshot() -> EnergyAndChargingSnapshot {
        let chargeState = ChargingState(apiValue: chargingStatusV2 ?? chargingStatus)
        let conn: ChargerConnection = {
            guard let status = chargerConnectionStatus?.uppercased() else { return .unknown }
            if status.contains("CONNECTED") { return .connected }
            if status.contains("DISCONNECTED") { return .disconnected }
            if status.contains("FAULT") || status.contains("ERROR") { return .fault }
            return .unknown
        }()

        let chgType: ChargingType = {
            guard let t = chargingType?.uppercased() else { return .unknown }
            if t.contains("AC") { return .ac }
            if t.contains("DC") { return .dc }
            if t.contains("WIRELESS") { return .wireless }
            if t.contains("NONE") { return .none }
            return .unknown
        }()

        let powerState: ChargerPowerState = {
            guard let p = chargerPowerStatus?.uppercased() else { return .unknown }
            if p.contains("PROVIDING") { return .providingPower }
            if p.contains("AVAILABLE") { return .available }
            if p.contains("INITIALIZING") { return .initializing }
            if p.contains("NO_POWER") { return .noPower }
            if p.contains("FAULT") { return .fault }
            return .unknown
        }()

        let breakdown: EnergyBreakdownSnapshot? = {
            let whSource = energyConsumptionWhSinceCharge ?? energyConsumptionWhAutomatic ?? energyConsumptionWhManual
            let pctSource = energyConsumptionPercentageSinceCharge ?? energyConsumptionPercentageAutomatic ?? energyConsumptionPercentageManual
            guard whSource != nil || pctSource != nil else { return nil }
            return EnergyBreakdownSnapshot(
                driving: EnergyBreakdownItem(wattHours: whSource?.driving, percentage: pctSource?.driving),
                climate: EnergyBreakdownItem(wattHours: whSource?.climate, percentage: pctSource?.climate),
                battery: EnergyBreakdownItem(wattHours: whSource?.battery, percentage: pctSource?.battery),
                other: EnergyBreakdownItem(wattHours: whSource?.other, percentage: pctSource?.other)
            )
        }()

        let diag = BatteryDiagnostics(
            timeToTargetMinutes: estimatedChargingTimeMinutesToTargetDistance.map { Int($0.rounded()) },
            timeToMinimumSOCMinutes: estimatedChargingTimeMinutesToMinimumSoc.map { Int($0.rounded()) },
            chargerPowerState: powerState,
            averageConsumption: averageEnergyConsumptionKwhPer100Km,
            averageConsumptionSinceCharge: averageEnergyConsumptionKwhPer100KmSinceCharge,
            averageConsumptionAutomatic: averageEnergyConsumptionKwhPer100KmAutomatic,
            energyUsedSinceChargeWh: totalEnergyConsumptionWhSinceCharge ?? totalEnergyConsumptionWhAutomatic ?? totalEnergyConsumptionWh,
            energyBreakdown: breakdown,
            powerLimitKw: dischargeInfo?.powerLimit,
            energyAvailableKwh: dischargeInfo?.energyAvailable
        )

        return EnergyAndChargingSnapshot(
            batteryPercentage: batteryChargeLevelPercentage,
            rangeKm: estimatedDistanceToEmptyKm.map { Int($0.rounded()) },
            chargingState: chargeState,
            estimatedTimeToFullMinutes: estimatedChargingTimeToFullMinutes.map { Int($0.rounded()) },
            estimatedTimeToTargetMinutes: estimatedChargingTimeMinutesToTargetDistance.map { Int($0.rounded()) },
            powerWatts: chargingPowerWatts.map { Int($0.rounded()) },
            currentAmps: chargingCurrentAmps.map { Int($0.rounded()) },
            voltageVolts: chargingVoltageVolts.map { Int($0.rounded()) },
            type: chgType,
            connection: conn,
            diagnostics: diag
        )
    }
}

extension PolestarExteriorDTO {
    func toExteriorSnapshot() -> ExteriorSnapshot {
        var readings: [OpeningReading] = []

        func parseOpening(_ raw: String?) -> OpeningState {
            guard let raw = raw?.uppercased() else { return .unknown }
            if raw.contains("OPEN") { return .open }
            if raw.contains("CLOSED") { return .closed }
            if raw.contains("AJAR") { return .ajar }
            return .unknown
        }

        func append(_ opening: VehicleOpening, value: String?) {
            let state = parseOpening(value)
            if state != .unknown {
                readings.append(OpeningReading(opening: opening, state: state))
            }
        }

        append(.frontLeftDoor, value: frontLeftDoor)
        append(.frontRightDoor, value: frontRightDoor)
        append(.rearLeftDoor, value: rearLeftDoor)
        append(.rearRightDoor, value: rearRightDoor)
        append(.frontLeftWindow, value: frontLeftWindow)
        append(.frontRightWindow, value: frontRightWindow)
        append(.rearLeftWindow, value: rearLeftWindow)
        append(.rearRightWindow, value: rearRightWindow)
        append(.hood, value: hood)
        append(.tailgate, value: tailgate)
        append(.chargeLid, value: tankLid)
        append(.sunroof, value: sunroof)

        let locked: Bool? = {
            guard let c = centralLock?.uppercased() else { return nil }
            if c.contains("UNLOCKED") { return false }
            if c.contains("LOCKED") { return true }
            return nil
        }()

        let alarm: Bool? = {
            guard let a = self.alarm?.uppercased() else { return nil }
            return a.contains("TRIGGERED") || a.contains("ALARM")
        }()

        let tailgateLocked: Bool? = {
            guard let t = tailgateLock?.uppercased() else { return nil }
            if t.contains("UNLOCKED") { return false }
            if t.contains("LOCKED") { return true }
            return nil
        }()

        return ExteriorSnapshot(
            openings: readings,
            isLocked: locked,
            alarmTriggered: alarm,
            isTailgateLocked: tailgateLocked,
            reportedAt: timestamp?.date
        )
    }
}

extension PolestarHealthDTO {
    func toMaintenanceSnapshot() -> MaintenanceAndHealthSnapshot {
        var warnings: [VehicleWarning] = []
        var reported: [VehicleWarning] = []

        func checkWarning(_ raw: String?, warning: VehicleWarning) {
            guard let raw = raw?.uppercased() else { return }
            reported.append(warning)
            if raw.contains("WARNING") || raw.contains("LOW") || raw.contains("FAULT") || raw == "TRUE" {
                warnings.append(warning)
            }
        }

        checkWarning(serviceWarning, warning: .service)
        checkWarning(brakeFluidLevelWarning, warning: .brakeFluid)
        checkWarning(engineCoolantLevelWarning, warning: .engineCoolant)
        checkWarning(oilLevelWarning, warning: .oil)
        checkWarning(washerFluidLevelWarning, warning: .washerFluid)
        checkWarning(lowVoltageBatteryWarning, warning: .lowVoltageBattery)

        func parseTyrePressure(_ rawWarn: String?, kpa: Double?, refKpa: Double?, pos: TyrePosition) -> TyrePressure {
            let warn: TyrePressureWarning = {
                guard let w = rawWarn?.uppercased() else { return .none }
                if w.contains("VERY_LOW") { return .veryLow }
                if w.contains("LOW") { return .low }
                if w.contains("HIGH") { return .high }
                if w.contains("FAULT") { return .sensorFault }
                return .none
            }()
            return TyrePressure(position: pos, kilopascals: kpa, warning: warn, referenceKilopascals: refKpa)
        }

        let tyres = [
            parseTyrePressure(frontLeftTyrePressureWarning, kpa: frontLeftTyrePressureKpa, refKpa: frontTyresReferencePressureKpa, pos: .frontLeft),
            parseTyrePressure(frontRightTyrePressureWarning, kpa: frontRightTyrePressureKpa, refKpa: frontTyresReferencePressureKpa, pos: .frontRight),
            parseTyrePressure(rearLeftTyrePressureWarning, kpa: rearLeftTyrePressureKpa, refKpa: rearTyresReferencePressureKpa, pos: .rearLeft),
            parseTyrePressure(rearRightTyrePressureWarning, kpa: rearRightTyrePressureKpa, refKpa: rearTyresReferencePressureKpa, pos: .rearRight)
        ]

        if tyres.contains(where: { $0.warning.needsAttention }) {
            warnings.append(.tyrePressure)
        }
        reported.append(.tyrePressure)

        var lightFaults: [String] = []
        if let lightWarnings {
            for (lightName, status) in lightWarnings {
                let st = status.uppercased()
                if st.contains("FAULT") || st.contains("WARNING") || st.contains("DEFECT") || st == "TRUE" {
                    lightFaults.append(lightName)
                }
            }
        }
        if !lightFaults.isEmpty {
            warnings.append(.exteriorLight)
        }
        reported.append(.exteriorLight)

        let details = VehicleHealthDetails(
            tyres: tyres,
            warnings: warnings,
            reportedWarnings: reported,
            lightFailures: lightFaults
        )

        let isServiceWarn = (serviceWarning?.uppercased().contains("WARNING") ?? false)
            || (serviceWarning?.uppercased() == "TRUE")

        var fluidWarningNames: [String] = []
        if brakeFluidLevelWarning?.uppercased().contains("WARNING") == true { fluidWarningNames.append("Brake Fluid") }
        if engineCoolantLevelWarning?.uppercased().contains("WARNING") == true { fluidWarningNames.append("Coolant") }
        if oilLevelWarning?.uppercased().contains("WARNING") == true { fluidWarningNames.append("Oil") }
        if washerFluidLevelWarning?.uppercased().contains("WARNING") == true { fluidWarningNames.append("Washer Fluid") }

        let service = ServiceSnapshot(
            daysToService: daysToService.map { Int($0.rounded()) },
            distanceToServiceKm: distanceToServiceKm.map { Int($0.rounded()) },
            serviceWarning: isServiceWarn,
            fluidWarnings: fluidWarningNames,
            engineHoursToService: engineHoursToService.map { Int($0.rounded()) }
        )

        return MaintenanceAndHealthSnapshot(
            details: details,
            service: service
        )
    }
}

// MARK: - Odometer Telemetry

struct PolestarOdometerDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let odometerMeters: Double?
    let odometerKm: Double?
    let meta: PolestarDataPortalMeta?

    enum CodingKeys: String, CodingKey {
        case vin, timestamp, odometerMeters, odometerInMeters, odometerKm, meta
    }

    init(
        vin: String? = nil,
        timestamp: PolestarDataPortalTimestamp? = nil,
        odometerMeters: Double? = nil,
        odometerKm: Double? = nil,
        meta: PolestarDataPortalMeta? = nil
    ) {
        self.vin = vin
        self.timestamp = timestamp
        self.odometerMeters = odometerMeters
        self.odometerKm = odometerKm
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.vin = try container.decodeIfPresent(String.self, forKey: .vin)
        self.timestamp = try container.decodeIfPresent(PolestarDataPortalTimestamp.self, forKey: .timestamp)
        self.odometerKm = try container.decodeIfPresent(Double.self, forKey: .odometerKm)
        let meters = try container.decodeIfPresent(Double.self, forKey: .odometerMeters)
            ?? container.decodeIfPresent(Double.self, forKey: .odometerInMeters)
        self.odometerMeters = meters
        self.meta = try container.decodeIfPresent(PolestarDataPortalMeta.self, forKey: .meta)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(vin, forKey: .vin)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(odometerMeters, forKey: .odometerMeters)
        try container.encodeIfPresent(odometerKm, forKey: .odometerKm)
        try container.encodeIfPresent(meta, forKey: .meta)
    }

    var calculatedOdometerKm: Int? {
        if let km = odometerKm {
            return Int(km.rounded())
        }
        if let meters = odometerMeters {
            return Int((meters / 1000.0).rounded())
        }
        return nil
    }
}

// MARK: - Location Telemetry

struct PolestarLocationDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let latitude: Double?
    let longitude: Double?
    let headingDegrees: Double?
    let altitudeMeters: Double?
    let speedMetersPerSecond: Double?
    let accuracyMeters: Double?
    let meta: PolestarDataPortalMeta?

    enum CodingKeys: String, CodingKey {
        case vin, timestamp, latitude, longitude
        case headingDegrees, heading
        case altitudeMeters, altitude
        case speedMetersPerSecond, speed
        case accuracyMeters, accuracy
        case meta
    }

    init(
        vin: String? = nil,
        timestamp: PolestarDataPortalTimestamp? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        headingDegrees: Double? = nil,
        altitudeMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        accuracyMeters: Double? = nil,
        meta: PolestarDataPortalMeta? = nil
    ) {
        self.vin = vin
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.headingDegrees = headingDegrees
        self.altitudeMeters = altitudeMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.accuracyMeters = accuracyMeters
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.vin = try container.decodeIfPresent(String.self, forKey: .vin)
        self.timestamp = try container.decodeIfPresent(PolestarDataPortalTimestamp.self, forKey: .timestamp)
        self.latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        self.longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        self.headingDegrees = try container.decodeIfPresent(Double.self, forKey: .headingDegrees)
            ?? container.decodeIfPresent(Double.self, forKey: .heading)
        self.altitudeMeters = try container.decodeIfPresent(Double.self, forKey: .altitudeMeters)
            ?? container.decodeIfPresent(Double.self, forKey: .altitude)
        self.speedMetersPerSecond = try container.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond)
            ?? container.decodeIfPresent(Double.self, forKey: .speed)
        self.accuracyMeters = try container.decodeIfPresent(Double.self, forKey: .accuracyMeters)
            ?? container.decodeIfPresent(Double.self, forKey: .accuracy)
        self.meta = try container.decodeIfPresent(PolestarDataPortalMeta.self, forKey: .meta)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(vin, forKey: .vin)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(longitude, forKey: .longitude)
        try container.encodeIfPresent(headingDegrees, forKey: .headingDegrees)
        try container.encodeIfPresent(altitudeMeters, forKey: .altitudeMeters)
        try container.encodeIfPresent(speedMetersPerSecond, forKey: .speedMetersPerSecond)
        try container.encodeIfPresent(accuracyMeters, forKey: .accuracyMeters)
        try container.encodeIfPresent(meta, forKey: .meta)
    }

    func toVehicleLocation() -> VehicleLocation {
        let speedKmh = speedMetersPerSecond.map { $0 * 3.6 }
        return VehicleLocation(
            latitude: latitude,
            longitude: longitude,
            heading: headingDegrees,
            speed: speedKmh,
            timestamp: timestamp?.date,
            altitudeMeters: altitudeMeters,
            accuracyMeters: accuracyMeters
        )
    }
}
