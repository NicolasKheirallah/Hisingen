import AppKit
import SwiftUI

@MainActor
struct ControlsCommandGate {
    let state: VehicleState
    /// The live session's brand, not `preferences.activeBrand` — the two can disagree for
    /// the brief window while a brand switch rebuilds the session, and gating must agree
    /// with what dispatch would actually use.
    let brand: VehicleBrand
    let preferences: PreferencesStore
    let remoteCommandInProgress: Bool
    let inFlightCommandID: String?
    let onRemoteCommand: (RemoteCommand) -> Void

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
        CapabilityGate.availability(
            for: command,
            state: state,
            brand: brand,
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
