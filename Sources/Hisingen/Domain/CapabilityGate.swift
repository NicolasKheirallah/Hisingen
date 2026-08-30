import Foundation

enum CommandAvailability: Equatable, Sendable {
    case available
    case disabledBySettings
    case unsupportedByVehicle
    case unimplementedByProvider
    case unavailableWhileBusy
    case unavailableUntilRefresh

    var isAvailable: Bool { self == .available }

    /// Short, human explanation for why a control is inert, shown under a dimmed card so
    /// "shown but disabled" reads as a specific state rather than a glitch. `nil` when the
    /// command is available.
    var shortReason: String? {
        switch self {
        case .available:
            return nil
        case .disabledBySettings:
            return L10n.text("Turn this on in Settings → Telemetry & Features.")
        case .unsupportedByVehicle:
            return L10n.text("This vehicle does not support the command.")
        case .unimplementedByProvider:
            return L10n.text("Not available through this account's vehicle service.")
        case .unavailableWhileBusy:
            return L10n.text("Another remote command is still running.")
        case .unavailableUntilRefresh:
            return L10n.text("Refresh vehicle data before sending a command.")
        }
    }
}

/// The single application-level decision point for whether a remote command may be shown or sent.
/// Provider probing remains provider-specific; this combines those facts with app policy.
struct CapabilityGate: Sendable {
    func availability(
        for command: RemoteCommand,
        state: VehicleState,
        brand: VehicleBrand,
        enabledFeatures: Set<AppFeature>,
        commandInProgress: Bool
    ) -> CommandAvailability {
        guard enabledFeatures.contains(command.feature) else { return .disabledBySettings }
        guard command.isImplemented(by: brand) else { return .unimplementedByProvider }
        guard state.capabilityProfile.permits(command.requiredCapability) else { return .unsupportedByVehicle }
        guard Date().timeIntervalSince(state.fetchedAt) < 10 * 60 else { return .unavailableUntilRefresh }
        guard !commandInProgress else { return .unavailableWhileBusy }
        return .available
    }
}
