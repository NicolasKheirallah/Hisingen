import Foundation

/// The one place that knows which Volvo command endpoint a `RemoteCommand` posts to, and which
/// advertised names in the car's `/commands` list mean that endpoint exists.
///
/// These two facts used to live apart: `dispatchCommand` held a switch of endpoint names, and the
/// capability probe tested a second hand-written list of strings. A typo in either made the app
/// promise a control that fails at dispatch, and nothing compared them. Keeping the pair in one
/// table lets a single test assert they agree.
enum VolvoCommandCatalog {
    /// The endpoints the app can invoke. A kind rather than a `RemoteCommand` because two cases
    /// carry arguments (`startClimate`, `startEngine`) and the catalog only cares which endpoint
    /// they post to.
    enum Kind: CaseIterable {
        case lock, unlock, lockReducedGuard
        case climateStart, climateStop
        case engineStart, engineStop
        case honkAndFlash, flash, honk
    }

    struct Entry {
        /// The final path segment of the invocation endpoint.
        let endpoint: String
        /// Names the `/commands` list may report for it. The list gives a display `command` and
        /// an `href`; `VolvoCommandDTO.normalizedName` prefers the `href` tail, and both spellings
        /// are accepted here so a car that reports either still counts as supporting the command.
        let advertisedNames: [String]
    }

    /// Endpoints the app implements for Volvo. Volvo's public v2 API only offers these; a car
    /// advertising anything else (a sunroof, for example) has no invocation path in Hisingen.
    static func entry(for kind: Kind) -> Entry {
        switch kind {
        case .lock: return Entry(endpoint: "lock", advertisedNames: ["lock"])
        case .unlock: return Entry(endpoint: "unlock", advertisedNames: ["unlock"])
        case .lockReducedGuard:
            return Entry(endpoint: "lock-reduced-guard", advertisedNames: ["lock-reduced-guard"])
        case .climateStart:
            return Entry(endpoint: "climatization-start", advertisedNames: ["climatization-start"])
        case .climateStop:
            return Entry(endpoint: "climatization-stop", advertisedNames: ["climatization-stop"])
        case .engineStart: return Entry(endpoint: "engine-start", advertisedNames: ["engine-start"])
        case .engineStop: return Entry(endpoint: "engine-stop", advertisedNames: ["engine-stop"])
        case .honkAndFlash:
            // The list reports `HONK_AND_FLASH`, whose href ends `/honk-flash`; older payloads
            // spell it out in full.
            return Entry(endpoint: "honk-flash", advertisedNames: ["honk-flash", "honk-and-flash"])
        case .flash: return Entry(endpoint: "flash", advertisedNames: ["flash"])
        case .honk: return Entry(endpoint: "honk", advertisedNames: ["honk"])
        }
    }

    /// The endpoint a remote command posts to, or nil when Volvo cannot run it.
    static func kind(for command: RemoteCommand) -> Kind? {
        switch command {
        case .lock: return .lock
        case .unlock: return .unlock
        case .lockReducedGuard: return .lockReducedGuard
        case .startClimate: return .climateStart
        case .stopClimate: return .climateStop
        case .startEngine: return .engineStart
        case .stopEngine: return .engineStop
        case .honkAndFlash: return .honkAndFlash
        case .flashLights: return .flash
        case .honkHorn: return .honk
        default: return nil
        }
    }

    static func endpoint(for command: RemoteCommand) -> String? {
        kind(for: command).map { entry(for: $0).endpoint }
    }

    /// Whether a car advertising `names` offers the kind.
    static func isAdvertised(_ kind: Kind, in names: Set<String>) -> Bool {
        entry(for: kind).advertisedNames.contains { names.contains($0) }
    }
}
