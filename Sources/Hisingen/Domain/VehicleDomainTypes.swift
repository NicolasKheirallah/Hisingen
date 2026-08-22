import Foundation


enum VehicleWeekday: Int, Codable, CaseIterable, Sendable {
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
    case sunday = 7

    var shortName: String {
        switch self {
        case .monday: return L10n.text("Mon")
        case .tuesday: return L10n.text("Tue")
        case .wednesday: return L10n.text("Wed")
        case .thursday: return L10n.text("Thu")
        case .friday: return L10n.text("Fri")
        case .saturday: return L10n.text("Sat")
        case .sunday: return L10n.text("Sun")
        }
    }
}

enum ScheduleKind: String, Codable, Sendable {
    case globalCharging
    case locationCharging
    case departure
    case climate

    var title: String {
        switch self {
        case .globalCharging: return L10n.text("Charging Window")
        case .locationCharging: return L10n.text("Location Charge")
        case .departure: return L10n.text("Departure")
        case .climate: return L10n.text("Cabin Climate")
        }
    }
}

struct VehicleSchedule: Codable, Equatable, Sendable {
    let backendID: String?
    let index: Int?
    let kind: ScheduleKind
    let startHour: Int?
    let startMinute: Int?
    let endHour: Int?
    let endMinute: Int?
    let weekdays: [VehicleWeekday]
    let isActive: Bool
    var locationName: String?

    init(
        backendID: String? = nil,
        index: Int? = nil,
        kind: ScheduleKind,
        startHour: Int?,
        startMinute: Int?,
        endHour: Int?,
        endMinute: Int?,
        weekdays: [VehicleWeekday] = [],
        isActive: Bool,
        locationName: String? = nil
    ) {
        self.backendID = backendID
        self.index = index
        self.kind = kind
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.isActive = isActive
        self.locationName = locationName
    }

    private enum CodingKeys: String, CodingKey {
        case backendID, index, kind, startHour, startMinute, endHour, endMinute
        case weekdays, isActive, locationName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendID = try c.decodeIfPresent(String.self, forKey: .backendID)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        kind = try c.decode(ScheduleKind.self, forKey: .kind)
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour)
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute)
        endHour = try c.decodeIfPresent(Int.self, forKey: .endHour)
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute)
        weekdays = try c.decodeIfPresent([VehicleWeekday].self, forKey: .weekdays) ?? []
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
    }
}


enum VehicleOpening: String, Codable, CaseIterable, Sendable {
    case frontLeftDoor
    case frontRightDoor
    case rearLeftDoor
    case rearRightDoor
    case frontLeftWindow
    case frontRightWindow
    case rearLeftWindow
    case rearRightWindow
    case hood
    case tailgate
    case chargeLid
    case fuelFlap
    case sunroof

    var displayName: String {
        switch self {
        case .frontLeftDoor: return L10n.text("Front-left door")
        case .frontRightDoor: return L10n.text("Front-right door")
        case .rearLeftDoor: return L10n.text("Rear-left door")
        case .rearRightDoor: return L10n.text("Rear-right door")
        case .frontLeftWindow: return L10n.text("Front-left window")
        case .frontRightWindow: return L10n.text("Front-right window")
        case .rearLeftWindow: return L10n.text("Rear-left window")
        case .rearRightWindow: return L10n.text("Rear-right window")
        case .hood: return L10n.text("Hood")
        case .tailgate: return L10n.text("Tailgate")
        case .chargeLid: return L10n.text("Charge lid")
        case .fuelFlap: return L10n.text("Fuel flap")
        case .sunroof: return L10n.text("Sunroof")
        }
    }
}

enum OpeningState: Int, Codable, Sendable {
    case closed = 2
    case open = 1
    case ajar = 3
    case unknown = 0
}

struct OpeningReading: Codable, Equatable, Sendable {
    let opening: VehicleOpening
    let state: OpeningState
}

struct ExteriorSnapshot: Codable, Equatable, Sendable {
    var openings: [OpeningReading]
    var isLocked: Bool?
    var alarmTriggered: Bool?

    /// Whether the tailgate is currently open (or ajar).
    var isTailgateOpen: Bool {
        openings.first(where: { $0.opening == .tailgate })?.state == .open
            || openings.first(where: { $0.opening == .tailgate })?.state == .ajar
    }

    var itemsNeedingAttention: [VehicleOpening] {
        openings.filter { $0.state == .open || $0.state == .ajar }.map(\.opening)
    }

