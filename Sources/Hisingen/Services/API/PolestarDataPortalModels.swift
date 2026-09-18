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
typealias PolestarDataPortalParkingClimatizationDTO = PolestarParkingClimatizationDTO
typealias PolestarDataPortalPreCleaningDTO = PolestarPreCleaningDTO
typealias PolestarDataPortalTargetSocDTO = PolestarTargetSocDTO
typealias PolestarDataPortalAmpLimitDTO = PolestarAmpLimitDTO
typealias PolestarDataPortalChargeLocationsDTO = PolestarChargeLocationsDTO
typealias PolestarDataPortalIsAtChargeLocationDTO = PolestarIsAtChargeLocationDTO
typealias PolestarDataPortalGlobalChargeTimerDTO = PolestarGlobalChargeTimerDTO
typealias PolestarDataPortalChargeNowDTO = PolestarChargeNowDTO
typealias PolestarDataPortalParkingClimateTimerDTO = PolestarParkingClimateTimerDTO

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

/// `OdometerState`. The portal reports the lifetime odometer in metres plus trip meters
/// in kilometres — there is no separate odometer-in-km field.
struct PolestarOdometerDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let odometerMeters: Double?
    let tripMeterManualKm: Double?
    let tripMeterAutomaticKm: Double?
    let tripMeterSinceChargeKm: Double?
    let averageSpeedKmPerHour: Double?
    let averageSpeedKmPerHourAutomatic: Double?
    let averageSpeedKmPerHourSinceCharge: Double?
    let metaReceivedAt: String?
    let metaEventId: String?

    var calculatedOdometerKm: Int? {
        odometerMeters.map { Int(($0 / 1000.0).rounded()) }
    }
}

// MARK: - Location Telemetry

/// `TelemetryCoordinate` — the lat/long pair shared by location and charge locations.
struct PolestarTelemetryCoordinateDTO: Codable, Sendable, Equatable {
    let latitude: Double?
    let longitude: Double?
}

/// `LocationState`. The coordinate is nested; altitude (metres) and speed (km/h) are
/// reported as decimal strings.
struct PolestarLocationDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let coordinate: PolestarTelemetryCoordinateDTO?
    /// Metres above sea level, wire format is a decimal string.
    let altitude: String?
    /// Kilometres per hour, wire format is a decimal string.
    let speed: String?
    /// Degrees from true north.
    let heading: Double?
    let metaReceivedAt: String?
    let metaEventId: String?

    var latitude: Double? { coordinate?.latitude }
    var longitude: Double? { coordinate?.longitude }

    func toVehicleLocation() -> VehicleLocation {
        VehicleLocation(
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            heading: heading,
            speed: speed.flatMap { Double($0) },
            timestamp: timestamp?.date,
            altitudeMeters: altitude.flatMap { Double($0) }
        )
    }
}

// MARK: - Parking Climatization Telemetry

/// `ParkingClimatizationState`. Status, ventilation and seat fields are string enums;
/// seat heating runs UNSPECIFIED/OFF/LOW/MEDIUM/HIGH.
struct PolestarParkingClimatizationDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let runningStatus: String?
    let mainClimateRunningStatus: String?
    /// Deprecated upstream in favour of the `startedAt`/`endingAt` window.
    let runtimeLeftMinutes: Double?
    let errors: [String]?
    let warnings: [String]?
    let ventilation: String?
    let currentCompartmentTemperatureCelsius: Double?
    let requestedCompartmentTemperatureCelsius: Double?
    let requestedFrontLeftSeat: String?
    let requestedFrontRightSeat: String?
    let requestedRearLeftSeat: String?
    let requestedRearRightSeat: String?
    let requestedSteeringWheelHeating: String?
    let startedAt: PolestarDataPortalTimestamp?
    let endingAt: PolestarDataPortalTimestamp?
    let startReason: String?
    let metaReceivedAt: String?
    let metaEventId: String?
}

// MARK: - Pre-Cleaning Telemetry

