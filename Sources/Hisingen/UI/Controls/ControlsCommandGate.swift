import AppKit
import SwiftUI

@MainActor
struct ControlsCommandGate {
    let state: VehicleState
    let preferences: PreferencesStore
    let remoteCommandInProgress: Bool
    let inFlightCommandID: String?
    let onRemoteCommand: (RemoteCommand) -> Void

    private let capabilityGate = CapabilityGate()

    var features: Set<AppFeature> { preferences.features.enabled }

    func send(_ command: RemoteCommand) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            command.risk == .routine ? .generic : .levelChange,
            performanceTime: .now
        )
        onRemoteCommand(command)
    }

    func availability(
        _ command: RemoteCommand,
        ignoreBusy: Bool = false
    ) -> CommandAvailability {
        capabilityGate.availability(
            for: command,
            state: state,
            commandCatalog: ProviderCommandCatalog(brand: preferences.activeBrand),
            enabledFeatures: features,
            commandInProgress: ignoreBusy ? false : remoteCommandInProgress,
            volvoRestrictedScopesEnabled: preferences.volvoRestrictedScopesEnabled
        )
    }

    func isDisabled(_ command: RemoteCommand) -> Bool {
        !availability(command).isAvailable
    }

    func isSending(_ command: RemoteCommand) -> Bool {
        remoteCommandInProgress && inFlightCommandID == command.identifier
    }

    func cardAvailability(_ commands: [RemoteCommand]) -> CommandAvailability {
        var fallback: CommandAvailability = .unsupportedByVehicle
        for command in commands {
            let availability = availability(command, ignoreBusy: true)
            if availability.isAvailable { return .available }
            fallback = availability
        }
        return fallback
    }

    func cardOpacity(_ commands: [RemoteCommand]) -> Double {
        cardAvailability(commands) == .available ? 1.0 : 0.6
    }
}
