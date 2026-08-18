import Foundation

enum CommandAvailability: Equatable, Sendable {
    case available
    case disabledBySettings
    case unsupportedByVehicle
    case unimplementedByProvider
    case unavailableWhileBusy

    var isAvailable: Bool { self == .available }
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
        guard !commandInProgress else { return .unavailableWhileBusy }
        return .available
    }
}