/// `PreCleaningState`. Measured air quality and PM2.5 are numbers; every cycle marker is
/// a `TelemetryTimestamp`.
struct PolestarPreCleaningDTO: Codable, Sendable, Equatable {
    let vin: String?
    let timestamp: PolestarDataPortalTimestamp?
    let lastCycleCompleted: PolestarDataPortalTimestamp?
    let measurementDate: PolestarDataPortalTimestamp?
    let startedAt: PolestarDataPortalTimestamp?
    let endingAt: PolestarDataPortalTimestamp?
    let runningStatus: String?
    let startReason: String?
    let lastCycleValid: Bool?
    let measuredAirQualityIndex: Double?
    let measuredParticulateMatter25: Double?
    let runtimeLeftMinutes: Double?
    let error: String?
    let metaReceivedAt: String?
    let metaEventId: String?
}

// MARK: - Charging Control DTOs

/// `TargetSocValue`.
struct PolestarTargetSocValueDTO: Codable, Sendable, Equatable {
    let batteryChargeTargetLevel: Double?
    let timestamp: PolestarDataPortalTimestamp?
    let chargeTargetLevelSettingType: String?
    let updatedAt: String?
    let source: String?
    let id: String?
}

/// `TargetSocState`.
struct PolestarTargetSocDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let updatedAt: String?
    let timestamp: PolestarDataPortalTimestamp?
    let targetSoc: PolestarTargetSocValueDTO?
    let pendingTargetSoc: PolestarTargetSocValueDTO?
    let metaReceivedAt: String?
    let metaEventId: String?

    /// Current charge target percentage, from `targetSoc.batteryChargeTargetLevel`.
    var targetSocPercentage: Int? {
        targetSoc?.batteryChargeTargetLevel.map { Int($0.rounded()) }
    }
}

/// `AmpLimitValue`.
struct PolestarAmpLimitValueDTO: Codable, Sendable, Equatable {
    let ampLimit: Double?
    let updatedAt: String?
    let updatedAtTimestamp: PolestarDataPortalTimestamp?
    let source: String?
    let id: String?
}

/// `AmpLimitState`. The spec carries a single amperage value per entry — no
/// minimum/maximum bounds.
struct PolestarAmpLimitDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let updatedAt: String?
    let updatedAtTimestamp: PolestarDataPortalTimestamp?
    /// Nested `AmpLimitState.ampLimit` per the spec.
    let syncedAmpLimit: PolestarAmpLimitValueDTO?
    let pendingAmpLimit: PolestarAmpLimitValueDTO?
    let metaReceivedAt: String?
    let metaEventId: String?

    /// Current amperage limit, from the nested `ampLimit.ampLimit` value.
    var ampLimit: Int? {
        syncedAmpLimit?.ampLimit.map { Int($0.rounded()) }
    }

    private enum CodingKeys: String, CodingKey {
        case vin, id, updatedAt, updatedAtTimestamp
        case syncedAmpLimit = "ampLimit"
        case pendingAmpLimit, metaReceivedAt, metaEventId
    }
}

/// `ChargeLocation`.
struct PolestarChargeLocationItemDTO: Codable, Sendable, Equatable {
    let locationId: String?
    let locationAlias: String?
    let coordinate: PolestarTelemetryCoordinateDTO?
    let ampLimit: Double?
    let minimumSoc: Double?
    let isOptimizedChargingEnabled: Bool?
    let isBidirectionalChargingEnabled: Bool?
    let availableOptimizedCharging: String?
    let locationType: String?
}

/// `ChargeLocationsState`.
struct PolestarChargeLocationsDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let chargeLocations: [PolestarChargeLocationItemDTO]?
    let pendingChargeLocations: [PolestarChargeLocationItemDTO]?
    /// True when the vehicle reports its timer times in UTC rather than local time.
    let utc0: Bool?
    let metaReceivedAt: String?
    let metaEventId: String?

    func toChargeLocations() -> [ChargeLocationSnapshot] {
        chargeLocations?.map { $0.toChargeLocationSnapshot() } ?? []
    }
}

