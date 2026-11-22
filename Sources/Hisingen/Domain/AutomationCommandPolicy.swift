import Foundation

/// What an unattended path may send.
///
/// A schedule or a location trigger fires while nobody is at the Mac to answer a confirmation
/// sheet or a device-owner prompt, so the action it carries has to be one the vehicle service
/// would accept without either. That is exactly the routine tier: the same set
/// `CommandCoordinator` already runs silently for `.automation` origins. Anything a person has
/// to approve stays a tap in the Controls tab.
enum AutomationCommandPolicy {
    /// Whether an unattended path may carry `command`. The check is on risk rather than an
    /// allowlist of cases, so a command a future provider adds at routine risk becomes
    /// schedulable without editing a table that would then disagree with the coordinator.
    static func allows(_ command: RemoteCommand) -> Bool {
        command.risk == .routine
    }

    /// The actions offered when the reader builds a schedule or a trigger. Only the ones a
    /// reader actually plans around: locking, closing the windows, climate and cabin cleaning,
    /// and the charging override. Charge targets and timers are one-off settings, not events.
    static func choices() -> [RemoteCommand] {
        [
            .lock,
            .closeWindows,
            .startClimate(
                temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
                rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified),
            .stopClimate,
            .startPreCleaning,
            .stopPreCleaning,
            .startChargingOverride,
            .stopChargingOverride,
        ].filter(allows)
    }
}