    var physicalDoorCount: Int {
        openings.reduce(into: 0) { count, reading in
            switch reading.opening {
            case .frontLeftDoor, .frontRightDoor, .rearLeftDoor, .rearRightDoor:
                count += 1
            default:
                break
            }
        }
    }

    func merging(previous: ExteriorSnapshot?) -> ExteriorSnapshot {
        guard let previous else { return self }
        var byOpening: [VehicleOpening: OpeningState] = [:]
        for reading in previous.openings { byOpening[reading.opening] = reading.state }
        for reading in openings { byOpening[reading.opening] = reading.state }
        let merged = byOpening.map { OpeningReading(opening: $0.key, state: $0.value) }
            .sorted { $0.opening.rawValue < $1.opening.rawValue }
        return ExteriorSnapshot(
            openings: merged,
            isLocked: isLocked ?? previous.isLocked,
            alarmTriggered: alarmTriggered ?? previous.alarmTriggered
        )
    }
}


enum TyrePosition: String, Codable, CaseIterable, Sendable {
    case frontLeft
    case frontRight
    case rearLeft
    case rearRight

    var displayName: String {
        switch self {
        case .frontLeft: return L10n.text("Front-left tyre")
        case .frontRight: return L10n.text("Front-right tyre")
        case .rearLeft: return L10n.text("Rear-left tyre")
        case .rearRight: return L10n.text("Rear-right tyre")
        }
    }
}

enum TyrePressureWarning: Int, Codable, Sendable {
    case unknown = 0
    case none = 1
    case veryLow = 2
    case low = 3
    case high = 4

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .none: return L10n.text("OK")
        case .veryLow: return L10n.text("Very low")
        case .low: return L10n.text("Low")
        case .high: return L10n.text("High")
        }
    }

    var needsAttention: Bool { self == .veryLow || self == .low || self == .high }
}

struct TyrePressure: Codable, Equatable, Sendable {
    let position: TyrePosition
    let kilopascals: Double?
    let warning: TyrePressureWarning
}

enum VehicleWarning: String, Codable, CaseIterable, Sendable {
    case service
    case brakeFluid
    case engineCoolant
    case oil
    case washerFluid
    case exteriorLight
    case lowVoltageBattery
    case tyrePressure

    var displayName: String {
        switch self {
        case .service: return L10n.text("Service warning")
        case .brakeFluid: return L10n.text("Brake fluid")
        case .engineCoolant: return L10n.text("Engine coolant")
        case .oil: return L10n.text("Oil")
        case .washerFluid: return L10n.text("Washer fluid")
        case .exteriorLight: return L10n.text("Exterior light")
        case .lowVoltageBattery: return L10n.text("12 V battery")
        case .tyrePressure: return L10n.text("Tyre pressure")
        }
    }
}

struct VehicleHealthDetails: Codable, Equatable, Sendable {
    let tyres: [TyrePressure]
    let warnings: [VehicleWarning]
    /// Warning categories for which the provider returned an explicit status. A category can
    /// be reported without being present in `warnings` (for example `NO_WARNING`). Keeping
    /// this separate prevents an absent response from being displayed as a healthy reading.
    var reportedWarnings: [VehicleWarning]
    var lightFailures: [String]

    init(
        tyres: [TyrePressure],
        warnings: [VehicleWarning],
        reportedWarnings: [VehicleWarning] = [],
        lightFailures: [String] = []
    ) {
        self.tyres = tyres
        self.warnings = warnings
        self.reportedWarnings = reportedWarnings
        self.lightFailures = lightFailures
    }

    private enum CodingKeys: String, CodingKey {
        case tyres, warnings, reportedWarnings, lightFailures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tyres = try c.decode([TyrePressure].self, forKey: .tyres)
        warnings = try c.decode([VehicleWarning].self, forKey: .warnings)
        reportedWarnings = try c.decodeIfPresent([VehicleWarning].self, forKey: .reportedWarnings) ?? []
        lightFailures = try c.decodeIfPresent([String].self, forKey: .lightFailures) ?? []
    }
}


