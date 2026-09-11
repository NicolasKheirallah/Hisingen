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
    func displayTitle(format: VehicleLabelFormat? = nil, preferences: PreferencesStore? = nil) -> String {
        // The store is created inside the isolated body: Swift 6 rejects actor-isolated
        // default-argument expressions, which are evaluated in the caller's context.
        let resolvedPreferences = preferences ?? PreferencesStore()
        return resolvedPreferences.formattedVehicleTitle(
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

/// Combustion and hybrid powertrain readings.
struct FuelSystemSnapshot: Codable, Equatable, Sendable {
    var levelPercent: Double?
    var rangeKm: Int?
    var amountLiters: Double?
    var averageConsumptionLPer100Km: Double?
    var isEngineRunning: Bool?
    /// Raw provider fuel-type string ("ELECTRIC", "DIESEL", …).
    var type: String?
}

/// OEM service and maintenance signals.
struct ServiceSnapshot: Codable, Equatable, Sendable {
    var daysToService: Int?
    var distanceToServiceKm: Int?
    var serviceWarning: Bool
    var fluidWarnings: [String]
    var engineHoursToService: Int?
    /// Raw provider service-trigger code (e.g. "TIME", "MILEAGE").
    var trigger: String?
    var preferredWorkshopID: String?
    var preferredWorkshopName: String?

    init(daysToService: Int? = nil, distanceToServiceKm: Int? = nil,
         serviceWarning: Bool = false, fluidWarnings: [String] = [],
         engineHoursToService: Int? = nil, trigger: String? = nil,
         preferredWorkshopID: String? = nil, preferredWorkshopName: String? = nil) {
        self.daysToService = daysToService
        self.distanceToServiceKm = distanceToServiceKm
        self.serviceWarning = serviceWarning
        self.fluidWarnings = fluidWarnings
        self.engineHoursToService = engineHoursToService
        self.trigger = trigger
        self.preferredWorkshopID = preferredWorkshopID
        self.preferredWorkshopName = preferredWorkshopName
    }
}

/// Trip-computer readings reported by the vehicle.
struct TripComputerSnapshot: Codable, Equatable, Sendable {
    var manualTripKm: Double?
    var automaticTripKm: Double?
    var averageSpeedKmH: Double?
    /// Average speed over the manual trip-meter period (`Odometer.average_speed_km_per_hour`,
    /// field 5), in km/h. Separate from the blended `averageSpeedKmH` so the two sources
    /// never overwrite each other. Defaults keep older persisted snapshots decodable.
    var manualAverageSpeedKmH: Int? = nil
    /// Average speed over the automatic trip-meter period
    /// (`Odometer.average_speed_km_per_hour_automatic`, field 6), in km/h.
    var automaticAverageSpeedKmH: Int? = nil
    var electricRangeKm: Int?
    var electricDistanceKm: Double?
    var fuelDistanceKm: Double?
    var regeneratedEnergyKwh: Double?
}

enum CommandConfirmationStatus: Codable, Equatable, Sendable {
    case awaiting
    case confirmed(at: Date)
    case timedOut(at: Date)

    var isAwaiting: Bool {
        if case .awaiting = self { return true }
        return false
    }

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    var isTerminal: Bool { !isAwaiting }
}

/// Display-only receipt for a remote command and its authoritative confirmation lifecycle.
/// Requested values remain optimistic until fresh vehicle telemetry moves `status` to
/// `confirmed`; the refresh coordinator owns the only timeout transition.
struct CommandReceipt: Codable, Equatable, Sendable {
    static let maximumConfirmationDuration: TimeInterval = 5 * 60
    static let confirmationTimestampTolerance: TimeInterval = 2
    static let maximumRetainedTerminalCount = 5

    var id: UUID
    /// Matches `RemoteCommand.identifier` and the command-audit trail.
    var commandIdentifier: String
    var issuedAt: Date
    var command: RemoteCommand? = nil
    var status: CommandConfirmationStatus = .awaiting

    init(
        id: UUID = UUID(),
        commandIdentifier: String,
        issuedAt: Date,
        command: RemoteCommand? = nil,
        status: CommandConfirmationStatus = .awaiting
    ) {
        self.id = id
        self.commandIdentifier = commandIdentifier
        self.issuedAt = issuedAt
        self.command = command
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, commandIdentifier, issuedAt, command, status, confirmedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        commandIdentifier = try values.decode(String.self, forKey: .commandIdentifier)
        issuedAt = try values.decode(Date.self, forKey: .issuedAt)
        command = try values.decodeIfPresent(RemoteCommand.self, forKey: .command)
        if let decoded = try values.decodeIfPresent(CommandConfirmationStatus.self, forKey: .status) {
            status = decoded
        } else if let confirmedAt = try values.decodeIfPresent(Date.self, forKey: .confirmedAt) {
            status = .confirmed(at: confirmedAt)
        } else {
            status = .awaiting
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(commandIdentifier, forKey: .commandIdentifier)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encodeIfPresent(command, forKey: .command)
        try values.encode(status, forKey: .status)
    }
}

struct EnergyAndChargingSnapshot: Codable, Equatable, Sendable {
    var batteryPercentage: Double?
    var rangeKm: Int?
    var chargingState: ChargingState
    var estimatedTimeToFullMinutes: Int?
    var estimatedTimeToTargetMinutes: Int?
    var targetPercentage: Int?
    var powerWatts: Int?
    var currentAmps: Int?
    var voltageVolts: Int?
    var type: ChargingType
    var connection: ChargerConnection
    var currentLimitAmps: Int?
    var reportedBatteryCapacityKwh: Double?
    var diagnostics: BatteryDiagnostics?
    var schedules: [VehicleSchedule]
    var locations: [ChargeLocationSnapshot]
    var samples: [ChargingSample]
    var sessions: [ChargingSession]

    init(
        batteryPercentage: Double? = nil,
        rangeKm: Int? = nil,
        chargingState: ChargingState = .idle,
        estimatedTimeToFullMinutes: Int? = nil,
        estimatedTimeToTargetMinutes: Int? = nil,
        targetPercentage: Int? = nil,
        powerWatts: Int? = nil,
        currentAmps: Int? = nil,
        voltageVolts: Int? = nil,
        type: ChargingType = .unknown,
        connection: ChargerConnection = .unknown,
        currentLimitAmps: Int? = nil,
        reportedBatteryCapacityKwh: Double? = nil,
        diagnostics: BatteryDiagnostics? = nil,
        schedules: [VehicleSchedule] = [],
        locations: [ChargeLocationSnapshot] = [],
        samples: [ChargingSample] = [],
        sessions: [ChargingSession] = []
    ) {
        self.batteryPercentage = batteryPercentage
        self.rangeKm = rangeKm
        self.chargingState = chargingState
        self.estimatedTimeToFullMinutes = estimatedTimeToFullMinutes
        self.estimatedTimeToTargetMinutes = estimatedTimeToTargetMinutes
        self.targetPercentage = targetPercentage
        self.powerWatts = powerWatts
        self.currentAmps = currentAmps
        self.voltageVolts = voltageVolts
        self.type = type
        self.connection = connection
        self.currentLimitAmps = currentLimitAmps
        self.reportedBatteryCapacityKwh = reportedBatteryCapacityKwh
        self.diagnostics = diagnostics
        self.schedules = schedules
        self.locations = locations
        self.samples = samples
        self.sessions = sessions
    }
}

struct VehicleIdentitySnapshot: Codable, Equatable, Sendable {
    var availability: VehicleAvailability
    var modelName: String?
    var modelYear: String?
    var registrationNo: String?
    var vin: String
    var ownerFirstName: String?
    var externalColour: String?
    var gearbox: String?
    var structureWeek: String?
    var internalVehicleIdentifier: String?
    var pno34: String?
    var accountMarket: String?
    var upholstery: String?
    var wheels: String?
    var packages: [String]
    var steeringOrientation: String?
    var imageData: Data?
    var interiorImageData: Data?

    init(
        availability: VehicleAvailability,
        modelName: String? = nil,
        modelYear: String? = nil,
        registrationNo: String? = nil,
        vin: String,
        ownerFirstName: String? = nil,
        externalColour: String? = nil,
        gearbox: String? = nil,
        structureWeek: String? = nil,
        internalVehicleIdentifier: String? = nil,
        pno34: String? = nil,
        accountMarket: String? = nil,
        upholstery: String? = nil,
        wheels: String? = nil,
        packages: [String] = [],
        steeringOrientation: String? = nil,
        imageData: Data? = nil,
        interiorImageData: Data? = nil
    ) {
        self.availability = availability
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
        self.vin = vin
        self.ownerFirstName = ownerFirstName
        self.externalColour = externalColour
        self.gearbox = gearbox
        self.structureWeek = structureWeek
        self.internalVehicleIdentifier = internalVehicleIdentifier
        self.pno34 = pno34
        self.accountMarket = accountMarket
        self.upholstery = upholstery
        self.wheels = wheels
        self.packages = packages
        self.steeringOrientation = steeringOrientation
        self.imageData = imageData
        self.interiorImageData = interiorImageData
    }
}

struct MaintenanceAndHealthSnapshot: Codable, Equatable, Sendable {
    var odometerKm: Int?
    var details: VehicleHealthDetails?
    var service: ServiceSnapshot
    var warranty: VehicleWarrantyInfo?
    var frontBrakePadStatus: String?
    var rearBrakePadStatus: String?

    init(
        odometerKm: Int? = nil,
        details: VehicleHealthDetails? = nil,
        service: ServiceSnapshot = .init(),
        warranty: VehicleWarrantyInfo? = nil,
        frontBrakePadStatus: String? = nil,
        rearBrakePadStatus: String? = nil
    ) {
        self.odometerKm = odometerKm
        self.details = details
        self.service = service
        self.warranty = warranty
        self.frontBrakePadStatus = frontBrakePadStatus
        self.rearBrakePadStatus = rearBrakePadStatus
    }
}

struct SnapshotFreshness: Codable, Equatable, Sendable {
    var isCached: Bool
    var fetchedAt: Date
    var vehicleReportedAt: Date?
    var readingDates: [VehicleReading: Date]
    var dataWarnings: [String]
    var unavailableFeatures: [AppFeature]
    var retainedDataCategories: [AppFeature]
    var retainedDataAt: Date?

    init(
        isCached: Bool = false,
        fetchedAt: Date,
        vehicleReportedAt: Date? = nil,
        readingDates: [VehicleReading: Date] = [:],
        dataWarnings: [String] = [],
        unavailableFeatures: [AppFeature] = [],
        retainedDataCategories: [AppFeature] = [],
        retainedDataAt: Date? = nil
    ) {
        self.isCached = isCached
        self.fetchedAt = fetchedAt
        self.vehicleReportedAt = vehicleReportedAt
        self.readingDates = readingDates
        self.dataWarnings = dataWarnings
        self.unavailableFeatures = unavailableFeatures
        self.retainedDataCategories = retainedDataCategories
        self.retainedDataAt = retainedDataAt
    }
}

struct CommandPresentationState: Codable, Equatable, Sendable {
    var optimisticLockUntil: Date?
    var receipts: [CommandReceipt]

    /// Compatibility view for call sites that only need the newest status.
    var receipt: CommandReceipt? {
        get { receipts.last }
        set {
            if let newValue {
                receipts = [newValue]
            } else {
                receipts = []
            }
        }
    }

    init(
        optimisticLockUntil: Date? = nil,
        receipts: [CommandReceipt] = [],
        receipt: CommandReceipt? = nil
    ) {
        self.optimisticLockUntil = optimisticLockUntil
        self.receipts = receipts.isEmpty ? receipt.map { [$0] } ?? [] : receipts
    }

    private enum CodingKeys: String, CodingKey {
        case optimisticLockUntil, receipts, receipt, pending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        optimisticLockUntil = try values.decodeIfPresent(Date.self, forKey: .optimisticLockUntil)
        if let decoded = try values.decodeIfPresent([CommandReceipt].self, forKey: .receipts) {
            receipts = decoded
        } else if let legacy = try values.decodeIfPresent(CommandReceipt.self, forKey: .receipt)
            ?? values.decodeIfPresent(CommandReceipt.self, forKey: .pending) {
            receipts = [legacy]
        } else {
            receipts = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(optimisticLockUntil, forKey: .optimisticLockUntil)
        if !receipts.isEmpty {
            try values.encode(receipts, forKey: .receipts)
        }
    }
}

struct VehicleState: Codable, Equatable, Sendable {
    var energy: EnergyAndChargingSnapshot
    var identity: VehicleIdentitySnapshot
    var maintenance: MaintenanceAndHealthSnapshot
    var freshness: SnapshotFreshness
    var commandState = CommandPresentationState()
    var exteriorStatus: ExteriorSnapshot? = nil
    var softwareInfo: VehicleSoftwareInfo? = nil
    var climateStatus: VehicleClimateStatus? = nil
    var climateTimers: [VehicleSchedule] = []
    var tripComputer = TripComputerSnapshot()
    var connectivity: VehicleConnectivity? = nil
    var airQuality: VehicleAirQuality? = nil
    var weather: VehicleWeather? = nil
    var location: VehicleLocation? = nil
    var probedCapabilities: VehicleProbedCapabilities? = nil



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

    /// Whether the backend explicitly reports the signed-in account as the vehicle's owner.
    /// Tri-state on purpose: `false` only when `GetMyCars` returned `userIsOwner == false`;
    /// `nil` (absent flag, Volvo, or pre-capability snapshot) means unknown and must never
    /// block a command.
    var accountOwnsVehicle: Bool? {
        otaCapabilities?.userIsOwner
    }

    /// Provider-reported pack specification. This is not a measured battery-health value.
    var vehicleErrors: [VehicleChronosError] = []
    var otaCapabilities: VehicleOTACapabilities? = nil

    private var batteryPercentage: Double? { get { energy.batteryPercentage } set { energy.batteryPercentage = newValue } }
    private var rangeKm: Int? { get { energy.rangeKm } set { energy.rangeKm = newValue } }
    private var chargingState: ChargingState { get { energy.chargingState } set { energy.chargingState = newValue } }
    private var estimatedChargingTimeToFullMinutes: Int? { get { energy.estimatedTimeToFullMinutes } set { energy.estimatedTimeToFullMinutes = newValue } }
    private var estimatedChargingTimeToTargetMinutes: Int? { get { energy.estimatedTimeToTargetMinutes } set { energy.estimatedTimeToTargetMinutes = newValue } }
    private var chargeTargetPercentage: Int? { get { energy.targetPercentage } set { energy.targetPercentage = newValue } }
    private var chargingPowerWatts: Int? { get { energy.powerWatts } set { energy.powerWatts = newValue } }
    private var chargingCurrentAmps: Int? { get { energy.currentAmps } set { energy.currentAmps = newValue } }
    private var chargingVoltageVolts: Int? { get { energy.voltageVolts } set { energy.voltageVolts = newValue } }
    private var chargingType: ChargingType { get { energy.type } set { energy.type = newValue } }
    private var chargerConnection: ChargerConnection { get { energy.connection } set { energy.connection = newValue } }
    private var chargingCurrentLimitAmps: Int? { get { energy.currentLimitAmps } set { energy.currentLimitAmps = newValue } }
    private var reportedBatteryCapacityKwh: Double? { get { energy.reportedBatteryCapacityKwh } set { energy.reportedBatteryCapacityKwh = newValue } }
    private var batteryDiagnostics: BatteryDiagnostics? { get { energy.diagnostics } set { energy.diagnostics = newValue } }
    private var chargingSchedules: [VehicleSchedule] { get { energy.schedules } set { energy.schedules = newValue } }
    private var chargeLocations: [ChargeLocationSnapshot] { get { energy.locations } set { energy.locations = newValue } }
    private var chargingSamples: [ChargingSample] { get { energy.samples } set { energy.samples = newValue } }
    private var chargingSessions: [ChargingSession] { get { energy.sessions } set { energy.sessions = newValue } }

    private var availability: VehicleAvailability { get { identity.availability } set { identity.availability = newValue } }
    private var modelName: String? { get { identity.modelName } set { identity.modelName = newValue } }
    private var modelYear: String? { get { identity.modelYear } set { identity.modelYear = newValue } }
    private var registrationNo: String? { get { identity.registrationNo } set { identity.registrationNo = newValue } }
    private var vin: String { get { identity.vin } set { identity.vin = newValue } }
    private var ownerFirstName: String? { get { identity.ownerFirstName } set { identity.ownerFirstName = newValue } }
    private var externalColour: String? { get { identity.externalColour } set { identity.externalColour = newValue } }
    private var gearbox: String? { get { identity.gearbox } set { identity.gearbox = newValue } }
    private var structureWeek: String? { get { identity.structureWeek } set { identity.structureWeek = newValue } }
    private var internalVehicleIdentifier: String? { get { identity.internalVehicleIdentifier } set { identity.internalVehicleIdentifier = newValue } }
    private var pno34: String? { get { identity.pno34 } set { identity.pno34 = newValue } }
    private var accountMarket: String? { get { identity.accountMarket } set { identity.accountMarket = newValue } }
    private var upholstery: String? { get { identity.upholstery } set { identity.upholstery = newValue } }
    private var wheels: String? { get { identity.wheels } set { identity.wheels = newValue } }
    private var packages: [String] { get { identity.packages } set { identity.packages = newValue } }
    private var steeringOrientation: String? { get { identity.steeringOrientation } set { identity.steeringOrientation = newValue } }
    private var imageData: Data? { get { identity.imageData } set { identity.imageData = newValue } }
    private var interiorImageData: Data? { get { identity.interiorImageData } set { identity.interiorImageData = newValue } }

    private var odometerKm: Int? { get { maintenance.odometerKm } set { maintenance.odometerKm = newValue } }
    private var healthDetails: VehicleHealthDetails? { get { maintenance.details } set { maintenance.details = newValue } }
    private var serviceInfo: ServiceSnapshot { get { maintenance.service } set { maintenance.service = newValue } }
    private var warrantyInfo: VehicleWarrantyInfo? { get { maintenance.warranty } set { maintenance.warranty = newValue } }
    private var frontBrakePadStatus: String? { get { maintenance.frontBrakePadStatus } set { maintenance.frontBrakePadStatus = newValue } }
    private var rearBrakePadStatus: String? { get { maintenance.rearBrakePadStatus } set { maintenance.rearBrakePadStatus = newValue } }

    private var isCachedSnapshot: Bool { get { freshness.isCached } set { freshness.isCached = newValue } }
    private var fetchedAt: Date { get { freshness.fetchedAt } set { freshness.fetchedAt = newValue } }
    private var vehicleReportedAt: Date? { get { freshness.vehicleReportedAt } set { freshness.vehicleReportedAt = newValue } }
    private var readingDates: [VehicleReading: Date] { get { freshness.readingDates } set { freshness.readingDates = newValue } }
    private var dataWarnings: [String] { get { freshness.dataWarnings } set { freshness.dataWarnings = newValue } }
    private var unavailableFeatures: [AppFeature] { get { freshness.unavailableFeatures } set { freshness.unavailableFeatures = newValue } }
    private var retainedDataCategories: [AppFeature] { get { freshness.retainedDataCategories } set { freshness.retainedDataCategories = newValue } }
    private var retainedDataAt: Date? { get { freshness.retainedDataAt } set { freshness.retainedDataAt = newValue } }

    private var optimisticCommandLockUntil: Date? { get { commandState.optimisticLockUntil } set { commandState.optimisticLockUntil = newValue } }
    var isAwaitingVehicleConfirmation: Bool {
        commandState.receipts.contains { $0.status.isAwaiting }
    }

    // Private forwarding keeps derived behavior compact without exposing a flat API.

    private var daysToService: Int? {
        get { serviceInfo.daysToService }
        set { serviceInfo.daysToService = newValue }
    }
    private var distanceToServiceKm: Int? {
        get { serviceInfo.distanceToServiceKm }
        set { serviceInfo.distanceToServiceKm = newValue }
    }
    private var serviceWarning: Bool {
        get { serviceInfo.serviceWarning }
        set { serviceInfo.serviceWarning = newValue }
    }
    private var fluidWarnings: [String] {
        get { serviceInfo.fluidWarnings }
        set { serviceInfo.fluidWarnings = newValue }
    }
    private var engineHoursToService: Int? {
        get { serviceInfo.engineHoursToService }
        set { serviceInfo.engineHoursToService = newValue }
    }
    private var serviceTrigger: String? {
        get { serviceInfo.trigger }
        set { serviceInfo.trigger = newValue }
    }
    private var preferredWorkshopId: String? {
        get { serviceInfo.preferredWorkshopID }
        set { serviceInfo.preferredWorkshopID = newValue }
    }
    private var preferredWorkshopName: String? {
        get { serviceInfo.preferredWorkshopName }
        set { serviceInfo.preferredWorkshopName = newValue }
    }

    private var tripMeterManualKm: Double? {
        get { tripComputer.manualTripKm }
        set { tripComputer.manualTripKm = newValue }
    }
    private var tripMeterAutomaticKm: Double? {
        get { tripComputer.automaticTripKm }
        set { tripComputer.automaticTripKm = newValue }
    }
    private var averageSpeedKmH: Double? {
        get { tripComputer.averageSpeedKmH }
        set { tripComputer.averageSpeedKmH = newValue }
    }
    private var tripManualAverageSpeedKmH: Int? {
        get { tripComputer.manualAverageSpeedKmH }
        set { tripComputer.manualAverageSpeedKmH = newValue }
    }
    private var tripAutomaticAverageSpeedKmH: Int? {
        get { tripComputer.automaticAverageSpeedKmH }
        set { tripComputer.automaticAverageSpeedKmH = newValue }
    }
    private var tripComputerElectricRangeKm: Int? {
        get { tripComputer.electricRangeKm }
        set { tripComputer.electricRangeKm = newValue }
    }
    private var electricDistanceKm: Double? {
        get { tripComputer.electricDistanceKm }
        set { tripComputer.electricDistanceKm = newValue }
    }
    private var fuelDistanceKm: Double? {
        get { tripComputer.fuelDistanceKm }
        set { tripComputer.fuelDistanceKm = newValue }
    }
    private var regeneratedEnergyKwh: Double? {
        get { tripComputer.regeneratedEnergyKwh }
        set { tripComputer.regeneratedEnergyKwh = newValue }
    }

    // MARK: Fuel/engine

    var powertrain: PowertrainType = .bev
    var fuelSystem: FuelSystemSnapshot = .init()

    private var fuelLevelPercent: Double? {
        get { fuelSystem.levelPercent }
        set { fuelSystem.levelPercent = newValue }
    }
    private var fuelRangeKm: Int? {
        get { fuelSystem.rangeKm }
        set { fuelSystem.rangeKm = newValue }
    }
    private var fuelAmountLiters: Double? {
        get { fuelSystem.amountLiters }
        set { fuelSystem.amountLiters = newValue }
    }
    private var averageFuelConsumptionLPer100Km: Double? {
        get { fuelSystem.averageConsumptionLPer100Km }
        set { fuelSystem.averageConsumptionLPer100Km = newValue }
    }
    private var isEngineRunning: Bool? {
        get { fuelSystem.isEngineRunning }
        set { fuelSystem.isEngineRunning = newValue }
    }
    private var fuelType: String? {
        get { fuelSystem.type }
        set { fuelSystem.type = newValue }
    }

    /// True when this state came from the on-disk snapshot rather than a live fetch.
    ///
    /// `cacheableCopy` drops most telemetry, so a cached state is not "the vehicle has no
    /// tyres data" — it is "we could not ask". Cards use this to show an unavailable badge
    /// instead of silently disappearing.

    mutating func applyLiveUpdate(_ update: VehicleLiveUpdate, receivedAt: Date = Date()) {
        switch update {
        case .connected:
            return
        case .battery(let battery):
            let reportedAt = battery.reportedAt
            var appliedReading = false
            if shouldApplyLiveReading(.battery, reportedAt: reportedAt) {
                if let value = battery.batteryPercentage {
                    batteryPercentage = value
                    if let reportedAt { readingDates[.battery] = reportedAt }
                }
                batteryDiagnostics = battery.diagnostics
                reportedBatteryCapacityKwh = battery.reportedBatteryCapacityKwh
                    ?? reportedBatteryCapacityKwh
                appliedReading = true
            }
            if let value = battery.rangeKm,
               shouldApplyLiveReading(.range, reportedAt: reportedAt) {
                rangeKm = value
                if let reportedAt { readingDates[.range] = reportedAt }
                appliedReading = true
            }
            let hasChargingReading = battery.estimatedChargingTimeToFullMinutes != nil
                || battery.chargingState != nil
                || battery.chargerConnection != .unknown
                || battery.chargingType != .unknown
                || battery.chargingPowerWatts != nil
                || battery.chargingCurrentAmps != nil
                || battery.chargingVoltageVolts != nil
            if hasChargingReading,
               shouldApplyLiveReading(.charging, reportedAt: reportedAt) {
                estimatedChargingTimeToFullMinutes = battery.estimatedChargingTimeToFullMinutes
                    ?? estimatedChargingTimeToFullMinutes
                chargingState = battery.chargingState ?? chargingState
                if battery.chargerConnection != .unknown {
                    chargerConnection = battery.chargerConnection
                }
                if battery.chargingType != .unknown {
                    chargingType = battery.chargingType
                }
                chargingPowerWatts = battery.chargingPowerWatts ?? chargingPowerWatts
                chargingCurrentAmps = battery.chargingCurrentAmps ?? chargingCurrentAmps
                chargingVoltageVolts = battery.chargingVoltageVolts ?? chargingVoltageVolts
                if let reportedAt { readingDates[.charging] = reportedAt }
                appliedReading = true
            }
            if appliedReading { advanceVehicleReportedAt(to: reportedAt) }
        case .exterior(let exterior, let reportedAt):
            let date = exterior.reportedAt ?? reportedAt
            let merged = exterior.merging(previous: exteriorStatus)
            var next = exteriorStatus ?? merged
            var appliedReading = false
            if shouldApplyLiveReading(.openings, reportedAt: date) {
                next.openings = merged.openings
                next.isTailgateLocked = merged.isTailgateLocked
                if let date { readingDates[.openings] = date }
                appliedReading = true
            }
            if (exterior.isLocked != nil || exterior.alarmTriggered != nil),
               shouldApplyLiveReading(.locks, reportedAt: date) {
                next.isLocked = merged.isLocked
                next.alarmTriggered = merged.alarmTriggered
                if let date { readingDates[.locks] = date }
                appliedReading = true
            }
            if appliedReading {
                if let date {
                    next.reportedAt = max(next.reportedAt ?? .distantPast, date)
                }
                exteriorStatus = next
                advanceVehicleReportedAt(to: date)
            }
        }
        fetchedAt = receivedAt
        isCachedSnapshot = false
    }

    private func shouldApplyLiveReading(_ reading: VehicleReading, reportedAt: Date?) -> Bool {
        guard let reportedAt, let current = readingDates[reading] else { return true }
        return reportedAt >= current
    }

    private mutating func advanceVehicleReportedAt(to reportedAt: Date?) {
        guard let reportedAt else { return }
        vehicleReportedAt = max(vehicleReportedAt ?? .distantPast, reportedAt)
    }

    init(
        energy: EnergyAndChargingSnapshot,
        identity: VehicleIdentitySnapshot,
        maintenance: MaintenanceAndHealthSnapshot = .init(),
        freshness: SnapshotFreshness,
        commandState: CommandPresentationState = .init(),
        exteriorStatus: ExteriorSnapshot? = nil,
        softwareInfo: VehicleSoftwareInfo? = nil,
        climateStatus: VehicleClimateStatus? = nil,
        climateTimers: [VehicleSchedule] = [],
        tripComputer: TripComputerSnapshot = .init(),
        connectivity: VehicleConnectivity? = nil,
        airQuality: VehicleAirQuality? = nil,
        weather: VehicleWeather? = nil,
        location: VehicleLocation? = nil,
        probedCapabilities: VehicleProbedCapabilities? = nil,
        powertrain: PowertrainType = .bev,
        fuelSystem: FuelSystemSnapshot = .init(),
        vehicleErrors: [VehicleChronosError] = [],
        otaCapabilities: VehicleOTACapabilities? = nil
    ) {
        self.energy = energy
        self.identity = identity
        self.maintenance = maintenance
        self.freshness = freshness
        self.commandState = commandState
        self.exteriorStatus = exteriorStatus
        self.softwareInfo = softwareInfo
        self.climateStatus = climateStatus
        self.climateTimers = climateTimers
        self.tripComputer = tripComputer
        self.connectivity = connectivity
        self.airQuality = airQuality
        self.weather = weather
        self.location = location
        self.probedCapabilities = probedCapabilities
        self.powertrain = powertrain
        self.fuelSystem = fuelSystem
        self.vehicleErrors = vehicleErrors
        self.otaCapabilities = otaCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case energy, identity, maintenance, freshness, commandState
        case readingDates
        case estimatedChargingTimeToTargetMinutes
        case batteryPercentage, rangeKm, chargingState, estimatedChargingTimeToFullMinutes
        case chargeTargetPercentage, chargingPowerWatts, chargingCurrentAmps, chargingVoltageVolts
        case chargingType, chargerConnection, availability, modelName, modelYear, registrationNo
        // serviceInfo/tripComputer are the current encodings; their flat member keys below
        // exist only for the decoder's legacy fallback.
        case vin, ownerFirstName, odometerKm, serviceInfo, tripComputer, pendingCommand
        case daysToService, distanceToServiceKm, serviceWarning, fluidWarnings
        case tripMeterManualKm, tripMeterAutomaticKm
        case exteriorStatus, healthDetails, softwareInfo, chargingSchedules
        case climateStatus, climateTimers, connectivity
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
        case isCachedSnapshot, retainedDataCategories, retainedDataAt, vehicleErrors, otaCapabilities
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func readFlat<T: Decodable>(_ key: String) throws -> T? {
            guard let key = CodingKeys(stringValue: key) else { return nil }
            return try values.decodeIfPresent(T.self, forKey: key)
        }

        let energy = try values.decodeIfPresent(EnergyAndChargingSnapshot.self, forKey: .energy)
            ?? EnergyAndChargingSnapshot(
                batteryPercentage: try readFlat("batteryPercentage"),
                rangeKm: try readFlat("rangeKm"),
                chargingState: try values.decode(ChargingState.self, forKey: .chargingState),
                estimatedTimeToFullMinutes: try readFlat("estimatedChargingTimeToFullMinutes"),
                estimatedTimeToTargetMinutes: try readFlat("estimatedChargingTimeToTargetMinutes"),
                targetPercentage: try readFlat("chargeTargetPercentage"),
                powerWatts: try readFlat("chargingPowerWatts"),
                currentAmps: try readFlat("chargingCurrentAmps"),
                voltageVolts: try readFlat("chargingVoltageVolts"),
                type: try values.decode(ChargingType.self, forKey: .chargingType),
                connection: try values.decode(ChargerConnection.self, forKey: .chargerConnection),
                currentLimitAmps: try readFlat("chargingCurrentLimitAmps"),
                reportedBatteryCapacityKwh: try readFlat("reportedBatteryCapacityKwh"),
                diagnostics: try readFlat("batteryDiagnostics"),
                schedules: try values.decodeIfPresent([VehicleSchedule].self, forKey: .chargingSchedules) ?? [],
                locations: try values.decodeIfPresent([ChargeLocationSnapshot].self, forKey: .chargeLocations) ?? [],
                samples: try values.decodeIfPresent([ChargingSample].self, forKey: .chargingSamples) ?? [],
                sessions: try values.decodeIfPresent([ChargingSession].self, forKey: .chargingSessions) ?? []
            )
        let identity = try values.decodeIfPresent(VehicleIdentitySnapshot.self, forKey: .identity)
            ?? VehicleIdentitySnapshot(
                availability: try values.decode(VehicleAvailability.self, forKey: .availability),
                modelName: try readFlat("modelName"),
                modelYear: try readFlat("modelYear"),
                registrationNo: try readFlat("registrationNo"),
                vin: try values.decode(String.self, forKey: .vin),
                ownerFirstName: try readFlat("ownerFirstName"),
                externalColour: try readFlat("externalColour"),
                gearbox: try readFlat("gearbox"),
                structureWeek: try readFlat("structureWeek"),
                internalVehicleIdentifier: try readFlat("internalVehicleIdentifier"),
                pno34: try readFlat("pno34"),
                accountMarket: try readFlat("accountMarket"),
                upholstery: try readFlat("upholstery"),
                wheels: try readFlat("wheels"),
                packages: try values.decodeIfPresent([String].self, forKey: .packages) ?? [],
                steeringOrientation: try readFlat("steeringOrientation"),
                imageData: try readFlat("imageData"),
                interiorImageData: try readFlat("interiorImageData")
            )
        let service = try values.decodeIfPresent(ServiceSnapshot.self, forKey: .serviceInfo)
            ?? ServiceSnapshot(
                daysToService: try readFlat("daysToService"),
                distanceToServiceKm: try readFlat("distanceToServiceKm"),
                serviceWarning: try values.decodeIfPresent(Bool.self, forKey: .serviceWarning) ?? false,
                fluidWarnings: try values.decodeIfPresent([String].self, forKey: .fluidWarnings) ?? [],
                engineHoursToService: try readFlat("engineHoursToService"),
                trigger: try readFlat("serviceTrigger"),
                preferredWorkshopID: try readFlat("preferredWorkshopId"),
                preferredWorkshopName: try readFlat("preferredWorkshopName")
            )
        let maintenance = try values.decodeIfPresent(MaintenanceAndHealthSnapshot.self, forKey: .maintenance)
            ?? MaintenanceAndHealthSnapshot(
                odometerKm: try readFlat("odometerKm"),
                details: try readFlat("healthDetails"),
                service: service,
                warranty: try readFlat("warrantyInfo"),
                frontBrakePadStatus: try readFlat("frontBrakePadStatus"),
                rearBrakePadStatus: try readFlat("rearBrakePadStatus")
            )
        let freshness = try values.decodeIfPresent(SnapshotFreshness.self, forKey: .freshness)
            ?? SnapshotFreshness(
                isCached: try values.decodeIfPresent(Bool.self, forKey: .isCachedSnapshot) ?? false,
                fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
                vehicleReportedAt: try readFlat("vehicleReportedAt"),
                readingDates: try values.decodeIfPresent([VehicleReading: Date].self, forKey: .readingDates) ?? [:],
                dataWarnings: try values.decode([String].self, forKey: .dataWarnings),
                unavailableFeatures: try values.decodeIfPresent([AppFeature].self, forKey: .unavailableFeatures) ?? [],
                retainedDataCategories: try values.decodeIfPresent([AppFeature].self, forKey: .retainedDataCategories) ?? [],
                retainedDataAt: try readFlat("retainedDataAt")
            )
        let tripComputer = try values.decodeIfPresent(TripComputerSnapshot.self, forKey: .tripComputer)
            ?? TripComputerSnapshot(
                manualTripKm: try readFlat("tripMeterManualKm"),
                automaticTripKm: try readFlat("tripMeterAutomaticKm"),
                averageSpeedKmH: try readFlat("averageSpeedKmH"),
                electricRangeKm: try readFlat("tripComputerElectricRangeKm"),
                electricDistanceKm: try readFlat("electricDistanceKm"),
                fuelDistanceKm: try readFlat("fuelDistanceKm"),
                regeneratedEnergyKwh: try readFlat("regeneratedEnergyKwh")
            )
        let fuelSystem = try values.decodeIfPresent(FuelSystemSnapshot.self, forKey: .fuelSystem)
            ?? FuelSystemSnapshot(
                levelPercent: try readFlat("fuelLevelPercent"),
                rangeKm: try readFlat("fuelRangeKm"),
                amountLiters: try readFlat("fuelAmountLiters"),
                averageConsumptionLPer100Km: try readFlat("averageFuelConsumptionLPer100Km"),
                isEngineRunning: try readFlat("isEngineRunning"),
                type: try readFlat("fuelType")
            )
        let commandState = try values.decodeIfPresent(CommandPresentationState.self, forKey: .commandState)
            ?? CommandPresentationState(receipt: try readFlat("pendingCommand"))

        self.init(
            energy: energy,
            identity: identity,
            maintenance: maintenance,
            freshness: freshness,
            commandState: commandState,
            exteriorStatus: try readFlat("exteriorStatus"),
            softwareInfo: try readFlat("softwareInfo"),
            climateStatus: try readFlat("climateStatus"),
            climateTimers: try values.decodeIfPresent([VehicleSchedule].self, forKey: .climateTimers) ?? [],
            tripComputer: tripComputer,
            connectivity: try readFlat("connectivity"),
            airQuality: try readFlat("airQuality"),
            weather: try readFlat("weather"),
            location: try readFlat("location"),
            probedCapabilities: try readFlat("probedCapabilities"),
            powertrain: try values.decodeIfPresent(PowertrainType.self, forKey: .powertrain) ?? .bev,
            fuelSystem: fuelSystem,
            vehicleErrors: try values.decodeIfPresent([VehicleChronosError].self, forKey: .vehicleErrors) ?? [],
            otaCapabilities: try readFlat("otaCapabilities")
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(energy, forKey: .energy)
        try values.encode(identity, forKey: .identity)
        try values.encode(maintenance, forKey: .maintenance)
        try values.encode(freshness, forKey: .freshness)
        try values.encode(commandState, forKey: .commandState)
        try values.encodeIfPresent(exteriorStatus, forKey: .exteriorStatus)
        try values.encodeIfPresent(softwareInfo, forKey: .softwareInfo)
        try values.encodeIfPresent(climateStatus, forKey: .climateStatus)
        try values.encode(climateTimers, forKey: .climateTimers)
        try values.encodeIfPresent(connectivity, forKey: .connectivity)
        try values.encodeIfPresent(airQuality, forKey: .airQuality)
        try values.encodeIfPresent(weather, forKey: .weather)
        try values.encodeIfPresent(location, forKey: .location)
        try values.encodeIfPresent(probedCapabilities, forKey: .probedCapabilities)
        try values.encode(powertrain, forKey: .powertrain)
        try values.encode(fuelSystem, forKey: .fuelSystem)
        try values.encode(tripComputer, forKey: .tripComputer)
        try values.encode(vehicleErrors, forKey: .vehicleErrors)
        try values.encodeIfPresent(otaCapabilities, forKey: .otaCapabilities)
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

    var batteryDegradationPercent: Double? {
        // Neither provider exposes a validated *measured* capacity or SoH value — this property
        // specifically represents that absence and must stay `nil` rather than infer one from
        // age, mileage, or a specification capacity. A separate, clearly-labeled *calculated*
        // estimate that does combine those signals exists at `BatteryHealthEstimator.estimate` —
        // it returns a distinct `BatteryHealthEstimate` type precisely so a calculated figure can
        // never be mistaken for what this property represents.
        return nil
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

    /// Derived label. Because neither provider exposes a measured SoH (see
    /// `batteryDegradationPercent`), this currently always reads "Unavailable" — it exists so
    /// a future verified source plugs into exactly one place.
    var batteryHealthStatus: String {
        guard powertrain.hasElectricRange, let deg = batteryDegradationPercent else {
            return L10n.text("Unavailable")
        }
        let soh = max(50.0, min(100.0, 100.0 - deg))
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
        VehicleCapabilityProfile(modelName: modelName, vin: vin, probed: probedCapabilities,
                                 advertised: otaCapabilities?.advertisedCapabilities ?? [:])
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
        guard isCharging, let minutes = remainingChargingMinutes, minutes > 0 else { return nil }
        guard !isStale() else { return nil }
        let completion = (reportedDate(for: .charging) ?? vehicleReportedAt ?? fetchedAt).addingTimeInterval(TimeInterval(minutes * 60))
        return completion > Date() ? completion : nil
    }

    var formattedCompletionTime: String? {
        guard let minutes = remainingChargingMinutes, minutes > 0, isCharging else { return nil }
        return Format.completionTime(from: minutes, baseDate: reportedDate(for: .charging) ?? vehicleReportedAt ?? fetchedAt)
    }

    func formattedChargingRate(unit: DistanceUnit) -> String? {
        guard let watts = chargingPowerWatts, watts > 0, isCharging else { return nil }


        guard let consumption = model.averageConsumptionWhPerKm else { return nil }
        return Format.chargingRateFormatted(powerWatts: watts, consumptionWhPerKm: consumption, unit: unit)
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
        var cachedEnergy = energy
        cachedEnergy.locations = []
        cachedEnergy.sessions = []

        var cachedIdentity = identity
        cachedIdentity.registrationNo = nil
        cachedIdentity.ownerFirstName = nil
        cachedIdentity.imageData = nil
        cachedIdentity.interiorImageData = nil

        var cachedFreshness = freshness
        cachedFreshness.unavailableFeatures = []
        cachedFreshness.readingDates[.location] = nil

        return VehicleState(
            energy: cachedEnergy,
            identity: cachedIdentity,
            maintenance: maintenance,
            freshness: cachedFreshness,
            exteriorStatus: exteriorStatus,
            softwareInfo: softwareInfo,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripComputer: tripComputer,
            connectivity: connectivity,
            airQuality: airQuality,
            weather: weather,
            probedCapabilities: probedCapabilities,
            powertrain: powertrain,
            fuelSystem: fuelSystem
        )
    }

    func mergingLastKnown(
        from previous: VehicleState?,
        features: FeatureSelection,
        refreshedFeatures: Set<AppFeature>? = nil,
        imageCache: CarImageCache = CarImageCache()
    ) -> VehicleState {
        guard let previous, previous.vin == vin else { return self }
        let failed = Set(unavailableFeatures)
        let refreshed = refreshedFeatures ?? AppFeature.permittedFeatures
        func wasRefreshed(_ feature: AppFeature) -> Bool {
            refreshed.contains(feature)
        }
        func keep(_ feature: AppFeature) -> Bool {
            features.contains(feature) && (!wasRefreshed(feature) || failed.contains(feature))
        }
        let mergedUnavailableFeatures = failed.union(
            previous.unavailableFeatures.filter { !wasRefreshed($0) }
        ).sorted { $0.title < $1.title }
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
        let connectivityIsUnsupported = probedCapabilities?.support(for: .connectivity) == .unavailable
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

        let mergedAirQuality: VehicleAirQuality? = {
            // During the command grace window a disagreeing reading is a stale cache, not a flip.
            if isCommandLocked, let previous = previous.airQuality {
                if let incoming = airQuality, incoming.cleaningState == previous.cleaningState {
                    return incoming
                }
                return previous
            }
            return airQuality ?? previous.airQuality
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
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: batteryPercentage ?? previous.batteryPercentage,
                rangeKm: rangeKm ?? previous.rangeKm,
                chargingState: previousChargingState ?? chargingState,
                estimatedTimeToFullMinutes: estimatedChargingTimeToFullMinutes
                    ?? previous.estimatedChargingTimeToFullMinutes,
                targetPercentage: mergedChargeTarget,
                powerWatts: chargingPowerWatts ?? previous.chargingPowerWatts,
                currentAmps: mergedCurrentAmps,
                voltageVolts: chargingVoltageVolts ?? previous.chargingVoltageVolts,
                type: chargingType == .unknown ? previous.chargingType : chargingType,
                connection: chargerConnection == .unknown ? previous.chargerConnection : chargerConnection,
                reportedBatteryCapacityKwh: reportedBatteryCapacityKwh ?? previous.reportedBatteryCapacityKwh,
                diagnostics: batteryDiagnostics
                    ?? (features.contains(.batteryDiagnostics) ? previous.batteryDiagnostics : nil),
                schedules: !chargingSchedules.isEmpty ? chargingSchedules
                    : (features.contains(.chargingSchedule) ? previous.chargingSchedules : [])
            ),
            identity: VehicleIdentitySnapshot(
                availability: mergedAvailability,
                modelName: modelName ?? (features.contains(.vehicleIdentity) ? previous.modelName : nil),
                modelYear: modelYear ?? (features.contains(.vehicleIdentity) ? previous.modelYear : nil),
                registrationNo: registrationNo ?? (features.contains(.vehicleIdentity) ? previous.registrationNo : nil),
                vin: vin,
                ownerFirstName: ownerFirstName ?? (features.contains(.ownerGreeting) ? previous.ownerFirstName : nil),
                imageData: imageData ?? (features.contains(.vehicleImage)
                    ? (previous.imageData ?? imageCache.image(for: vin)) : nil)
            ),
            maintenance: MaintenanceAndHealthSnapshot(
                odometerKm: odometerKm ?? (features.contains(.vehicleHealth) ? previous.odometerKm : nil),
                details: healthDetails ?? (features.contains(.tyreAndWarnings) ? previous.healthDetails : nil),
                service: ServiceSnapshot(
                    daysToService: daysToService ?? (features.contains(.vehicleHealth) ? previous.daysToService : nil),
                    distanceToServiceKm: distanceToServiceKm
                        ?? (features.contains(.vehicleHealth) ? previous.distanceToServiceKm : nil),
                    serviceWarning: !serviceWarning && keep(.vehicleHealth) ? previous.serviceWarning : serviceWarning,
                    fluidWarnings: fluidWarnings.isEmpty && keep(.vehicleHealth) ? previous.fluidWarnings : fluidWarnings
                )
            ),
            freshness: SnapshotFreshness(
                fetchedAt: fetchedAt,
                vehicleReportedAt: vehicleReportedAt ?? previous.vehicleReportedAt,
                dataWarnings: dataWarnings,
                unavailableFeatures: mergedUnavailableFeatures
            ),
            exteriorStatus: exteriorStatus ?? (features.contains(.exteriorStatus) ? previous.exteriorStatus : nil),
            softwareInfo: mergedSoftware,
            climateStatus: mergedClimate,
            climateTimers: !climateTimers.isEmpty ? climateTimers
                : (features.contains(.climateStatus) ? previous.climateTimers : []),
            tripComputer: TripComputerSnapshot(
                manualTripKm: tripMeterManualKm ?? (features.contains(.tripMeters) ? previous.tripMeterManualKm : nil),
                automaticTripKm: tripMeterAutomaticKm ?? (features.contains(.tripMeters) ? previous.tripMeterAutomaticKm : nil)
            ),
            connectivity: connectivity ?? (features.contains(.connectivityDiagnostics) && !connectivityIsUnsupported
                ? previous.connectivity : nil),
            airQuality: mergedAirQuality,
            weather: weather ?? (features.contains(.vehicleWeather) ? previous.weather : nil),
            location: location ?? (features.contains(.vehicleLocation) ? previous.location : nil),
            probedCapabilities: mergedProbes,
            powertrain: powertrain == .unknown ? previous.powertrain : powertrain,
            fuelSystem: FuelSystemSnapshot(
                levelPercent: fuelLevelPercent ?? previous.fuelLevelPercent,
                rangeKm: fuelRangeKm ?? previous.fuelRangeKm
            )
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
        merged.readingDates = readingDates
        merged.estimatedChargingTimeToTargetMinutes = estimatedChargingTimeToTargetMinutes
        if batteryPercentage == nil { merged.readingDates[.battery] = previous.reportedDate(for: .battery) }
        if rangeKm == nil { merged.readingDates[.range] = previous.reportedDate(for: .range) }
        if odometerKm == nil { merged.readingDates[.odometer] = previous.reportedDate(for: .odometer) }
        if healthDetails == nil { merged.readingDates[.health] = previous.reportedDate(for: .health) }
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
        merged.tripComputer.manualAverageSpeedKmH = tripComputer.manualAverageSpeedKmH
            ?? previous.tripComputer.manualAverageSpeedKmH
        merged.tripComputer.automaticAverageSpeedKmH = tripComputer.automaticAverageSpeedKmH
            ?? previous.tripComputer.automaticAverageSpeedKmH
        merged.frontBrakePadStatus = frontBrakePadStatus ?? previous.frontBrakePadStatus
        merged.rearBrakePadStatus = rearBrakePadStatus ?? previous.rearBrakePadStatus
        merged.preferredWorkshopId = preferredWorkshopId ?? previous.preferredWorkshopId
        merged.preferredWorkshopName = preferredWorkshopName ?? previous.preferredWorkshopName

        var retained = Set(previous.retainedDataCategories.filter { !wasRefreshed($0) })
        func markRetained(_ feature: AppFeature, currentIsMissing: Bool, previousWasPresent: Bool) {
            if features.contains(feature), wasRefreshed(feature), currentIsMissing, previousWasPresent {
                retained.insert(feature)
            }
        }
        markRetained(.exteriorStatus, currentIsMissing: exteriorStatus == nil, previousWasPresent: previous.exteriorStatus != nil)
        markRetained(.tyreAndWarnings, currentIsMissing: healthDetails == nil, previousWasPresent: previous.healthDetails != nil)
        markRetained(.softwareUpdates, currentIsMissing: softwareInfo == nil, previousWasPresent: previous.softwareInfo != nil)
        markRetained(.climateStatus, currentIsMissing: climateStatus == nil, previousWasPresent: previous.climateStatus != nil)
        markRetained(.tripMeters, currentIsMissing: tripMeterManualKm == nil && tripMeterAutomaticKm == nil,
                     previousWasPresent: previous.tripMeterManualKm != nil || previous.tripMeterAutomaticKm != nil)
        if !connectivityIsUnsupported {
            markRetained(.connectivityDiagnostics, currentIsMissing: connectivity == nil,
                         previousWasPresent: previous.connectivity != nil)
        }
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
