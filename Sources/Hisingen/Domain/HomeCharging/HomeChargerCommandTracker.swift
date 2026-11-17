import Foundation

enum HomeChargerCommandKind: String, Codable, Equatable, Sendable {
    case start
    case pause

    var title: String {
        switch self {
        case .start: return L10n.text("Charge now")
        case .pause: return L10n.text("Pause")
        }
    }
}

/// Follows one home charger command from the tap to the charger's own answer.
///
/// A successful Home Assistant call means the command was accepted by the integration, nothing
/// more: the NexBlue switch flips to its assumed state at once, and the charger answers on its
/// next poll. So acceptance only moves the command to "waiting for the charger", and the result
/// is read from a charger status reading stamped after acceptance. A reading from before the
/// command can never confirm it, and a window that closes without one is reported as unconfirmed
/// rather than as success.
struct HomeChargerCommandTracker: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case charging(powerKw: Double)
        /// The charger is enabled and the car is drawing no power.
        case enabledNoDraw
        case waitingForPower
        case waitingForVehicle
        case stopped
    }

    enum UnconfirmedReason: Equatable, Sendable {
        /// Fresh readings arrived and none matched the command.
        case timedOut
        /// The charger holds a delayed start (a NexBlue schedule or EcoPilot).
        case delayedStartActive
        case chargerError
        /// No reading stamped after the command arrived at all.
        case noFreshReading
    }

    enum Phase: Equatable, Sendable {
        case idle
        case sending(HomeChargerCommandKind, since: Date)
        case awaitingCharger(HomeChargerCommandKind, acceptedAt: Date, deadline: Date)
        case confirmed(HomeChargerCommandKind, at: Date, outcome: Outcome)
        case rejected(HomeChargerCommandKind, reason: String, at: Date)
        case unconfirmed(HomeChargerCommandKind, since: Date, reason: UnconfirmedReason)
    }

    /// The charger is polled once a minute and Home Assistant schedules extra refreshes after a
    /// command, so two and a half minutes covers a missed poll without hiding a failure.
    static let confirmationWindow: TimeInterval = 150

    private(set) var phase: Phase = .idle

    var isPending: Bool {
        switch phase {
        case .sending, .awaitingCharger: return true
        default: return false
        }
    }

    var kind: HomeChargerCommandKind? {
        switch phase {
        case .idle: return nil
        case .sending(let kind, _), .awaitingCharger(let kind, _, _), .confirmed(let kind, _, _),
             .rejected(let kind, _, _), .unconfirmed(let kind, _, _):
            return kind
        }
    }

    /// True when the charger already answers the way the command would make it answer, so the
    /// command need not be sent. Requires a current reading: a stale one proves nothing.
    static func alreadySatisfied(_ kind: HomeChargerCommandKind, telemetry: HomeChargerTelemetry, now: Date) -> Bool {
        guard case .current = telemetry.freshness(now: now), let status = telemetry.status?.value else { return false }
        switch kind {
        case .start: return status.isChargingEnabled
        case .pause: return status.cableState == true && !status.isChargingEnabled
        }
    }

    mutating func begin(_ kind: HomeChargerCommandKind, now: Date) {
        phase = .sending(kind, since: now)
    }

    /// Home Assistant returned success for the action call.
    mutating func accepted(now: Date, window: TimeInterval = HomeChargerCommandTracker.confirmationWindow) {
        guard case .sending(let kind, _) = phase else { return }
        phase = .awaitingCharger(kind, acceptedAt: now, deadline: now.addingTimeInterval(window))
    }

    /// The call itself failed: Home Assistant answered with an error, or could not be reached.
    mutating func rejected(reason: String, now: Date) {
        guard case .sending(let kind, _) = phase else { return }
        phase = .rejected(kind, reason: reason, at: now)
    }

    mutating func confirmedWithoutSending(_ kind: HomeChargerCommandKind, telemetry: HomeChargerTelemetry, now: Date) {
        phase = .confirmed(kind, at: now, outcome: Self.outcome(for: kind, telemetry: telemetry, now: now) ?? .stopped)
    }

    mutating func dismiss() {
        guard !isPending else { return }
        phase = .idle
    }

    /// Feed every telemetry change and every clock tick here while a command is pending.
    mutating func observe(_ telemetry: HomeChargerTelemetry, now: Date) {
        guard case .awaitingCharger(let kind, let acceptedAt, let deadline) = phase else { return }
        if let reading = telemetry.status, reading.timestamp >= acceptedAt {
            if reading.value == .error {
                phase = .unconfirmed(kind, since: now, reason: .chargerError)
                return
            }
            if let outcome = Self.outcome(for: kind, telemetry: telemetry, now: now) {
                phase = .confirmed(kind, at: now, outcome: outcome)
                return
            }
        }
        guard now >= deadline else { return }
        let reason: UnconfirmedReason
        if let reading = telemetry.status, reading.timestamp >= acceptedAt {
            reason = kind == .start && reading.value == .delayedStart ? .delayedStartActive : .timedOut
        } else {
            reason = .noFreshReading
        }
        phase = .unconfirmed(kind, since: now, reason: reason)
    }

    private static func outcome(for kind: HomeChargerCommandKind, telemetry: HomeChargerTelemetry, now: Date) -> Outcome? {
        guard let status = telemetry.status?.value else { return nil }
        switch kind {
        case .start:
            switch status {
            case .charging:
                let power = telemetry.powerKw?.value ?? 0
                return power < HomeChargerTelemetry.zeroPowerThresholdKw ? .enabledNoDraw : .charging(powerKw: power)
            case .waitingForPower: return .waitingForPower
            case .waitingForVehicle: return .waitingForVehicle
            default: return nil
            }
        case .pause:
            switch status {
            case .pluggedIn, .finished, .delayedStart, .unplugged: return .stopped
            default: return nil
            }
        }
    }
}
