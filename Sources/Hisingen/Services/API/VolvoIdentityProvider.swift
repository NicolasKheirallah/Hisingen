import Foundation

/// The two Volvo ID sign-in systems. Volvo is moving every developer application from the
/// original server to a new one and says the original stops accepting applications after
/// 31 January 2027. The client ID says which system an application belongs to: new ones start
/// `vid-` (the community library documents `vid-dc-`, but a client issued by the new portal
/// starts `vid-dcr-`, so only `vid-` is safe to key on), original ones `dc-`. Tokens, scopes and
/// endpoints differ, so every request that
/// touches sign-in asks this type instead of assuming one host.
enum VolvoIdentityProvider: String, Sendable {
    case legacy
    case volvoID

    static let volvoIDClientPrefix = "vid-"

    init(clientID: String?) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self = trimmed.hasPrefix(Self.volvoIDClientPrefix) ? .volvoID : .legacy
    }

    var authorizeURL: URL {
        switch self {
        case .legacy:
            URL(string: "https://volvoid.eu.volvocars.com/as/authorization.oauth2")!
        case .volvoID:
            URL(string: "https://auth.volvocars.com/realms/volvocars/protocol/openid-connect/auth")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .legacy:
            URL(string: "https://volvoid.eu.volvocars.com/as/token.oauth2")!
        case .volvoID:
            URL(string: "https://auth.volvocars.com/realms/volvocars/protocol/openid-connect/token")!
        }
    }

    /// The original system has no documented revocation endpoint, so it gets none rather than a
    /// guessed one.
    var revocationURL: URL? {
        switch self {
        case .legacy:
            nil
        case .volvoID:
            URL(string: "https://auth.volvocars.com/realms/volvocars/protocol/openid-connect/revoke")!
        }
    }

    /// Read scopes only the new system knows. The original server rejects the whole
    /// authorization with `invalid_scope` for an unknown scope, so these are added per system,
    /// and never to the `core` tier, which must stay the floor either system accepts.
    /// `conve:navigation` is deliberately not requested: nothing reads it, and it can expose
    /// destinations.
    var additionalReadScopes: [String] {
        // `conve:connectivity_status` and `conve:environment` used to be requested here. Nothing
        // reads either endpoint (connectivity status is Enterprise-only, `/environment` is
        // documented as 404), and Volvo rejects the *whole* authorization with `invalid_scope`
        // when one requested scope is unapproved — so asking for them could push an otherwise
        // valid sign-in down a tier. Request only scopes that gate something.
        []
    }
}