enum SoftwareUpdateState: String, Codable, Sendable {
    case unknown
    case available
    case downloading
    case downloaded
    case installing
    case completed
    case failed
    case deferred
    case scheduled

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .available: return L10n.text("Available")
        case .downloading: return L10n.text("Downloading")
        case .downloaded: return L10n.text("Downloaded")
        case .installing: return L10n.text("Installing")
        case .completed: return L10n.text("Completed")
        case .failed: return L10n.text("Failed")
        case .deferred: return L10n.text("Deferred")
        case .scheduled: return L10n.text("Scheduled")
        }
    }
}
enum SoftwareStateRaw: Int, Codable, Sendable {
    case unknown = 0
    case downloadReady = 1
    case downloadStarted = 2
    case downloadCompleted = 3
    case downloadFailed = 4
    case installationInitiated = 5
    case installationStarted = 6
    case aborted = 7
    case failed = 8
    case installationCompleted = 9
    case installationDeferred = 10
    case failedCritical = 11
    case installationScheduled = 12
    case installationScheduleTriggered = 13
    case installationUnknown = 14
    case updateAvailable = 15

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .downloadReady: return L10n.text("Download authorized")
        case .downloadStarted: return L10n.text("Downloading")
        case .downloadCompleted: return L10n.text("Downloaded")
        case .downloadFailed: return L10n.text("Download failed")
        case .installationInitiated: return L10n.text("Installing")
        case .installationStarted: return L10n.text("Installing")
        case .aborted: return L10n.text("Aborted")
        case .failed: return L10n.text("Failed")
        case .installationCompleted: return L10n.text("Completed")
        case .installationDeferred: return L10n.text("Deferred")
        case .failedCritical: return L10n.text("Failed")
        case .installationScheduled: return L10n.text("Scheduled")
        case .installationScheduleTriggered: return L10n.text("Installing")
        case .installationUnknown: return L10n.text("Unknown")
        case .updateAvailable: return L10n.text("Update announced")
        }
    }

    /// Whether the `SchedulerService` will accept `Schedule`/`InstallNow` in this state.
    /// Verified live: states 3, 10, 12 are accepted; 15 is rejected with
    /// "The software with software id … is not ready to be scheduled!"
    /// Note: `downloadReady` (1) means "ready to download" — the vehicle hasn't downloaded
    /// the payload yet, so installation is NOT possible. Only `downloadCompleted` (3) and
    /// the deferred/scheduled states are installable.
    var isInstallable: Bool {
        switch self {
        case .downloadCompleted, .installationDeferred, .installationScheduled:
            return true
        default:
            return false
        }
    }

    /// Collapse into the coarser `SoftwareUpdateState` used by the UI.
    var coarseState: SoftwareUpdateState {
        switch self {
        case .unknown, .installationUnknown: return .unknown
        case .downloadReady, .updateAvailable: return .available
        case .downloadStarted: return .downloading
        case .downloadCompleted: return .downloaded
        case .downloadFailed: return .failed
        case .installationInitiated, .installationStarted, .installationScheduleTriggered:
            return .installing
        case .aborted, .failed, .failedCritical: return .failed
        case .installationCompleted: return .completed
        case .installationDeferred: return .deferred
        case .installationScheduled: return .scheduled
        }
    }
}

struct VehicleSoftwareInfo: Codable, Equatable, Sendable {
    let version: String?
    let title: String?
    let state: SoftwareUpdateState
    /// The precise backend enum value (0…15), preserving the distinction between
    /// `updateAvailable` (15) and `downloadReady` (1) that `state` collapses.
    var rawState: SoftwareStateRaw?
    /// Estimated installation duration in seconds, from `CarSoftwareInfo` field 5 sub-field 1
    /// (observed: 5400 = 90 min). `nil` when not reported.
    var estimatedInstallDurationSeconds: Int?
    var scheduledAt: Date?
    /// Who set the schedule (APP, HMI, CLOUD) — from `SchedulerService/GetSchedule` field 5.
    var scheduleSetBy: ScheduleSetBy?
    let updatedAt: Date?
    var installedVersion: String?
    var latestAvailableVersion: String?

    init(
        version: String? = nil,
        title: String? = nil,
        state: SoftwareUpdateState = .unknown,
        rawState: SoftwareStateRaw? = nil,
        estimatedInstallDurationSeconds: Int? = nil,
        scheduledAt: Date? = nil,
        scheduleSetBy: ScheduleSetBy? = nil,
        updatedAt: Date? = nil,
        installedVersion: String? = nil,
        latestAvailableVersion: String? = nil
    ) {
        self.version = version
        self.title = title
        self.state = state
        self.rawState = rawState
        self.estimatedInstallDurationSeconds = estimatedInstallDurationSeconds
        self.scheduledAt = scheduledAt
        self.scheduleSetBy = scheduleSetBy
        self.updatedAt = updatedAt
        self.installedVersion = installedVersion
        self.latestAvailableVersion = latestAvailableVersion
    }

