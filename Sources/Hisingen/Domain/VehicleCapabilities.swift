import Foundation

typealias VehicleModel = VehicleModelFamily

enum VehicleModelFamily: Codable, Hashable, Sendable {
    case polestar1
    case polestar2
    case polestar3
    case polestar4
    case polestar5
    case polestar6
    case volvoXC40
    case volvoEX40
    case volvoC40
    case volvoEC40
    case volvoXC60
    case volvoXC90
    case volvoS60
    case volvoS90
    case volvoV60
    case volvoV90
    case volvoEX30
    case volvoEX90
    case volvoES90
    case volvoUnknown(String?)
    case unknown(String?)

    init(modelName: String?, vin: String? = nil) {
        if let vin = vin?.uppercased(), vin.count >= 4 {
            let chars = Array(vin)
            if vin.hasPrefix("YSM") {
                switch chars[3] {
                case "V", "E", "S", "2": self = .polestar2; return
                case "B", "3": self = .polestar3; return
                case "A", "C", "4": self = .polestar4; return
                case "5": self = .polestar5; return
                case "6": self = .polestar6; return
                default: break
                }
            }
        }

        let normalized = (modelName ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        if let volvo = Self.volvoModel(from: normalized) {
            self = volvo
            return
        }

        if normalized.contains("polestar 2") || normalized.contains("ps2") || normalized.contains(" 2") || normalized.contains("two") {
            self = .polestar2
            return
        }
        if normalized.contains("polestar 3") || normalized.contains("ps3") || normalized.contains(" 3") || normalized.contains("three") {
            self = .polestar3
            return
        }
        if normalized.contains("polestar 4") || normalized.contains("ps4") || normalized.contains(" 4") || normalized.contains("four") {
            self = .polestar4
            return
        }
        if normalized.contains("polestar 1") || normalized.contains("ps1") || normalized.contains(" 1") || normalized.contains("one") {
            self = .polestar1
            return
        }
        if normalized.contains("polestar 5") || normalized.contains("ps5") || normalized.contains(" 5") || normalized.contains("five") {
            self = .polestar5
            return
        }
        if normalized.contains("polestar 6") || normalized.contains("ps6") || normalized.contains(" 6") || normalized.contains("six") {
            self = .polestar6
            return
        }

        let compact = normalized.filter(\.isLetter).replacingOccurrences(of: "polestar", with: "")
        let number = normalized.first(where: \.isNumber).flatMap { Int(String($0)) }
        switch number {
        case 1: self = .polestar1
        case 2: self = .polestar2
        case 3: self = .polestar3
        case 4: self = .polestar4
        case 5: self = .polestar5
        case 6: self = .polestar6
        default:
            switch compact {
            case "one": self = .polestar1
            case "two": self = .polestar2
            case "three": self = .polestar3
            case "four": self = .polestar4
            case "five": self = .polestar5
            case "six": self = .polestar6
            default:
                if let vin = vin?.uppercased(), (vin.hasPrefix("YV1") || vin.hasPrefix("YV4") || vin.hasPrefix("LVY")) {
                    self = .volvoUnknown(modelName)
                } else {
                    self = .unknown(modelName)
                }
            }
        }
    }

    private static func volvoModel(from normalized: String) -> VehicleModelFamily? {
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        if compact.contains("ex30") { return .volvoEX30 }
        if compact.contains("ex90") { return .volvoEX90 }
        if compact.contains("es90") { return .volvoES90 }
        if compact.contains("ex40") { return .volvoEX40 }
        if compact.contains("ec40") { return .volvoEC40 }
        if compact.contains("xc40") { return .volvoXC40 }
        if compact.contains("c40") { return .volvoC40 }
        if compact.contains("xc60") { return .volvoXC60 }
        if compact.contains("xc90") { return .volvoXC90 }
        if compact.contains("s60") { return .volvoS60 }
        if compact.contains("s90") { return .volvoS90 }
        if compact.contains("v60") { return .volvoV60 }
        if compact.contains("v90") { return .volvoV90 }
        return nil
    }

    var displayName: String {
        switch self {
        case .polestar1: return "Polestar 1"
        case .polestar2: return "Polestar 2"
        case .polestar3: return "Polestar 3"
        case .polestar4: return "Polestar 4"
        case .polestar5: return "Polestar 5"
        case .polestar6: return "Polestar 6"
        case .volvoXC40: return "Volvo XC40"
        case .volvoEX40: return "Volvo EX40"
        case .volvoC40: return "Volvo C40"
        case .volvoEC40: return "Volvo EC40"
        case .volvoXC60: return "Volvo XC60"
        case .volvoXC90: return "Volvo XC90"
        case .volvoS60: return "Volvo S60"
        case .volvoS90: return "Volvo S90"
        case .volvoV60: return "Volvo V60"
        case .volvoV90: return "Volvo V90"
        case .volvoEX30: return "Volvo EX30"
        case .volvoEX90: return "Volvo EX90"
        case .volvoES90: return "Volvo ES90"
        case .volvoUnknown(let name):
            return name?.isEmpty == false ? name! : L10n.text("Unknown Volvo model")
        case .unknown(let name):
            return name?.isEmpty == false ? name! : L10n.text("Unknown model")
        }
    }

    var isKnown: Bool {
        switch self {
        case .unknown, .volvoUnknown: return false
        default: return true
        }
    }

    var brand: VehicleBrand {
        switch self {
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40, .volvoXC60, .volvoXC90,
             .volvoS60, .volvoS90, .volvoV60, .volvoV90, .volvoEX30, .volvoEX90, .volvoES90, .volvoUnknown:
            return .volvo
        case .polestar1, .polestar2, .polestar3, .polestar4, .polestar5, .polestar6, .unknown:
            return .polestar
        }
    }

    /// Static model-family reference values are available. This does not mean the exact VIN,
    /// battery, wheel, market or model-year variant has been verified — it means the capacity/
    /// WLTP tables below have a non-zero entry for this model family. Volvo BEVs (XC40/EX40/C40/
    /// EC40/EX30/EX90/ES90) do; Volvo ICE/PHEV/unrecognized models don't, so this is model-driven
    /// rather than brand-driven — a Polestar-only check would hide those Volvo models' own
    /// reference numbers even though the same table already carries them.
    var hasModelReferenceSpecs: Bool { nominalWltpRangeKm > 0 && nominalUsableCapacityKwh > 0 }

    /// Base per-model-family capacity table. This is the single source of truth for battery
    /// capacity — `VehicleState.factoryNominalBatteryCapacityKwh`/`factoryUsableBatteryCapacityKwh`
    /// read these values and layer year/powertrain-specific overrides on top (a 2024+ Polestar 2
    /// or Volvo XC40-family pack revision, or a PHEV's year-dependent pack), rather than
    /// maintaining a second independent table. `VehicleState.batteryPackDescription`'s prose
    /// strings interpolate those same computed values instead of hardcoding their own numbers,
    /// for the same reason: one place to update if a figure changes.
    var nominalBatteryCapacityKwh: Double {
        switch self {
        case .polestar1: return 34.0
        case .polestar2: return 78.0
        case .polestar3: return 111.0
        case .polestar4: return 102.0
        case .polestar5: return 103.0
        case .polestar6: return 103.0
        case .unknown: return 78.0
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40:
            return 78.0
        case .volvoEX30:
            return 69.0
        case .volvoEX90, .volvoES90:
            return 111.0
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90, .volvoUnknown:
            return 0
        }
    }

    var nominalUsableCapacityKwh: Double {
        switch self {
        case .polestar1: return 30.0
        case .polestar2: return 75.0
        case .polestar3: return 107.0
        case .polestar4: return 94.0
        case .polestar5: return 96.0
        case .polestar6: return 96.0
        case .unknown: return 75.0
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40:
            return 75.0
        case .volvoEX30:
            return 64.0
        case .volvoEX90, .volvoES90:
            return 107.0
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90, .volvoUnknown:
            return 0
        }
    }

    var nominalWltpRangeKm: Double {
        switch self {
        case .polestar1: return 150.0
        case .polestar2: return 480.0
        case .polestar3: return 610.0
        case .polestar4: return 610.0
        case .polestar5: return 670.0
        case .polestar6: return 670.0
        case .unknown: return 480.0
        case .volvoXC40, .volvoEX40: return 570.0
        case .volvoC40, .volvoEC40: return 580.0
        case .volvoEX30: return 476.0
        case .volvoEX90: return 600.0
        case .volvoES90: return 600.0
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90, .volvoUnknown:
            return 0
        }
    }

    var averageConsumptionWhPerKm: Double? {
        guard hasModelReferenceSpecs, nominalWltpRangeKm > 0 else { return nil }
        return (nominalUsableCapacityKwh * 1_000) / nominalWltpRangeKm
    }

    private enum CodingKeys: String, CodingKey { case kind, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "polestar1": self = .polestar1
        case "polestar2": self = .polestar2
        case "polestar3": self = .polestar3
        case "polestar4": self = .polestar4
        case "polestar5": self = .polestar5
        case "polestar6": self = .polestar6
        case "volvoXC40": self = .volvoXC40
        case "volvoEX40": self = .volvoEX40
        case "volvoC40": self = .volvoC40
        case "volvoEC40": self = .volvoEC40
        case "volvoXC60": self = .volvoXC60
        case "volvoXC90": self = .volvoXC90
        case "volvoS60": self = .volvoS60
        case "volvoS90": self = .volvoS90
        case "volvoV60": self = .volvoV60
        case "volvoV90": self = .volvoV90
        case "volvoEX30": self = .volvoEX30
        case "volvoEX90": self = .volvoEX90
        case "volvoES90": self = .volvoES90
        case "volvoUnknown": self = .volvoUnknown(try c.decodeIfPresent(String.self, forKey: .name))
        case "unknown": self = .unknown(try c.decodeIfPresent(String.self, forKey: .name))
        default: self = .unknown(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .polestar1: try c.encode("polestar1", forKey: .kind)
        case .polestar2: try c.encode("polestar2", forKey: .kind)
        case .polestar3: try c.encode("polestar3", forKey: .kind)
        case .polestar4: try c.encode("polestar4", forKey: .kind)
        case .polestar5: try c.encode("polestar5", forKey: .kind)
        case .polestar6: try c.encode("polestar6", forKey: .kind)
        case .volvoXC40: try c.encode("volvoXC40", forKey: .kind)
        case .volvoEX40: try c.encode("volvoEX40", forKey: .kind)
        case .volvoC40: try c.encode("volvoC40", forKey: .kind)
        case .volvoEC40: try c.encode("volvoEC40", forKey: .kind)
        case .volvoXC60: try c.encode("volvoXC60", forKey: .kind)
        case .volvoXC90: try c.encode("volvoXC90", forKey: .kind)
        case .volvoS60: try c.encode("volvoS60", forKey: .kind)
        case .volvoS90: try c.encode("volvoS90", forKey: .kind)
        case .volvoV60: try c.encode("volvoV60", forKey: .kind)
        case .volvoV90: try c.encode("volvoV90", forKey: .kind)
        case .volvoEX30: try c.encode("volvoEX30", forKey: .kind)
        case .volvoEX90: try c.encode("volvoEX90", forKey: .kind)
        case .volvoES90: try c.encode("volvoES90", forKey: .kind)
        case .volvoUnknown(let name):
            try c.encode("volvoUnknown", forKey: .kind)
            try c.encodeIfPresent(name, forKey: .name)
        case .unknown(let name):
            try c.encode("unknown", forKey: .kind)
            try c.encodeIfPresent(name, forKey: .name)
        }
    }
}

enum VehicleCapabilitySupport: String, Codable, Sendable {
    case supported
    case vehicleManaged
    case unavailable
    case backendDependent

