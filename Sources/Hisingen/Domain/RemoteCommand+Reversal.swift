import Foundation

extension RemoteCommand {
    /// The command that puts back what this one changed, or `nil` when the app has no reversal it
    /// can send safely. Honk and flash are one-shot signals with nothing to restore. Software
    /// installs, engine start and charge locations are never reversed from a banner. Lock with
    /// reduced guard is left out because the reader never asked for the guard to be lowered.
    ///
    /// `setChargeTarget` needs the target the car held before the command, captured at dispatch.
    /// Without it the prior state is unknown, so there is nothing to undo to.
    func inverse(previousChargeTarget: Int?) -> RemoteCommand? {
        switch self {
        case .lock: return .unlock
        case .unlock: return .lock
        case .openWindows: return .closeWindows
        case .closeWindows: return .openWindows
        case .openTailgate: return .closeTailgate
        case .closeTailgate: return .openTailgate
        case .startPreCleaning: return .stopPreCleaning
        case .stopPreCleaning: return .startPreCleaning
        case .startClimate:
            return .stopClimate
        case .stopClimate:
            // The settings the climate was running at are not recorded, so undo starts it on the
            // car's automatic setpoint with no seat or steering wheel heating.
            return .startClimate(
                temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
                rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified)
        case .setChargeTarget(let target):
            guard let previousChargeTarget, previousChargeTarget != target else { return nil }
            return .setChargeTarget(previousChargeTarget)
        case .unlockTrunk, .lockReducedGuard, .flashLights, .honkAndFlash, .honkHorn,
             .setAmpLimit, .startChargingOverride, .stopChargingOverride, .setGlobalChargeTimer,
             .setClimateTimer, .deleteClimateTimer, .scheduleOTA, .installOTANow, .cancelOTA,
             .createChargeLocationAtCar, .updateChargeLocationAlias, .updateChargeLocationAmpLimit,
             .updateChargeLocationMinimumSoc, .setChargeLocationOptimisedCharging,
             .deleteChargeLocation, .startEngine, .stopEngine:
            return nil
        }
    }
}