    /// Failed OTA states are backend event records, not a durable vehicle fault. Only surface
    /// one as actionable while it identifies a different target version and is still recent.
    func hasActionableFailure(at date: Date = Date(), maximumAge: TimeInterval = 30 * 86_400) -> Bool {
        guard state == .failed,
              let target = latestAvailableVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              target != installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              let updatedAt else { return false }
        let age = date.timeIntervalSince(updatedAt)
        return age >= -300 && age <= maximumAge
    }

    /// Stable local identity for dismissing one backend event without suppressing a later one.
    var eventIdentifier: String {
        let eventTime = updatedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "no-date"
        return [String(rawState?.rawValue ?? -1), latestAvailableVersion ?? version ?? "no-version", eventTime]
            .joined(separator: "|")
    }
}


enum ClimateActivity: String, Codable, Sendable {
    case unknown
    case idle
    case active
    case starting
    case heating
    case cooling
    case ventilating

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .idle: return L10n.text("Idle")
        case .active: return L10n.text("Active")
        case .starting: return L10n.text("Starting")
        case .heating: return L10n.text("Heating")
        case .cooling: return L10n.text("Cooling")
        case .ventilating: return L10n.text("Ventilating")
        }
    }
}

struct VehicleClimateStatus: Codable, Equatable, Sendable {
    let activity: ClimateActivity
    let timeRemainingMinutes: Int?
    let timerTriggered: Bool
    let interiorTemperatureCelsius: Double?
    let requestedTemperatureCelsius: Double?
    let driverSeatHeatingLevel: Int?
    let passengerSeatHeatingLevel: Int?
    let steeringWheelHeatingLevel: Int?

    init(
        activity: ClimateActivity,
        timeRemainingMinutes: Int?,
        timerTriggered: Bool,
        interiorTemperatureCelsius: Double? = nil,
        requestedTemperatureCelsius: Double? = nil,
        driverSeatHeatingLevel: Int? = nil,
        passengerSeatHeatingLevel: Int? = nil,
        steeringWheelHeatingLevel: Int? = nil
    ) {
        self.activity = activity
        self.timeRemainingMinutes = timeRemainingMinutes
        self.timerTriggered = timerTriggered
        self.interiorTemperatureCelsius = interiorTemperatureCelsius
        self.requestedTemperatureCelsius = requestedTemperatureCelsius
        self.driverSeatHeatingLevel = driverSeatHeatingLevel
        self.passengerSeatHeatingLevel = passengerSeatHeatingLevel
        self.steeringWheelHeatingLevel = steeringWheelHeatingLevel
    }

    private enum CodingKeys: String, CodingKey {
        case activity, timeRemainingMinutes, timerTriggered
        case interiorTemperatureCelsius, requestedTemperatureCelsius
        case driverSeatHeatingLevel, passengerSeatHeatingLevel, steeringWheelHeatingLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activity = try c.decode(ClimateActivity.self, forKey: .activity)
        timeRemainingMinutes = try c.decodeIfPresent(Int.self, forKey: .timeRemainingMinutes)
        timerTriggered = try c.decodeIfPresent(Bool.self, forKey: .timerTriggered) ?? false
        interiorTemperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .interiorTemperatureCelsius)
        requestedTemperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .requestedTemperatureCelsius)
        driverSeatHeatingLevel = try c.decodeIfPresent(Int.self, forKey: .driverSeatHeatingLevel)
        passengerSeatHeatingLevel = try c.decodeIfPresent(Int.self, forKey: .passengerSeatHeatingLevel)
        steeringWheelHeatingLevel = try c.decodeIfPresent(Int.self, forKey: .steeringWheelHeatingLevel)
    }
}


enum ConnectivityState: String, Codable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case connected

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .unavailable: return L10n.text("Unavailable")
        case .disconnected: return L10n.text("Disconnected")
        case .connected: return L10n.text("Connected")
        }
    }
}

struct VehicleConnectivity: Codable, Equatable, Sendable {
    let state: ConnectivityState
    let networkType: String?
    let signalStrength: String?
    let updatedAt: Date?
    let signalBars: Int?
    let wakeReason: String?

