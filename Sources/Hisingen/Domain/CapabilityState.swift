import Foundation

/// What is known about one optional capability reading.
///
/// This replaces `OptionalCapability`, which asked the same question with three independent
/// fields — `value`, `unavailable`, `unsupported` — and could not express a state the UI tier
/// already named: `CapabilityBadge` had an `.unknown` case labelled "Not yet checked", while the
/// API tier had no way to say it. Three fields also allowed states that cannot happen
/// (unavailable *and* unsupported, or a value that is simultaneously unavailable), and they made
/// "the feature is off, so we never asked" indistinguishable from "we asked and the provider had
/// nothing" — both arrived as `(nil, false, false)`.
///
/// One enum instead. The four states are mutually exclusive by construction, and the questions
/// consumers actually ask survive as read-only projections (`value`, `unavailable`,
/// `unsupported`), so a caller can read the state but cannot assemble an incoherent one.
enum CapabilityState<Value: Sendable>: Sendable {
    /// The reading was taken. The payload is optional because a provider can answer successfully
    /// and still have nothing for this reading — which is deliberately *not* the same as never
    /// having asked.
    case available(Value?)
    /// The vehicle or backend does not implement this reading.
    case unsupported
    /// The reading failed in a way that may clear on its own.
    case unavailable
    /// Nothing is established, because the reading was never requested.
    case unknown

    /// The payload, when a reading was taken.
    var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }

    /// Whether the reading failed in a recoverable way.
    var unavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Whether the vehicle or backend does not implement this reading.
    var unsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }

    /// The same state with its payload erased — all a badge needs in order to name and draw it.
    var summary: CapabilitySummary {
        switch self {
        case .available: return .available
        case .unsupported: return .unsupported
        case .unavailable: return .unavailable
        case .unknown: return .unknown
        }
    }
}

extension CapabilityState: Equatable where Value: Equatable {}

/// `CapabilityState` with its payload removed, for surfaces that only name the state.
///
/// Not a second vocabulary: it has the same four cases and is only ever produced by
/// `CapabilityState.summary`. It exists because a badge carries no payload, and a bare case
/// literal (`.unavailable`) needs a concrete generic argument at the call site.
enum CapabilitySummary: Hashable, Sendable {
    case available
    case unsupported
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .available: return L10n.text("Available")
        case .unsupported: return L10n.text("Unsupported")
        case .unavailable: return L10n.text("Temporarily unavailable")
        case .unknown: return L10n.text("Not yet checked")
        }
    }

    var symbol: String {
        switch self {
        case .available: return "checkmark.circle"
        case .unsupported: return "minus.circle"
        case .unavailable: return "wifi.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }
}