    var permitsRequest: Bool { self != .unavailable }

    var displayName: String {
        switch self {
        case .supported: return L10n.text("Supported")
        case .vehicleManaged: return L10n.text("Automatic")
        case .unavailable: return L10n.text("Not available")
        case .backendDependent: return L10n.text("Depends on vehicle service")
        }
    }

    var symbolName: String {
        switch self {
        case .supported: return "checkmark.circle.fill"
        case .vehicleManaged: return "gearshape.fill"
        case .unavailable: return "minus.circle"
        case .backendDependent: return "questionmark.circle"
        }
    }
}

enum FeatureAvailability: String, Codable, Sendable {
    case available
    case vehicleOffline
    case temporarilyUnavailable
    case authenticationRequired
    case unknown

    var displayName: String {
        switch self {
        case .available: return L10n.text("Available")
        case .vehicleOffline: return L10n.text("Vehicle offline")
        case .temporarilyUnavailable: return L10n.text("Temporarily unavailable")
        case .authenticationRequired: return L10n.text("Sign in required")
        case .unknown: return L10n.text("Unknown")
        }
    }

    var isActionable: Bool { self == .available }
}

struct VehicleFeatureStatus: Equatable, Sendable {
    let support: VehicleCapabilitySupport
    let availability: FeatureAvailability