    init(
        state: ConnectivityState,
        networkType: String? = nil,
        signalStrength: String? = nil,
        updatedAt: Date? = nil,
        signalBars: Int? = nil,
        wakeReason: String? = nil
    ) {
        self.state = state
        self.networkType = networkType
        self.signalStrength = signalStrength
        self.updatedAt = updatedAt
        self.signalBars = signalBars
        self.wakeReason = wakeReason
    }
}


enum AirCleaningState: String, Codable, Sendable {
    case unknown
    case on
    case off
    case pending

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .on: return L10n.text("Running")
        case .off: return L10n.text("Off")
        case .pending: return L10n.text("Pending")
        }
    }
}

struct VehicleAirQuality: Codable, Equatable, Sendable {
    let cleaningState: AirCleaningState
    let airQualityIndex: Int?
    let particulateMatter25: Int?
    let particulateMatter10: Int?
    let externalParticulateMatter25: Int?
    let filterRemainingPercent: Int?
    let runtimeRemainingMinutes: Int?
    let hasError: Bool

    init(
        cleaningState: AirCleaningState,
        airQualityIndex: Int? = nil,
        particulateMatter25: Int? = nil,
        particulateMatter10: Int? = nil,
        externalParticulateMatter25: Int? = nil,
        filterRemainingPercent: Int? = nil,
        runtimeRemainingMinutes: Int? = nil,
        hasError: Bool = false
    ) {
        self.cleaningState = cleaningState
        self.airQualityIndex = airQualityIndex
        self.particulateMatter25 = particulateMatter25
        self.particulateMatter10 = particulateMatter10
        self.externalParticulateMatter25 = externalParticulateMatter25
        self.filterRemainingPercent = filterRemainingPercent
        self.runtimeRemainingMinutes = runtimeRemainingMinutes
        self.hasError = hasError
    }
}


enum ChargerPowerState: String, Codable, Sendable {
    case unknown
    case noPower
    case initializing
    case available
    case providingPower
    case fault

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .noPower: return L10n.text("No power")
        case .initializing: return L10n.text("Initializing")
        case .available: return L10n.text("Available")
        case .providingPower: return L10n.text("Providing power")
        case .fault: return L10n.text("Fault")
        }
    }
}

struct BatteryDiagnostics: Codable, Equatable, Sendable {
    let timeToTargetMinutes: Int?
    let timeToMinimumSOCMinutes: Int?
    let chargerPowerState: ChargerPowerState
    let averageConsumption: Double?
    let averageConsumptionSinceCharge: Double?
    let energyUsedSinceChargeWh: Double?
}

struct VehicleWarrantyInfo: Codable, Equatable, Sendable {
    let planName: String?
    let status: String?
    let factoryWarrantyValidUntil: Date?
    let batteryWarrantyValidUntil: Date?
    let batteryWarrantyKm: Int?
    let roadsideAssistanceValidUntil: Date?
    let includedMaintenance: Bool?
    let corrosionWarrantyValidUntil: Date?
    let digitalServicesValidUntil: Date?
    let assistanceContact: String?

    init(
        planName: String? = nil,
        status: String? = nil,
        factoryWarrantyValidUntil: Date? = nil,
        batteryWarrantyValidUntil: Date? = nil,
        batteryWarrantyKm: Int? = nil,
        roadsideAssistanceValidUntil: Date? = nil,
        includedMaintenance: Bool? = nil,
        corrosionWarrantyValidUntil: Date? = nil,
        digitalServicesValidUntil: Date? = nil,
        assistanceContact: String? = nil
    ) {
        self.planName = planName
        self.status = status
        self.factoryWarrantyValidUntil = factoryWarrantyValidUntil
        self.batteryWarrantyValidUntil = batteryWarrantyValidUntil
        self.batteryWarrantyKm = batteryWarrantyKm
        self.roadsideAssistanceValidUntil = roadsideAssistanceValidUntil
        self.includedMaintenance = includedMaintenance
        self.corrosionWarrantyValidUntil = corrosionWarrantyValidUntil
        self.digitalServicesValidUntil = digitalServicesValidUntil
        self.assistanceContact = assistanceContact
    }
}


struct VehicleLocation: Codable, Equatable, Sendable {
    let latitude: Double?
    let longitude: Double?
    let heading: Double?
    let speed: Double?
    let timestamp: Date?
    let altitudeMeters: Double?
    let accuracyMeters: Double?
    let parkingBrakeEngaged: Bool?
    let gear: String?

