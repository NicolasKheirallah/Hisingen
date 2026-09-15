import AppKit
import SwiftUI

@MainActor
struct ControlsCommandGate {
    let state: VehicleState
    /// The live session's brand, not `preferences.activeBrand` – the two can disagree for
    /// the brief window while a brand switch rebuilds the session, and gating must agree
    /// with what dispatch would actually use.
    let brand: VehicleBrand
    let preferences: PreferencesStore
    let remoteCommandInProgress: Bool
    let inFlightCommandID: String?
    let onRemoteCommand: (RemoteCommand) -> Void

    var features: Set<AppFeature> { preferences.features.enabled }

    /// Dispatches a command, refusing one the gate itself would disable.
    ///
    /// `send` had no self-guard, so every caller had to remember to check `isDisabled` first and a
    /// caller that forgot dispatched a command the gate would have refused — which is the root
    /// cause of the schedule editor's silent no-op. The guard belongs where the decision is made.
    func send(_ command: RemoteCommand) {
        guard !isDisabled(command) else { return }
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

    /// Whether the card could ever work for this vehicle, ignoring a command that happens to be
    /// running. This is the capability question, and it is deliberately blind to the busy flag: it
    /// answers "is a restriction here that re-probing might lift?", which is what decides whether
    /// to offer a re-probe. A card that is dimmed only because another command is in flight must
    /// not make the re-probe button appear and disappear on every tap.
    func capabilityAvailability(_ commands: [RemoteCommand]) -> CommandAvailability {
        var fallback: CommandAvailability = .unsupportedByVehicle
        for command in commands {
            let availability = availability(command, ignoreBusy: true)
            if availability.isAvailable { return .available }
            fallback = availability
        }
        return fallback
    }

    /// Whether the card is usable *right now*, which includes a command that is already in flight.
    ///
    /// This is the question a card's dimming and its explanation have to answer, and it is not the
    /// same question as `capabilityAvailability`. `CapabilityGate` refuses every command while any
    /// is in flight, and a charge-limit write holds that state for 15 to 30 seconds, so the honest
    /// answer is routinely "no, and here is why" rather than "no, this vehicle cannot do it".
    /// Both callers used to ask the capability question, which left the sentence written for
    /// exactly this state (`Another remote command is still running.`) unreachable and left the
    /// cards looking live while every control on them was refused.
    func liveAvailability(_ commands: [RemoteCommand]) -> CommandAvailability {
        var fallback: CommandAvailability = .unsupportedByVehicle
        for command in commands {
            let availability = availability(command)
            if availability.isAvailable { return .available }
            fallback = availability
        }
        return fallback
    }

    func liveOpacity(_ commands: [RemoteCommand]) -> Double {
        liveAvailability(commands) == .available ? 1.0 : 0.6
    }
}
