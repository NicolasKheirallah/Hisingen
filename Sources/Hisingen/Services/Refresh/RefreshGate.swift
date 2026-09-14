import Foundation

/// What a caller wants the refresh machinery to do.
///
/// An intent, not a set of guards: the caller states what it is trying to do and `RefreshGate`
/// answers whether it may start. Naming the intent is also what lets the gate keep the orders
/// that genuinely differ — see `checks`.
enum RefreshIntent: Equatable {
    /// A scheduled tick.
    case scheduled
    /// The user asked for a refresh: the menu item, ⌘R, or the footer button.
    case manual
    /// The machine woke.
    case wake
    /// The network path came back.
    case networkRestored
    /// An optional metadata reload for the selected vehicle.
    case metadata
    /// The user picked a different vehicle.
    case selection(vin: String)
    /// A session needs establishing before anything else can run.
    case establishSession

    /// A selection supersedes in-flight work — it bumps the generation and cancels what is
    /// running. Every other intent coalesces with it: a second fetch of the same data buys
    /// nothing.
    var supersedesWorkInFlight: Bool {
        if case .selection = self { return true }
        return false
    }
}

/// One precondition a refresh intent must pass.
enum RefreshCheck: Equatable {
    case rateLimit
    case sleep
    case network
    case workInFlight
    case session
    case selection
}

/// Why an intent could not start.
///
/// The cases name outcomes rather than guards, because the entry points present them
/// differently on purpose: a manual refresh publishes when the pause ends, a selection raises
/// `.switchPaused`, and a scheduled tick says nothing at all.
enum RefreshRefusal: Equatable {
    /// Inside a provider rate-limit window.
    case rateLimited(until: Date)
    /// The app is asleep; waking delivers a `.wake` intent.
    case asleep
    /// No usable network path.
    case offline
    /// Equivalent work is already in flight.
    case alreadyRunning
    /// No session yet. The caller should establish one.
    case needsSession
    /// A session exists but no vehicle is selected.
    case noVehicleSelected
}

enum RefreshAdmission: Equatable {
    case start
    case refused(RefreshRefusal)

    var isRefused: Bool { self != .start }
}

/// The one place a refresh intent is admitted or refused, so precedence no longer has to be
/// re-derived by every entry point.
///
/// The order is expressed per intent in `RefreshIntent.checks` because the orders genuinely
/// differ, and the reasons were previously written down nowhere:
///
/// - `manual` asks for a session **before** it asks about in-flight work: a missing session is
///   resolved by establishing one, and `beginSession` defers on its own when work is running.
/// - `scheduled` coalesces with in-flight work **first**: a tick that lands mid-fetch has
///   nothing to add and must not start a second fetch. Its own delay already came from the
///   rate-limit window, so it does not re-check the window and cannot stall the poll.
/// - `selection` checks only the rate limit, because that is the one refusal the UI has a place
///   to present; it supersedes rather than coalesces. Its switch-specific guards (already
///   switching to this car, already settled) stay with the switcher, where the retry budget is.
/// - `metadata` folds every refusal into an ordinary manual refresh.
struct RefreshGate: Equatable {
    /// The facts the decision reads. Values, so the rule stays pure and testable.
    struct Situation: Equatable {
        var isAsleep: Bool
        var isOnline: Bool
        var hasSession: Bool
        var isWorking: Bool
        var rateLimitedUntil: Date?
        var selectedVIN: String
        var now: Date

        init(
            isAsleep: Bool,
            isOnline: Bool,
            hasSession: Bool,
            isWorking: Bool,
            rateLimitedUntil: Date?,
            selectedVIN: String,
            now: Date
        ) {
            self.isAsleep = isAsleep
            self.isOnline = isOnline
            self.hasSession = hasSession
            self.isWorking = isWorking
            self.rateLimitedUntil = rateLimitedUntil
            self.selectedVIN = selectedVIN
            self.now = now
        }
    }

    static func admit(_ intent: RefreshIntent, in situation: Situation) -> RefreshAdmission {
        for check in intent.checks {
            switch check {
            case .rateLimit:
                if let until = situation.rateLimitedUntil, until > situation.now {
                    return .refused(.rateLimited(until: until))
                }
            case .sleep:
                if situation.isAsleep { return .refused(.asleep) }
            case .network:
                if !situation.isOnline { return .refused(.offline) }
            case .workInFlight:
                if situation.isWorking, !intent.supersedesWorkInFlight {
                    return .refused(.alreadyRunning)
                }
            case .session:
                if !situation.hasSession { return .refused(.needsSession) }
            case .selection:
                if situation.selectedVIN.isEmpty { return .refused(.noVehicleSelected) }
            }
        }
        return .start
    }
}

extension RefreshIntent {
    /// The preconditions this intent must pass, in order.
    var checks: [RefreshCheck] {
        switch self {
        case .manual:
            return [.rateLimit, .sleep, .network, .session, .workInFlight, .selection]
        case .scheduled, .wake, .networkRestored:
            return [.workInFlight, .sleep, .network, .session, .selection]
        case .metadata:
            return [.rateLimit, .workInFlight, .session, .selection]
        case .selection:
            return [.rateLimit]
        case .establishSession:
            return [.sleep, .workInFlight, .network]
        }
    }
}
