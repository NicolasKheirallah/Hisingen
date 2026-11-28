import Foundation
import OSLog

/// Fires the reader's actions when the car arrives at, or leaves, a saved charge location.
///
/// The comparison is Hisingen's own: the vehicle snapshot already carries a position and the
/// saved locations already carry coordinates (`ChargeLocationPresence`). No Location Services
/// request is made, so the feature works on a Mac where Hisingen has never asked for anything,
/// and the reader is never shown a prompt that a menu-bar app has no business raising.
///
/// Triggers react to a *change*. The first snapshot after launch only records where the car is:
/// otherwise every launch while parked at home would send "arrived at Home" again.
@MainActor
final class ChargeLocationTriggerController {
    private let logger = AppLog.logger("automation")
    private let preferences: PreferencesStore
    private let send: @MainActor (RemoteCommand, String?) async -> AutomationSendResult

    /// Where each vehicle was the last time this process looked. Optional-of-optional because
    /// "never looked" and "looked, not at a saved location" are different answers: the first must
    /// not fire, the second can end in an arrival.
    private struct Observation {
        let presence: ChargeLocationPresence?
    }
    private var observations: [String: Observation] = [:]

    init(preferences: PreferencesStore,
         send: @escaping @MainActor (RemoteCommand, String?) async -> AutomationSendResult) {
        self.preferences = preferences
        self.send = send
    }

    convenience init(preferences: PreferencesStore,
                     send: @escaping @MainActor (RemoteCommand) async -> AutomationSendResult) {
        self.init(preferences: preferences) { command, _ in await send(command) }
    }

    /// Called for every fresh snapshot. `state.chargeLocationPresence` was resolved from the
    /// position and the saved locations during the snapshot merge.
    func vehicleStateDidUpdate(_ state: VehicleState) async {
        let vin = state.identity.vin.normalizedVIN
        guard !vin.isEmpty else { return }
        let current = state.chargeLocationPresence
        let previous = observations[vin]
        observations[vin] = Observation(presence: current)

        let triggers = preferences.locationTriggers.filter(\.isRunnable)
        guard !triggers.isEmpty, let previous else { return }

        let transition = ChargeLocationTransition.between(previous: previous.presence, current: current)
        guard transition != .none else { return }

        for trigger in triggers where trigger.applies(to: vin) {
            let destinationVIN = trigger.targetVIN ?? vin
            switch trigger.event {
            case .arrival:
                guard let arrival = transition.arrival, trigger.watches(locationID: arrival.locationID) else { continue }
                logger.info("Arrival trigger at \(arrival.locationID, privacy: .private) firing")
                _ = await send(trigger.command, destinationVIN)
            case .departure:
                guard let departure = transition.departure, trigger.watches(locationID: departure.locationID) else { continue }
                logger.info("Departure trigger from \(departure.locationID, privacy: .private) firing")
                _ = await send(trigger.command, destinationVIN)
            }
        }
    }

    /// Forgets the recorded positions. Called when the reader edits triggers so the next snapshot
    /// re-baselines instead of comparing against a stale location.
    func resetObservations() {
        observations.removeAll()
    }
}