    var isVisible: Bool { support.permitsRequest }
    var isUsable: Bool { support.permitsRequest && availability.isActionable }
}

enum VehicleCapability: String, Codable, CaseIterable, Sendable {
    case climateStartStop
    case climateTemperature
    case seatHeating
    case steeringWheelHeating
    case climateTimers
    case preCleaning
    case chargeTarget
    case chargingCurrentLimit
    case chargingSchedule
    case chargingScheduleOverride
    case chargeLocations
    case locks
    case reducedGuardLock
    case trunk
    case windows
    case honkAndFlash
    case exteriorStatus
    case tyrePressureValues
    case serviceWarnings
    case tripMeters
    case connectivity
    case softwareStatus
    case softwareInstallControl
    case engineStart

    var title: String {
        switch self {
        case .climateStartStop: return L10n.text("Climate start & stop")
        case .climateTemperature: return L10n.text("Climate temperature selection")
        case .seatHeating: return L10n.text("Seat-heating selection")
        case .steeringWheelHeating: return L10n.text("Steering-wheel heating selection")
        case .climateTimers: return L10n.text("Climate timers")
        case .preCleaning: return L10n.text("Cabin pre-cleaning")
        case .chargeLocations: return L10n.text("Saved charge locations")
        case .chargeTarget: return L10n.text("Charge target")
        case .chargingCurrentLimit: return L10n.text("Charging current limit")
        case .chargingSchedule: return L10n.text("Charging schedule")
        case .chargingScheduleOverride: return L10n.text("Charge-schedule override")
        case .locks: return L10n.text("Lock and unlock")
        case .reducedGuardLock: return L10n.text("Lock with reduced guard")
        case .trunk: return L10n.text("Trunk unlock")
        case .windows: return L10n.text("Window control")
        case .honkAndFlash: return L10n.text("Honk and flash")
        case .exteriorStatus: return L10n.text("Doors, windows, and lock status")
        case .tyrePressureValues: return L10n.text("Direct tyre-pressure values")
        case .serviceWarnings: return L10n.text("Service and vehicle warnings")
        case .tripMeters: return L10n.text("Trip meters")
        case .connectivity: return L10n.text("Connectivity diagnostics")
        case .softwareStatus: return L10n.text("Vehicle software status")
        case .softwareInstallControl: return L10n.text("Software installation control")
        case .engineStart: return L10n.text("Remote engine start (RES)")
        }
    }

