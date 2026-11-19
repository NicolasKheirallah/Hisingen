import Foundation

/// Why a charger session began or ended, worded for the history list.
///
/// NexBlue's session list names both with a fixed token. The raw token is what the ledger keeps;
/// these types only word it. A token missing from the table, and the vendor's own "no reason"
/// values (`_None`, `_Other`), word as `nil`, so the row is left out rather than guessed.
enum ChargerSessionStart: String, CaseIterable, Sendable {
    case local = "Local"
    case remote = "Remote"
    case admin = "Admin"
    case schedule = "Schedule"
    case errorRecovery = "ErrorRecover"
    case plugAndCharge = "PlugAndCharge"

    init?(token: String?) {
        guard let token, let value = Self(rawValue: token) else { return nil }
        self = value
    }

    var text: String {
        switch self {
        case .local: return L10n.text("At the charger")
        case .remote: return L10n.text("Remotely")
        case .admin: return L10n.text("By an administrator")
        case .schedule: return L10n.text("By schedule")
        case .errorRecovery: return L10n.text("After an error")
        case .plugAndCharge: return L10n.text("On plug-in")
        }
    }
}

enum ChargerSessionEnd: String, CaseIterable, Sendable {
    case cableUnplugged = "EVDisconnected"
    case complete = "Complete"
    case local = "Local"
    case remote = "Remote"
    case admin = "Admin"
    case schedule = "Schedule"
    case loadBalancing = "LB_Required"
    case unlockCommand = "UnlockCommand"
    case deauthorized = "DeAuthorized"
    case reboot = "Reboot"
    case softReset = "SoftReset"
    case hardReset = "HardReset"
    case powerLoss = "PowerLoss"
    case emergencyStop = "EmergencyStop"

    init?(token: String?) {
        guard let token, let value = Self(rawValue: token) else { return nil }
        self = value
    }

    /// Power loss and an emergency stop are the two endings a reader should notice in a list of
    /// otherwise routine ones.
    var needsAttention: Bool { self == .powerLoss || self == .emergencyStop }

    var text: String {
        switch self {
        case .cableUnplugged: return L10n.text("Cable unplugged")
        case .complete: return L10n.text("Charge complete")
        case .local: return L10n.text("At the charger")
        case .remote: return L10n.text("Remotely")
        case .admin: return L10n.text("By an administrator")
        case .schedule: return L10n.text("By schedule")
        case .loadBalancing: return L10n.text("Held by load balancing")
        case .unlockCommand: return L10n.text("Cable unlocked")
        case .deauthorized: return L10n.text("Not authorised")
        case .reboot, .softReset, .hardReset: return L10n.text("Charger restarted")
        case .powerLoss: return L10n.text("Power loss")
        case .emergencyStop: return L10n.text("Emergency stop")
        }
    }
}
