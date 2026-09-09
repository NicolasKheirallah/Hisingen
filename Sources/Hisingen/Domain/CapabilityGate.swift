import Foundation

enum CommandAvailability: Equatable, Sendable {
    case available
    case disabledBySettings
    case unsupportedByVehicle
    case unimplementedByProvider
    case unavailableWhileBusy
    case unavailableUntilRefresh
    /// The backend explicitly reports the signed-in account is not the vehicle's owner
    /// (`GetMyCars.userIsOwner == false`). Distinct from "unknown" — an absent flag never
    /// blocks a command.
    case notVehicleOwner
    /// The Volvo account token lacks the "Approved" (restricted) scopes a write needs —
    /// the user must re-grant them in Settings before lock/unlock/locate can run.
    case requiresAccountApproval
    case invalidSettings(String)

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
        case .notVehicleOwner:
            return L10n.text("The vehicle reports this account as not being its owner. Owner commands are disabled.")
        case .requiresAccountApproval:
            return L10n.text("Enable Approved Volvo permissions in Settings and sign in again first.")
        case .invalidSettings(let reason): return reason
        }
    }
}

/// The single application-level decision point for whether a remote command may be shown or sent.
/// Provider probing remains provider-specific; this combines those facts with app policy.
struct CapabilityGate: Sendable {
    func availability(
        for command: RemoteCommand,
        state: VehicleState,
        commandCatalog: ProviderCommandCatalog,
        enabledFeatures: Set<AppFeature>,
        commandInProgress: Bool,
        volvoRestrictedScopesEnabled: Bool = true
    ) -> CommandAvailability {
        guard enabledFeatures.contains(command.feature) else { return .disabledBySettings }
        guard commandCatalog.implements(command) else { return .unimplementedByProvider }
        // Volvo's lock/unlock/locate writes need the restricted ("Approved") scope tier on
        // the signed-in token; without it the provider would reject the command after the
        // fact. One shared precondition keeps every entry point's answer identical.
        if commandCatalog.brand == .volvo, !volvoRestrictedScopesEnabled,
           command.feature == .remoteLocks || command.feature == .remoteHonkFlash {
            return .requiresAccountApproval
        }
        if commandCatalog.brand == .polestar, state.otaCapabilities?.honkFlashMode?.permits(command) == false {
            return .unsupportedByVehicle
        }
        guard state.capabilityProfile.permits(command.requiredCapability) else { return .unsupportedByVehicle }
        guard state.accountOwnsVehicle != false else { return .notVehicleOwner }
        let settings = state.otaCapabilities?.controlSettings ?? VehicleControlSettings()
        let adaptedCommand = command.adapted(to: state.capabilityProfile, settings: settings)
        if let reason = settings.rejection(for: adaptedCommand, state: state) {
            return .invalidSettings(reason)
        }
        guard Date().timeIntervalSince(state.fetchedAt) < 10 * 60 else { return .unavailableUntilRefresh }
        guard !commandInProgress else { return .unavailableWhileBusy }
        return .available
    }
}
