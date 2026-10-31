import Foundation

extension AppDelegate {
    func startCalendarClimate() async -> RemoteCommandDispatchOutcome {
        // Don't attempt (and don't spend a "Command not sent" banner) when the user has
        // turned the remote-climate feature off. Capability/session gating still happens
        // inside `CommandCoordinator`.
        guard preferences.features.contains(.remoteClimate) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        return await commandCoordinator.perform(
            .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: preferences.remoteDriverSeatHeating,
                frontRightSeat: preferences.remoteFrontRightSeatHeating,
                rearLeftSeat: preferences.remoteRearLeftSeatHeating,
                rearRightSeat: preferences.remoteRearRightSeatHeating,
                steeringWheel: preferences.remoteSteeringWheelHeating
            ),
            origin: .automation)
    }

    /// The planner's unattended start-charging path. Guarded on the remote-charging
    /// feature so turning that off also disarms auto-start; `.automation` origin means
    /// the coordinator runs the routine-risk `startChargingOverride` silently (no sheet,
    /// no biometrics) – auto-start is its own explicit consent in the planner settings.
    func startPlannerCharging(targetVIN: String) async -> RemoteCommandDispatchOutcome {
        guard preferences.features.contains(.remoteCharging) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        guard !targetVIN.isEmpty, let currentVIN = vehicleSession.latest?.identity.vin,
              currentVIN.caseInsensitiveCompare(targetVIN) == .orderedSame else {
            return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
        }
        return await commandCoordinator.perform(.startChargingOverride, origin: .automation)
    }
}
