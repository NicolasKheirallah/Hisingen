import Foundation

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

    /// False for a provider token the app does not recognise, which is not a state it can vouch
    /// for and must not present with the same confidence as one it can.
    var isRecognised: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(apiValue: String?) {
        let key = (apiValue ?? "")
            .replacingOccurrences(of: "CHARGING_STATUS_V2_", with: "")
            .replacingOccurrences(of: "CHARGING_STATUS_", with: "")
            .uppercased()
        switch key {
        case "CHARGING", "CHARGING_TOWARDS_MIN_SOC", "CHARGING_IS_EN_ROUTE", "FAST_CHARGING":
            self = .charging
        case "SMART_CHARGING", "SMART_CHARGING_WILL_NOT_FINISH":
            self = .smartCharging
        case "SMART_CHARGING_PAUSED":
            self = .paused
        case "SCHEDULED", "SCHEDULED_CHARGING_WILL_COMPLETE", "SCHEDULED_CHARGING_CANNOT_COMPLETE":
            self = .scheduled
        case "IDLE":
            self = .idle
        case "DONE", "CHARGE_LEVEL_IS_GOOD_TO_GO":
            self = .complete
        case "DISCHARGING", "DISCHARGING_V2H", "DISCHARGING_V2L":
            self = .discharging
        case "ERROR", "FAULT":
            self = .fault
        default:
            self = .unknown(key.isEmpty ? "UNSPECIFIED" : key)
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
            // A provider token the app does not recognise was rendered as though it were a state
            // the app understands — "Unknown (Cable Connected Ac)" sat in the hero pill in the same
            // weight and colour as "Charging". It says plainly that it is unrecognised now.
            let displayValue = value.replacingOccurrences(of: "_", with: " ").capitalized
            return displayValue.isEmpty
                ? L10n.text("Not reported")
                : L10n.format("Unrecognised state: %@", displayValue)
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

/// How a state-of-charge reading should read at a glance, so every renderer agrees on where
/// the thresholds are and only the palette differs between them.
///
/// These are presentation thresholds. The user's own low-battery *alert* level is a separate
/// setting (`PreferencesStore.lowBatteryThreshold`) that notifications and readiness use; the
/// two were previously hardcoded side by side and drifted apart.
enum BatteryLevel: Equatable, Sendable {
    case critical
    case low
    /// Actively charging, not yet near full: the renderers show progress rather than alarm.
    case charging
    /// Actively charging and close enough to full to read as good news.
    case chargingComplete
    case normal

    static let criticalPercentage = 15.0
    static let lowPercentage = 35.0
    static let chargingCompletePercentage = 80.0
}

