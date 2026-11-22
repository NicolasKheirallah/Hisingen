import Foundation
import HisingenIntents

/// The app side of the shared widget-intent seam.
///
/// The widget-facing intents live in `HisingenIntents` so the extension and the app name the
/// same types. The extension cannot link the app, so it links the intent module only; this
/// adapter is what the app registers at launch, and it routes each command through the same
/// handoff, capability gates and confirmation the app's own controls use.
@MainActor
final class WidgetIntentCommandHandler: VehicleWidgetCommandHandling {
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore = .shared) {
        self.preferences = preferences
    }

    func perform(_ command: VehicleWidgetCommand, vin: String?) async throws -> String {
        switch command {
        case .lock:
            return await AutomationHandoff.send(.lock, vehicle: vin, preferences: preferences)
        case .unlock:
            return await AutomationHandoff.send(.unlock, vehicle: vin, preferences: preferences)
        case .startClimate:
            // Seat and wheel levels mirror the in-app and Shortcuts climate paths, which all
            // start from the reader's saved remote-seat-heating preferences.
            return await AutomationHandoff.send(
                .startClimate(
                    temperatureCelsius: Float(preferences.remoteClimateTemperature),
                    frontLeftSeat: preferences.remoteDriverSeatHeating,
                    frontRightSeat: preferences.remoteFrontRightSeatHeating,
                    rearLeftSeat: preferences.remoteRearLeftSeatHeating,
                    rearRightSeat: preferences.remoteRearRightSeatHeating,
                    steeringWheel: preferences.remoteSteeringWheelHeating),
                vehicle: vin,
                preferences: preferences)
        case .refresh:
            // Refresh is not a remote command: it asks the same launch-installed action the
            // Shortcuts intent and the panel use, so there is no second refresh path.
            guard let refresh = AutomationHandoff.refreshAction else {
                return L10n.text("Hisingen is still launching. Try again in a moment.")
            }
            refresh()
            return L10n.text("Refresh requested – Hisingen is fetching the latest vehicle data.")
        }
    }
}
