import Foundation

/// A part of the vehicle a provider connection can reach, named without any provider's own
/// endpoint vocabulary. One list serves the capability inspector, the connection's domain
/// support map, and the fallback policy that decides which provider may fill a gap.
enum ProviderDomain: String, Codable, CaseIterable, Sendable {
    case telemetry
    case energy
    case availability
    case climate
    case locks
    case engine
    case honkFlash
    case location
    case exterior
    case health
    case odometer
    case schedules
    case charging
    case software
    case connectivity
    case commands

    var title: String {
        switch self {
        case .telemetry: return L10n.text("Vehicle telemetry")
        case .energy: return L10n.text("Energy readings")
        case .availability: return L10n.text("Availability")
        case .climate: return L10n.text("Climate")
        case .locks: return L10n.text("Lock controls")
        case .engine: return L10n.text("Engine")
        case .honkFlash: return L10n.text("Honk & flash controls")
        case .location: return L10n.text("Location")
        case .exterior: return L10n.text("Exterior status")
        case .health: return L10n.text("Vehicle health")
        case .odometer: return L10n.text("Odometer")
        case .schedules: return L10n.text("Schedules")
        case .charging: return L10n.text("Charging controls")
        case .software: return L10n.text("Vehicle software")
        case .connectivity: return L10n.text("Connectivity diagnostics")
        case .commands: return L10n.text("Remote commands")
        }
    }
}

/// The credential shape behind one provider choice. The same brand can answer through more
/// than one of these, and what it can read differs per channel.
enum ProviderChannel: String, Codable, CaseIterable, Sendable {
    case polestarID
    case polestarDataPortal
    case polestarAugmented
    case volvo

    var displayName: String {
        switch self {
        case .polestarID: return L10n.text("Polestar ID")
        case .polestarDataPortal: return L10n.text("Developer Portal")
        case .polestarAugmented: return L10n.text("Augmented")
        case .volvo: return L10n.text("Volvo cloud")
        }
    }
}

/// What the provider stated, or what the app can legitimately infer, about one domain's
/// authorization. The distinction between "asked and refused" and "never asked" is the whole
/// point: both used to render as a generic unavailable badge.
enum ProviderScopeGrantState: String, Codable, Sendable {
    case granted
    case partial
    case notGranted
    case notRequested
    case unknown

    var label: String {
        switch self {
        case .granted: return L10n.text("Granted")
        case .partial: return L10n.text("Partly granted")
        case .notGranted: return L10n.text("Not granted")
        case .notRequested: return L10n.text("Not requested")
        case .unknown: return L10n.text("Unknown")
        }
    }

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .notGranted: return "xmark.circle"
        case .notRequested: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct ProviderScopeGrant: Codable, Equatable, Sendable, Identifiable {
    let domain: ProviderDomain
    let scopes: [String]
    let state: ProviderScopeGrantState

    var id: ProviderDomain { domain }
}

/// One reading the provider answered with a status instead of a value. `reason` is the
/// provider's own `unavailableReason`/`code`, kept verbatim so the inspector can show what the
/// car said rather than inventing a friendlier cause.
struct ProviderReadingStatus: Codable, Equatable, Sendable, Identifiable {
    let feature: AppFeature
    let field: String
    let label: String
    let status: String?
    let reason: String?

    var id: String { "\(feature.rawValue).\(field)" }