    init(
        latitude: Double?,
        longitude: Double?,
        heading: Double? = nil,
        speed: Double? = nil,
        timestamp: Date? = nil,
        altitudeMeters: Double? = nil,
        accuracyMeters: Double? = nil,
        parkingBrakeEngaged: Bool? = nil,
        gear: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
        self.timestamp = timestamp
        self.altitudeMeters = altitudeMeters
        self.accuracyMeters = accuracyMeters
        self.parkingBrakeEngaged = parkingBrakeEngaged
        self.gear = gear
    }
}


struct VehicleWeather: Codable, Equatable, Sendable {
    let temperatureCelsius: Double?
    let condition: String?
    let apparentTemperatureCelsius: Double?
    let relativeHumidity: Int?
    let timestamp: Date?

    init(
        temperatureCelsius: Double?,
        condition: String? = nil,
        apparentTemperatureCelsius: Double? = nil,
        relativeHumidity: Int? = nil,
        timestamp: Date? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.condition = condition
        self.apparentTemperatureCelsius = apparentTemperatureCelsius
        self.relativeHumidity = relativeHumidity
        self.timestamp = timestamp
    }
}


struct ChargingSession: Codable, Equatable, Sendable {
    let id: UUID
    let vin: String
    let startDate: Date
    let endDate: Date
    let startBatteryPercentage: Double
    let endBatteryPercentage: Double
    let kwhDelivered: Double
    let peakPowerWatts: Int?
    let cost: Double?


    let targetPercentage: Int?


    let samples: [ChargingSample]

    init(
        id: UUID, vin: String, startDate: Date, endDate: Date,
        startBatteryPercentage: Double, endBatteryPercentage: Double,
        kwhDelivered: Double, peakPowerWatts: Int?, cost: Double?,
        targetPercentage: Int? = nil, samples: [ChargingSample] = []
    ) {
        self.id = id
        self.vin = vin
        self.startDate = startDate
        self.endDate = endDate
        self.startBatteryPercentage = startBatteryPercentage
        self.endBatteryPercentage = endBatteryPercentage
        self.kwhDelivered = kwhDelivered
        self.peakPowerWatts = peakPowerWatts
        self.cost = cost
        self.targetPercentage = targetPercentage
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case id, vin, startDate, endDate, startBatteryPercentage, endBatteryPercentage
        case kwhDelivered, peakPowerWatts, cost, targetPercentage, samples
    }


    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            vin: try c.decode(String.self, forKey: .vin),
            startDate: try c.decode(Date.self, forKey: .startDate),
            endDate: try c.decode(Date.self, forKey: .endDate),
            startBatteryPercentage: try c.decode(Double.self, forKey: .startBatteryPercentage),
            endBatteryPercentage: try c.decode(Double.self, forKey: .endBatteryPercentage),
            kwhDelivered: try c.decode(Double.self, forKey: .kwhDelivered),
            peakPowerWatts: try c.decodeIfPresent(Int.self, forKey: .peakPowerWatts),
            cost: try c.decodeIfPresent(Double.self, forKey: .cost),
            targetPercentage: try c.decodeIfPresent(Int.self, forKey: .targetPercentage),
            samples: try c.decodeIfPresent([ChargingSample].self, forKey: .samples) ?? []
        )
    }

    var durationMinutes: Int {
        Int(max(0, endDate.timeIntervalSince(startDate)) / 60)
    }

    var percentageAdded: Double {
        max(0, endBatteryPercentage - startBatteryPercentage)
    }

    func estimatedCost(tariff: Double? = nil) -> Double? {
        cost ?? tariff.map { $0 * kwhDelivered }
    }

    static func completed(
        previous: VehicleState?,
        current: VehicleState,
        pricePerKwh: Double
    ) -> ChargingSession? {
        guard let previous, previous.vin == current.vin,
              previous.isCharging, !current.isCharging,
              let first = previous.chargingSamples.first,
              let endBattery = current.batteryPercentage,
              endBattery > first.batteryPercentage else { return nil }
        let percentageAdded = endBattery - first.batteryPercentage
        let estimatedKwh = percentageAdded / 100 * current.configuredUsableBatteryCapacityKwh
        guard estimatedKwh > 0 else { return nil }
        return ChargingSession(
            id: UUID(),
            vin: current.vin,
            startDate: first.timestamp,
            endDate: current.fetchedAt,
            startBatteryPercentage: first.batteryPercentage,
            endBatteryPercentage: endBattery,
            kwhDelivered: estimatedKwh,
            peakPowerWatts: previous.chargingSamples.compactMap(\.powerWatts).max(),
            cost: pricePerKwh > 0 ? estimatedKwh * pricePerKwh : nil,
            targetPercentage: previous.chargeTargetPercentage ?? current.chargeTargetPercentage,
            samples: previous.chargingSamples
        )
    }
}


