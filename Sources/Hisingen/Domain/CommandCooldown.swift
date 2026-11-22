import Foundation

/// The shortest gap between two sends of the same command to the same vehicle.
///
/// A menu-bar app makes repeats cheap: a location trigger can fire on two refreshes in one
/// minute, a queue can be re-entered from two paths, a Shortcut can be run twice by accident.
/// The vehicle service keeps its own rate limits and a refused send is worse than a delayed one,
/// so unattended paths share one table instead of each inventing a debounce. Interactive taps
/// keep going straight to the coordinator – a person watching the control is their own throttle.
enum CommandCooldown {
    /// How long one command has to wait after a successful send to the same vehicle. A command
    /// not listed here has no cooldown; that reads as "no interval", never as "not allowed".
    static func interval(for command: RemoteCommand) -> TimeInterval {
        switch command {
        case .lock, .lockReducedGuard:
            // The car reports the lock state back within seconds; a second lock inside half a
            // minute is a double tap, not a correction.
            return 30
        case .openWindows, .closeWindows:
            return 60
        case .startClimate, .stopClimate, .startPreCleaning, .stopPreCleaning:
            // These hold the command client for a while and the car spends the next minute
            // acting on the first one.
            return 120
        case .startChargingOverride, .stopChargingOverride:
            return 120
        case .startEngine, .stopEngine:
            return 60
        default:
            return 0
        }
    }

    enum Decision: Equatable, Sendable {
        case allowed
        /// The same command went out too recently. `retryAfter` is what is left of the interval.
        case refused(retryAfter: TimeInterval)

        var isAllowed: Bool { self == .allowed }
    }

    /// Compares the last successful send against the command's interval. A clock that moved
    /// backwards (a manual date change, a time-zone jump) reads as allowed rather than as a
    /// cooldown that would never end.
    static func evaluate(command: RemoteCommand, lastSentAt: Date?, now: Date) -> Decision {
        let interval = interval(for: command)
        guard interval > 0, let lastSentAt else { return .allowed }
        let elapsed = now.timeIntervalSince(lastSentAt)
        guard elapsed >= 0, elapsed < interval else { return .allowed }
        return .refused(retryAfter: interval - elapsed)
    }

    /// Why a duplicate send was refused. It names the command and the wait, so "nothing
    /// happened" never has to be guessed at from an empty log.
    static func refusalReason(command: RemoteCommand, retryAfter: TimeInterval) -> String {
        L10n.format(
            "Wait %@ before sending %@ again.",
            Format.shortDuration(minutes: max(1, Int((retryAfter / 60).rounded(.up)))),
            command.title
        )
    }
}