/// `IsAtChargeLocationState`. The portal signals presence purely through `locationId` —
/// there is no boolean on the wire.
struct PolestarIsAtChargeLocationDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    /// The charge location the vehicle is currently at.
    let locationId: String?
    let arrivedAt: String?
    let arrivedAtTimestamp: PolestarDataPortalTimestamp?
    let metaReceivedAt: String?
    let metaEventId: String?

    var isAtChargeLocation: Bool { locationId != nil }
    /// Kept for snapshot assembly until it joins `locationId` against the
    /// charge-locations list; the state itself carries no name.
    var currentLocationName: String? { nil }
}

/// `DailyTime` — a wall-clock hour/minute pair shared by every timer shape.
struct PolestarDailyTimeDTO: Codable, Sendable, Equatable {
    let hour: Double?
    let minute: Double?

    var hourComponent: Int? { hour.map { Int($0.rounded()) } }
    var minuteComponent: Int? { minute.map { Int($0.rounded()) } }
}

/// `GlobalChargeTimerValue` — one daily charging window; the spec has no weekday list here.
struct PolestarGlobalChargeTimerValueDTO: Codable, Sendable, Equatable {
    let start: PolestarDailyTimeDTO?
    let stop: PolestarDailyTimeDTO?
    let activated: Bool?
}

/// `GlobalChargeTimerState` — a single synced window plus its pending counterpart.
struct PolestarGlobalChargeTimerDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let globalChargeTimer: PolestarGlobalChargeTimerValueDTO?
    let pendingGlobalChargeTimer: PolestarGlobalChargeTimerValueDTO?
    /// True when the vehicle reports its timer times in UTC rather than local time.
    let utc0: Bool?
    let metaReceivedAt: String?
    let metaEventId: String?

    func toSchedules() -> [VehicleSchedule] {
        guard let timer = globalChargeTimer else { return [] }
        return [VehicleSchedule(
            backendID: id,
            index: 0,
            kind: .globalCharging,
            startHour: timer.start?.hourComponent,
            startMinute: timer.start?.minuteComponent,
            endHour: timer.stop?.hourComponent,
            endMinute: timer.stop?.minuteComponent,
            isActive: timer.activated ?? false
        )]
    }
}

/// `OverrideChargeTimerValue` — the charge-now override switch with its sync bookkeeping.
struct PolestarOverrideChargeTimerValueDTO: Codable, Sendable, Equatable {
    /// True while the charge timer is overridden, i.e. charge now is on.
    let override: Bool?
    let updatedAt: String?
    let updatedAtTimestamp: PolestarDataPortalTimestamp?
}

/// `ChargeNowState`. The override-charge-timer resource shares this shape.
struct PolestarChargeNowDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let syncedOverrideChargeTimer: PolestarOverrideChargeTimerValueDTO?
    let pendingOverrideChargeTimer: PolestarOverrideChargeTimerValueDTO?
    let metaReceivedAt: String?
    let metaEventId: String?
}

/// `StartDate` — the first day a one-shot climate timer applies.
struct PolestarTimerStartDateDTO: Codable, Sendable, Equatable {
    let year: Double?
    let month: Double?
    let day: Double?
}

/// `ParkingClimateTimer`. `readyAt` is a `DailyTime`: the cabin must be ready by that
/// wall-clock time, and the vehicle back-computes its own start.
struct PolestarParkingClimateTimerItemDTO: Codable, Sendable, Equatable {
    let timerId: String?
    let index: Double?
    let readyAt: PolestarDailyTimeDTO?
    let activated: Bool?
    /// True when the timer repeats weekly on the listed weekdays.
    let repeats: Bool?
    let weekdays: [String]?
    let startDate: PolestarTimerStartDateDTO?

    private enum CodingKeys: String, CodingKey {
        case timerId, index, readyAt, activated
        case repeats = "repeat"
        case weekdays, startDate
    }

    func toVehicleSchedule(index fallbackIndex: Int = 0) -> VehicleSchedule {
        VehicleSchedule(
            backendID: timerId,
            index: index.map { Int($0.rounded()) } ?? fallbackIndex,
            kind: .climate,
            startHour: readyAt?.hourComponent,
            startMinute: readyAt?.minuteComponent,
            endHour: nil,
            endMinute: nil,
            weekdays: weekdays?.compactMap { parsePortalWeekday($0) } ?? [],
            isActive: activated ?? false
        )
    }
}