struct ChargingSample: Codable, Equatable, Sendable {
    let timestamp: Date
    let batteryPercentage: Double
    let powerWatts: Int?

    init(timestamp: Date = Date(), batteryPercentage: Double, powerWatts: Int? = nil) {
        self.timestamp = timestamp
        self.batteryPercentage = batteryPercentage
        self.powerWatts = powerWatts
    }
}

struct VehicleChronosError: Codable, Equatable, Sendable {
    /// Which Chronos service reported the error. Maps to the `ServiceErrorCase` oneof field
    /// numbers in `GetErrorsResponse`: 3=AmpLimit, 4=ChargeLocation, 5=ChargeNow,
    /// 6=GlobalChargeTimer, 7=ParkingClimateTimer, 8=TargetSoc.
    let service: Service
    /// The error code from the `Error` enum (field 1 of each sub-error message).
    let errorCode: Code
    /// Optional action code from the `Action` enum (field 2), when the sub-error has one
    /// (ChargeNow and ChargeLocation carry an action).
    let actionCode: Int?

    enum Service: Int, Codable, Sendable {
        case ampLimit = 3
        case chargeLocation = 4
        case chargeNow = 5
        case globalChargeTimer = 6
        case parkingClimateTimer = 7
        case targetSoc = 8

        var displayName: String {
            switch self {
            case .ampLimit: return L10n.text("Amp Limit")
            case .chargeLocation: return L10n.text("Charge Location")
            case .chargeNow: return L10n.text("Charge Now")
            case .globalChargeTimer: return L10n.text("Global Charge Timer")
            case .parkingClimateTimer: return L10n.text("Parking Climate Timer")
            case .targetSoc: return L10n.text("Target SOC")
            }
        }
    }

    /// `pccs.chronos.messages.error.v1.Error` enum: 0=UNSPECIFIED, 1=TIMEOUT, 2=CAR,
    /// 3=WRONG_USAGE_MODE, 4=PRIVACY_SETTINGS_ENABLED.
    enum Code: Int, Codable, Sendable {
        case unspecified = 0
        case timeout = 1
        case car = 2
        case wrongUsageMode = 3
        case privacySettingsEnabled = 4
        case unknown = -1

        var displayName: String {
            switch self {
            case .unspecified: return L10n.text("Unspecified error")
            case .timeout: return L10n.text("Request timed out")
            case .car: return L10n.text("Vehicle reported an error")
            case .wrongUsageMode: return L10n.text("Wrong usage mode")
            case .privacySettingsEnabled: return L10n.text("Privacy settings blocked the request")
            case .unknown: return L10n.text("Unknown error")
            }
        }
    }

    init(service: Service, errorCode: Code, actionCode: Int? = nil) {
        self.service = service
        self.errorCode = errorCode
        self.actionCode = actionCode
    }
}