    /// The provider's status and reason in one line, e.g. "ERROR · PROPERTY_NOT_FOUND".
    var providerText: String? {
        var parts: [String] = []
        for value in [status, reason] {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            parts.append(trimmed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What one refresh knows about a provider connection: which scopes or domains it was granted,
/// and which readings the provider answered with a status. Persisted with the snapshot so the
/// inspector keeps last-known answers across relaunches instead of starting blank.
struct ProviderCapabilityReport: Codable, Equatable, Sendable {
    let providerName: String
    let channel: ProviderChannel
    let recordedAt: Date?
    let requestedScopes: [String]
    let grantedScopes: [String]?
    let grants: [ProviderScopeGrant]
    let degradedReadings: [ProviderReadingStatus]
    let supportedDomains: [ProviderDomain]
    let servedByFallback: Bool
    /// A connection-level explanation when the channel itself changed what could be read, for
    /// example a portal refresh served by the Polestar ID fallback.
    let connectionNote: String?

    init(
        providerName: String,
        channel: ProviderChannel,
        recordedAt: Date? = nil,
        requestedScopes: [String] = [],
        grantedScopes: [String]? = nil,
        grants: [ProviderScopeGrant] = [],
        degradedReadings: [ProviderReadingStatus] = [],
        supportedDomains: [ProviderDomain]? = nil,
        servedByFallback: Bool = false,
        connectionNote: String? = nil
    ) {
        self.providerName = providerName
        self.channel = channel
        self.recordedAt = recordedAt
        self.requestedScopes = requestedScopes
        self.grantedScopes = grantedScopes
        self.grants = grants
        self.degradedReadings = degradedReadings
        self.supportedDomains = supportedDomains ?? ProviderDomainSupportMap.domains(for: channel)
        self.servedByFallback = servedByFallback
        self.connectionNote = connectionNote
    }

    /// Whether the provider actually stated a grant. A per-domain row exists even without one
    /// (every domain answers "unknown"), so the rows alone are not evidence.
    var hasScopeEvidence: Bool {
        if grantedScopes != nil { return true }
        return grants.contains { $0.state == .granted || $0.state == .partial || $0.state == .notGranted }
    }

    /// The provider's own reason for a feature's missing reading, when it named one.
    func reason(for feature: AppFeature) -> String? {
        degradedReadings.first { $0.feature == feature }?.providerText
    }

    func statuses(for feature: AppFeature) -> [ProviderReadingStatus] {
        degradedReadings.filter { $0.feature == feature }
    }
}

/// Which domains each connection can serve. This is the map the fallback policy consults before
/// it asks another provider, and the inspector consults before it promises a card.
enum ProviderDomainSupportMap {
    private static let polestarIDDomains: Set<ProviderDomain> = Set(ProviderDomain.allCases)

    private static let portalDomains: Set<ProviderDomain> = [
        .telemetry, .energy, .availability, .climate, .locks, .location,
        .exterior, .health, .odometer, .schedules, .charging
    ]

    private static let volvoDomains: Set<ProviderDomain> = [
        .telemetry, .energy, .availability, .climate, .locks, .engine,
        .honkFlash, .location, .exterior, .health, .odometer, .commands
    ]

    static func domains(for channel: ProviderChannel) -> [ProviderDomain] {
        switch channel {
        case .polestarID:
            return ordered(polestarIDDomains)
        case .polestarDataPortal:
            return ordered(portalDomains)
        case .polestarAugmented:
            return ordered(polestarIDDomains.union(portalDomains))
        case .volvo:
            return ordered(volvoDomains)
        }
    }

    static func supports(_ domain: ProviderDomain, on channel: ProviderChannel) -> Bool {
        switch channel {
        case .polestarID: return polestarIDDomains.contains(domain)
        case .polestarDataPortal: return portalDomains.contains(domain)
        case .polestarAugmented: return polestarIDDomains.contains(domain) || portalDomains.contains(domain)
        case .volvo: return volvoDomains.contains(domain)
        }
    }

    /// Domains the fallback channel can serve that the primary cannot. A non-empty result is
    /// the reason a portal-served refresh may still ask Polestar ID for software and
    /// connectivity instead of reporting them missing every time.
    static func domainsMissing(
        from primary: ProviderChannel, suppliedBy fallback: ProviderChannel
    ) -> [ProviderDomain] {
        domains(for: fallback).filter { !supports($0, on: primary) }
    }

    private static func ordered(_ domains: Set<ProviderDomain>) -> [ProviderDomain] {
        ProviderDomain.allCases.filter { domains.contains($0) }
    }
}