/// `ParkingClimateTimerState`.
struct PolestarParkingClimateTimerDTO: Codable, Sendable, Equatable {
    let vin: String?
    let id: String?
    let updatedAt: String?
    let updatedAtTimestamp: PolestarDataPortalTimestamp?
    let parkingClimateTimers: [PolestarParkingClimateTimerItemDTO]?
    let pendingParkingClimateTimers: [PolestarParkingClimateTimerItemDTO]?
    /// True when the vehicle reports its timer times in UTC rather than local time.
    let utc0: Bool?
    let metaReceivedAt: String?
    let metaEventId: String?

    func toClimateSchedules() -> [VehicleSchedule] {
        parkingClimateTimers?.enumerated().map { idx, timer in
            timer.toVehicleSchedule(index: idx)
        } ?? []
    }
}

// MARK: - Climatization, Pre-Cleaning & Charging Domain Mappers

extension PolestarParkingClimatizationDTO {
    /// HEATING_INTENSITY_OFF → 0 … HEATING_INTENSITY_HIGH → 3. UNSPECIFIED and absent both
    /// map to nil so "the car did not say" stays distinguishable from "off".
    private func seatHeatLevel(_ raw: String?) -> Int? {
        switch raw?.uppercased() {
        case "HEATING_INTENSITY_OFF": return 0
        case "HEATING_INTENSITY_LOW": return 1
        case "HEATING_INTENSITY_MEDIUM": return 2
        case "HEATING_INTENSITY_HIGH": return 3
        default: return nil
        }
    }

    func toVehicleClimateStatus(batteryPreconditioning: PolestarPreconditioningDTO? = nil) -> VehicleClimateStatus {
        let running = runningStatus == "RUNNING_STATUS_ON"
        // runtimeLeftMinutes is deprecated upstream; when absent, derive the remainder
        // from the session window instead.
        let remaining: Int? = {
            if let minutes = runtimeLeftMinutes { return Int(minutes.rounded()) }
            guard let ends = endingAt?.date else { return nil }
            let diff = ends.timeIntervalSinceNow
            return diff > 0 ? max(1, Int(diff / 60)) : 0
        }()
        return VehicleClimateStatus(
            activity: running ? .active : .idle,
            timeRemainingMinutes: remaining,
            timerTriggered: false,
            interiorTemperatureCelsius: currentCompartmentTemperatureCelsius,
            requestedTemperatureCelsius: requestedCompartmentTemperatureCelsius,
            driverSeatHeatingLevel: seatHeatLevel(requestedFrontLeftSeat),
            passengerSeatHeatingLevel: seatHeatLevel(requestedFrontRightSeat),
            steeringWheelHeatingLevel: seatHeatLevel(requestedSteeringWheelHeating),
            rearLeftSeatHeatingLevel: seatHeatLevel(requestedRearLeftSeat),
            rearRightSeatHeatingLevel: seatHeatLevel(requestedRearRightSeat),
            ventilation: ventilation,
            mainClimateRunningStatus: mainClimateRunningStatus,
            sessionStartedAt: startedAt?.date ?? batteryPreconditioning?.startedAt?.date,
            sessionEndsAt: endingAt?.date ?? batteryPreconditioning?.endingAt?.date
        )
    }
}

extension PolestarPreCleaningDTO {
    func toVehicleAirQuality() -> VehicleAirQuality {
        let state: AirCleaningState = {
            switch runningStatus {
            case "RUNNING_STATUS_ON": return .on
            case "RUNNING_STATUS_OFF": return .off
            case "RUNNING_STATUS_PENDING": return .pending
            default: return .unknown
            }
        }()
        return VehicleAirQuality(
            cleaningState: state,
            airQualityIndex: measuredAirQualityIndex.map { Int($0.rounded()) },
            particulateMatter25: measuredParticulateMatter25.map { Int($0.rounded()) },
            runtimeRemainingMinutes: runtimeLeftMinutes.map { Int($0.rounded()) },
            reportedAt: timestamp?.date,
            startedAt: startedAt?.date,
            endingAt: endingAt?.date,
            startReason: cleaningStartReason,
            lastCycleValid: lastCycleValid,
            errorKind: cleaningErrorKind,
            measuredAt: measurementDate?.date,
            lastCycleCompleted: lastCycleCompleted?.date
        )
    }