    var displayName: String { title }

    static let displayed: [VehicleCapability] = [
        .climateStartStop, .climateTemperature, .seatHeating, .steeringWheelHeating,
        .climateTimers, .preCleaning, .chargeTarget, .chargingCurrentLimit,
        .chargingSchedule, .chargingScheduleOverride, .chargeLocations,
        .locks, .reducedGuardLock, .trunk, .windows,
        .honkAndFlash, .exteriorStatus, .tyrePressureValues, .serviceWarnings,
        .tripMeters, .connectivity, .softwareStatus, .softwareInstallControl, .engineStart
    ]
}

struct VehicleProbedCapabilities: Codable, Equatable, Sendable {
    private var results: [VehicleCapability: VehicleCapabilitySupport]
    let probedAt: Date

    static let stalenessInterval: TimeInterval = 6 * 3_600

    init(results: [VehicleCapability: VehicleCapabilitySupport] = [:],
         probedAt: Date = Date()) {
        self.results = results
        self.probedAt = probedAt
    }

    func support(for capability: VehicleCapability) -> VehicleCapabilitySupport? {
        results[capability]
    }

    mutating func record(_ capability: VehicleCapability,
                          as support: VehicleCapabilitySupport) {
        results[capability] = support
    }

    var isStale: Bool {
        Date().timeIntervalSince(probedAt) > Self.stalenessInterval
    }

