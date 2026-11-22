import Foundation

/// Whether the Developer Portal is entitled to serve this account right now.
///
/// The portal is one credential pair with its own failure vocabulary: no pair configured, the
/// owner revoked the app's access to a VIN, the daily quota is spent, or the gateway is down.
/// A plain "portal failed" cannot decide whether the Polestar ID session may stand in, so the
/// probe names the state and the fallback policy acts on it.
enum PortalEntitlement: Equatable, Sendable {
    case entitled
    /// No client ID/secret pair is configured, so the portal cannot answer at all.
    case credentialsMissing
    /// The owner has not granted Hisingen access to a vehicle, or the grant was withdrawn.
    case accessRevoked(retryAfter: Date?)
    case rateLimited(retryAfter: Date?)
    /// The portal is reachable in principle but the probe could not confirm access this time.
    case unavailable(reason: String?)

    /// Whether the portal itself is worth asking. A missing credential or a revoked grant will
    /// not clear before the next session, while `unavailable` may clear on its own.
    var canServePortal: Bool {
        switch self {
        case .entitled, .unavailable: return true
        case .credentialsMissing, .accessRevoked, .rateLimited: return false
        }
    }

    /// When a blocked portal state expires, if the provider named a time.
    var retryAfter: Date? {
        switch self {
        case .accessRevoked(let date), .rateLimited(let date): return date
        default: return nil
        }
    }

    var explanation: String? {
        switch self {
        case .entitled: return nil
        case .credentialsMissing:
            return L10n.text("No Developer Portal credentials are configured.")
        case .accessRevoked:
            return L10n.text("Developer Portal access to this vehicle was not granted. Re-enable data sharing in the Polestar app.")
        case .rateLimited:
            return L10n.text("The Developer Portal daily call limit has been reached.")
        case .unavailable:
            return L10n.text("Developer Portal access could not be verified.")
        }
    }
}

/// A provider that can answer the entitlement question itself. `PolestarDataPortalAPI`
/// conforms; tests and adapters without a portal can supply a probe of their own.
protocol PortalEntitlementReporting: Sendable {
    func probeEntitlement(now: Date) async -> PortalEntitlement
}

/// Configuration-only probe for a portal that cannot mint a token in this context. It answers
/// only the question the stored facts can settle: is a credential pair present at all?
struct PortalEntitlementProbe: Sendable {
    let hasClientID: Bool
    let hasClientSecret: Bool

    func probe() -> PortalEntitlement {
        hasClientID && hasClientSecret ? .entitled : .credentialsMissing
    }
}

/// What the fallback provider may do with the portal's current state.
enum PortalFallbackDecision: Equatable, Sendable {
    /// Ask the portal first; fall back only if that request fails.
    case portalFirst
    /// Skip the portal for this refresh and serve from the consumer session.
    case fallbackOnly(reason: String?)
}

struct PortalFallbackPolicy {
    /// `.dataPortal` used to have no fallback at all: a revoked grant, a spent quota or a
    /// missing credential left every card dark even when a Polestar ID session was warm. The
    /// policy keeps the portal as the primary whenever it might answer and otherwise names the
    /// reason the fallback is serving.
    static func decide(
        entitlement: PortalEntitlement,
        consumerWarm: Bool,
        now: Date = Date()
    ) -> PortalFallbackDecision {
        guard consumerWarm else { return .portalFirst }
        if entitlement.canServePortal { return .portalFirst }
        if let retryAfter = entitlement.retryAfter, retryAfter <= now {
            // The stated window has passed; let the portal prove itself again.
            return .portalFirst
        }
        return .fallbackOnly(reason: entitlement.explanation)
    }
}