struct VehicleOTACapabilities: Codable, Equatable, Sendable {
    /// The currently installed software version (e.g. "4.2.13"). This is the *authoritative*
    /// installed version from the `Car.consumerSoftwareVersion` field — `GetSoftwareInfo`
    /// does not report the installed version during a rollout, only the target.
    let installedSoftwareVersion: String?
    /// Whether the vehicle supports full OTA updates (not just minor patches).
    let supportsFullOtaUpdates: Bool
    /// Whether remote OTA install scheduling is supported (`Schedule`/`InstallNow`).
    let supportsRemoteOtaInstallSchedule: Bool
    /// Whether the vehicle supports cloud-based OTA download consent. When `false`, the
    /// download authorization cannot be triggered by a cloud API — the TCU must check in
    /// autonomously and the backend must have the VIN in the rollout cohort.
    let supportsCloudBasedOtaDownloadConsent: Bool
    /// Whether the vehicle reports update status via the `supportsUpdateStatus` flag.
    let supportsUpdateStatus: Bool
    /// Whether a performance software upgrade is available.
    let hasPerformanceSoftwareUpgrade: Bool
    /// Whether the vehicle supports trunk/tailgate open AND close (motorized tailgate).
    let supportsTrunkControl: Bool
    /// Whether the vehicle supports trunk unlock (unlock only, not open/close).
    let supportsTrunkUnlock: Bool
    /// Whether the vehicle supports honk and flash.
    let supportsHonkAndFlash: Bool
    /// Whether the vehicle supports flash only (without honk).
    let supportsFlash: Bool
    /// Whether the vehicle supports charging functions (target SOC, amp limit, timers).
    let supportsChargingFunctions: Bool
    /// Whether the vehicle supports global charge amperage limit setting.
    let supportsGlobalChargeAmperageLimit: Bool
    /// Whether the vehicle supports target charge level setting.
    let supportsTargetChargeLevel: Bool
    /// Whether the vehicle supports charge now timer override.
    let supportsChargeNowTimerOverride: Bool
    /// Minimum charge amperage limit.
    let chargeAmperageMinLimit: Int
    /// Maximum charge amperage limit.
    let chargeAmperageMaxLimit: Int
    /// Minimum target charge level percentage.
    let targetChargeLevelPercentageMinLimit: Int
    /// Whether the vehicle supports windows control.
    let supportsWindowsControl: Bool
    /// Whether the vehicle supports pre-cleaning.
    let supportsAirPurificationRemoteStart: Bool
    /// Whether the vehicle supports plug & charge.
    let supportsPlugAndCharge: Bool

    init(installedSoftwareVersion: String? = nil,
         supportsFullOtaUpdates: Bool = false,
         supportsRemoteOtaInstallSchedule: Bool = false,
         supportsCloudBasedOtaDownloadConsent: Bool = false,
         supportsUpdateStatus: Bool = false,
         hasPerformanceSoftwareUpgrade: Bool = false,
         supportsTrunkControl: Bool = false,
         supportsTrunkUnlock: Bool = false,
         supportsHonkAndFlash: Bool = false,
         supportsFlash: Bool = false,
         supportsChargingFunctions: Bool = false,
         supportsGlobalChargeAmperageLimit: Bool = false,
         supportsTargetChargeLevel: Bool = false,
         supportsChargeNowTimerOverride: Bool = false,
         chargeAmperageMinLimit: Int = 0,
         chargeAmperageMaxLimit: Int = 0,
         targetChargeLevelPercentageMinLimit: Int = 0,
         supportsWindowsControl: Bool = false,
         supportsAirPurificationRemoteStart: Bool = false,
         supportsPlugAndCharge: Bool = false) {
        self.installedSoftwareVersion = installedSoftwareVersion
        self.supportsFullOtaUpdates = supportsFullOtaUpdates
        self.supportsRemoteOtaInstallSchedule = supportsRemoteOtaInstallSchedule
        self.supportsCloudBasedOtaDownloadConsent = supportsCloudBasedOtaDownloadConsent
        self.supportsUpdateStatus = supportsUpdateStatus
        self.hasPerformanceSoftwareUpgrade = hasPerformanceSoftwareUpgrade
        self.supportsTrunkControl = supportsTrunkControl
        self.supportsTrunkUnlock = supportsTrunkUnlock
        self.supportsHonkAndFlash = supportsHonkAndFlash
        self.supportsFlash = supportsFlash
        self.supportsChargingFunctions = supportsChargingFunctions
        self.supportsGlobalChargeAmperageLimit = supportsGlobalChargeAmperageLimit
        self.supportsTargetChargeLevel = supportsTargetChargeLevel
        self.supportsChargeNowTimerOverride = supportsChargeNowTimerOverride
        self.chargeAmperageMinLimit = chargeAmperageMinLimit
        self.chargeAmperageMaxLimit = chargeAmperageMaxLimit
        self.targetChargeLevelPercentageMinLimit = targetChargeLevelPercentageMinLimit
        self.supportsWindowsControl = supportsWindowsControl
        self.supportsAirPurificationRemoteStart = supportsAirPurificationRemoteStart
        self.supportsPlugAndCharge = supportsPlugAndCharge
    }
}

/// Who set the OTA schedule, from the `SetBy` enum in `SchedulerService`.
enum ScheduleSetBy: Int, Codable, Sendable {
    case unknown = 0
    case app = 1
    case hmi = 2
    case cloud = 3

    var displayName: String {
        switch self {
        case .unknown: return L10n.text("Unknown")
        case .app: return L10n.text("App")
        case .hmi: return L10n.text("Car display")
        case .cloud: return L10n.text("Cloud")
        }
    }
}