    /// Only reasons the domain type can represent are surfaced; TIMER and KEEP_CLIMATE
    /// have no `AirCleaningStartReason` case and stay nil.
    private var cleaningStartReason: AirCleaningStartReason? {
        switch startReason {
        case "START_REASON_REMOTE": return .remote
        case "START_REASON_MANUALLY_FROM_CAR": return .manuallyFromCar
        default: return nil
        }
    }

    /// `ERROR_TYPE_UNSPECIFIED` means "no value" and decodes to nil. A present
    /// NO_START_NEEDED is the explicit no-error signal (`.none`); INTERRUPTED is not a
    /// hardware fault; every remaining error kind falls back to `.generic`.
    /// `AirCleaningError` has a case literally named `none`, so a bare `return .none`
    /// here would resolve to `Optional.none` and silently drop the signal — spell the type.
    private var cleaningErrorKind: AirCleaningError? {
        switch error {
        case nil, "ERROR_TYPE_UNSPECIFIED": return nil
        case "ERROR_TYPE_NO_START_NEEDED": return AirCleaningError.none
        case "ERROR_TYPE_INTERRUPTED": return .interrupted
        default: return .generic
        }
    }
}

extension PolestarChargeLocationItemDTO {
    /// `availableOptimizedCharging` as the snapshot's mode code: 0 unavailable,
    /// 1 intelligent timer, 2 price-optimised.
    private var optimisedChargingMode: Int {
        switch availableOptimizedCharging {
        case "INTELLIGENT_TIMER": return 1
        case "PRICED_OPTIMIZED_CHARGING": return 2
        default: return 0
        }
    }

    /// `LOCATION_TYPE_*` as the snapshot kind: 1 recent, 2 saved, 3 saved third-party.
    /// Unspecified rows default to saved so they stay in the saved-locations bucket.
    private var locationKind: Int {
        switch locationType {
        case "LOCATION_TYPE_RECENT": return 1
        case "LOCATION_TYPE_SAVED_3RD_PARTY": return 3
        case "LOCATION_TYPE_SAVED": return 2
        default: return 2
        }
    }

    func toChargeLocationSnapshot() -> ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: locationId ?? UUID().uuidString,
            alias: locationAlias ?? "Charge Location",
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            ampLimit: ampLimit.map { Int($0.rounded()) } ?? 0,
            minimumSoc: minimumSoc.map { Int($0.rounded()) } ?? 0,
            optimisedChargingEnabled: isOptimizedChargingEnabled ?? false,
            optimisedChargingMode: optimisedChargingMode,
            kind: locationKind
        )
    }
}

private func parsePortalWeekday(_ raw: String) -> VehicleWeekday? {
    switch raw.uppercased() {
    case "MONDAY", "MON": return .monday
    case "TUESDAY", "TUE": return .tuesday
    case "WEDNESDAY", "WED": return .wednesday
    case "THURSDAY", "THU": return .thursday
    case "FRIDAY", "FRI": return .friday
    case "SATURDAY", "SAT": return .saturday
    case "SUNDAY", "SUN": return .sunday
    default: return nil
    }
}

extension VehicleWeekday {
    /// Portal wire encoding of a weekday, the inverse of `parsePortalWeekday`.
    var portalWeekdayName: String {
        switch self {
        case .monday: return "MONDAY"
        case .tuesday: return "TUESDAY"
        case .wednesday: return "WEDNESDAY"
        case .thursday: return "THURSDAY"
        case .friday: return "FRIDAY"
        case .saturday: return "SATURDAY"
        case .sunday: return "SUNDAY"
        }
    }
}