    var resultsMap: [VehicleCapability: VehicleCapabilitySupport] {
        results
    }

    var allResults: [(capability: VehicleCapability, support: VehicleCapabilitySupport)] {
        let list = results.map { (capability: $0.key, support: $0.value) }
        return list.sorted { (a: (capability: VehicleCapability, support: VehicleCapabilitySupport), b: (capability: VehicleCapability, support: VehicleCapabilitySupport)) in
            a.capability.title < b.capability.title
        }
    }

    func merging(newerProbe: VehicleProbedCapabilities) -> VehicleProbedCapabilities {
        var merged = newerProbe
        for (capability, support) in results where merged.results[capability] == nil {
            merged.results[capability] = support
        }
        return merged
    }

    var count: Int { results.count }
}

struct VehicleCapabilityProfile: Equatable, Sendable {
    let model: VehicleModelFamily
    let probed: VehicleProbedCapabilities?

    init(modelName: String?, vin: String? = nil, probed: VehicleProbedCapabilities? = nil) {
        model = VehicleModelFamily(modelName: modelName, vin: vin)
        self.probed = probed
    }

    func support(for capability: VehicleCapability) -> VehicleCapabilitySupport {
        if let probed, !probed.isStale,
           let observed = probed.support(for: capability) {
            return observed
        }
        switch model {
        case .polestar2:
            switch capability {
            case .climateTemperature, .seatHeating, .steeringWheelHeating:
                return .vehicleManaged
            case .honkAndFlash, .reducedGuardLock:
                return .unavailable
            case .softwareInstallControl:
                return .backendDependent
            case .tyrePressureValues:
                // The reference MY23 capture reported warning level only (no kPa), but this is
                // a firmware/backend question, not a vehicle-hardware fact — EU-market cars
                // carry TPMS hardware. Probe at runtime; the health parser also scans for
                // pressures at alternate field positions before giving up.
                return .backendDependent
            default:
                return .supported
            }
        case .polestar3:
            switch capability {
            case .climateTemperature, .seatHeating, .steeringWheelHeating:
                return .supported
            case .connectivity, .softwareInstallControl, .preCleaning, .chargingCurrentLimit,
                 .reducedGuardLock:
                return .backendDependent
            case .chargeLocations:
                return .backendDependent
            default:
                return .supported
            }
        case .polestar4:
            switch capability {
            case .climateTemperature, .seatHeating, .steeringWheelHeating:
                return .supported
            case .chargingCurrentLimit, .preCleaning, .connectivity, .softwareInstallControl,
                 .reducedGuardLock:
                return .unavailable
            case .softwareStatus, .chargeLocations:
                // Charge-location management is unverified on the SEA-platform Polestar 4;
                // probe at runtime rather than promising a control that may 404.
                return .backendDependent
            default:
                return .supported
            }
        case .polestar1, .polestar5, .polestar6:
            return .backendDependent
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40, .volvoXC60, .volvoXC90,
             .volvoS60, .volvoS90, .volvoV60, .volvoV90, .volvoUnknown:
            switch capability {
            case .locks, .honkAndFlash, .exteriorStatus, .climateStartStop, .serviceWarnings:
                return .supported
            case .climateTemperature, .seatHeating, .steeringWheelHeating:
                return .unavailable
            case .preCleaning, .softwareInstallControl, .windows, .trunk, .chargeLocations:
                return .unavailable
            // Volvo's public APIs expose no software/OTA resource at all — not a backend
            // that might answer on some vehicles, but an endpoint that does not exist.
            case .softwareStatus:
                return .unavailable
            case .chargeTarget, .chargingCurrentLimit, .chargingScheduleOverride:
                return .unavailable
            // Volvo's `tyres` endpoint (indirect TPMS, inferred from wheel-speed imbalance,
            // not a per-wheel pressure sensor) reports a warning-level enum only — there is no
            // numeric kPa/PSI field to report, on any Volvo model, regardless of API product or
            // vehicle configuration. This is a fixed API/hardware fact, not something a live
            // probe could ever resolve differently, so it belongs in the static baseline (like
            // Polestar 2's equivalent case above) rather than sitting at `.backendDependent`
            // forever. Tyre *warning* status itself is still fully supported — see
            // `healthDetails.tyres[].warning`; only the "direct value" capability is unavailable.
            case .tyrePressureValues:
                return .unavailable
            default:
                return .backendDependent
            }
        case .volvoEX30, .volvoEX90, .volvoES90:
            switch capability {
            case .locks, .honkAndFlash, .exteriorStatus, .climateStartStop, .serviceWarnings:
                return .supported
            case .climateTemperature, .seatHeating, .steeringWheelHeating:
                return .supported
            case .softwareInstallControl, .softwareStatus:
                return .unavailable
            // See the comment on the same case above — applies to every Volvo model.
            case .tyrePressureValues:
                return .unavailable
            default:
                return .backendDependent
            }
        case .unknown:
            return .backendDependent
        }
    }

