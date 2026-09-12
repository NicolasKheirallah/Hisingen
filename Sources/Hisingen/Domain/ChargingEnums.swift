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