    func permits(_ capability: VehicleCapability) -> Bool {
        support(for: capability).permitsRequest
    }

    var hasSelectableClimateTemperature: Bool {
        support(for: .climateTemperature) == .supported
    }

    var hasSelectableSeatHeating: Bool {
        support(for: .seatHeating) == .supported
    }

    var hasSelectableSteeringWheelHeating: Bool {
        support(for: .steeringWheelHeating) == .supported
    }

    var hasEngineStart: Bool {
        support(for: .engineStart) == .supported
    }

    func featureStatus(for capability: VehicleCapability, in state: VehicleState) -> VehicleFeatureStatus {
        let support = self.support(for: capability)
        let availability: FeatureAvailability
        switch state.availability {
        case .available: availability = .available
        case .unavailable: availability = .vehicleOffline
        case .unknown:
            availability = state.unavailableFeatures.contains(capability.associatedFeature)
                ? .temporarilyUnavailable : .unknown
        }
        return VehicleFeatureStatus(support: support, availability: availability)
    }
}

private extension VehicleCapability {
    var associatedFeature: AppFeature {
        switch self {
        case .climateStartStop, .climateTemperature, .seatHeating,
             .steeringWheelHeating, .climateTimers, .engineStart:
            return .climateStatus
        case .preCleaning: return .airQuality
        case .chargeTarget, .chargingCurrentLimit, .chargingSchedule,
             .chargingScheduleOverride, .chargeLocations: return .chargingSchedule
        case .locks, .reducedGuardLock, .trunk: return .exteriorStatus
        case .windows: return .exteriorStatus
        case .honkAndFlash: return .exteriorStatus
        case .exteriorStatus: return .exteriorStatus
        case .tyrePressureValues, .serviceWarnings: return .tyreAndWarnings
        case .tripMeters: return .tripMeters
        case .connectivity: return .connectivityDiagnostics
        case .softwareStatus, .softwareInstallControl: return .softwareUpdates
        }
    }
}
