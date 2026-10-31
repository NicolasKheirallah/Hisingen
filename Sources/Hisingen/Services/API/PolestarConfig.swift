import Foundation

/// The fixed values Hisingen's Polestar support depends on: hosts, OAuth clients and the
/// timings tied to them. Gathered here so a change on Polestar's side is one edit with its
/// reasoning next to it. `PolestarAPI` exposes these through its own properties.
enum PolestarConfig {
    // MARK: Hosts

    /// Account and vehicle data (`getConsumerCarsV2`, telematics).
    static let apiBaseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!
    /// Public, unauthenticated lookups such as vehicle renders.
    static let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
    /// The app's own backend, used for the secondary (VDMS) discovery source.
    static let appBackendURL = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!
    /// The identity provider (PingFederate).
    static let oidcProviderURL = URL(string: "https://polestarid.eu.polestar.com")!

    // MARK: OAuth clients

    /// The polestar.com web client. The mobile-app client (`lp8dyrd_10`,
    /// `polestar-explore://explore.polestar.com`) authenticates fine but its token is rejected
    /// by `pc-api.polestar.com/mystar-v2` with `UnauthorizedException`, so vehicle discovery
    /// returns nothing and the app has no car to talk about – verified live against a real
    /// account. The `getConsumerCarsV2` query only accepts this client.
    static let webClientID = "l3oopkc_10"
    static let webRedirectURL = URL(string: "https://www.polestar.com/sign-in-callback")!
    /// `customer:attributes:write` is what the C3 `ota_mobcache.SchedulerService` write RPCs
    /// require. This client grants it on request – adding it does not disturb discovery.
    static let webScope = "openid profile email customer:attributes customer:attributes:write"

    /// Remote commands are gated on a *client-id allowlist*, separate from scope. C3 spells the
    /// rule out when it refuses: `Client id l3oopkc_10 is not a required client id: [… lp8dyrd_10 …]`.
    /// The web client above can list vehicles but cannot invoke; this one can invoke but is
    /// rejected by `mystar-v2` for reads. Neither is sufficient alone, so the app holds a token
    /// from each and picks per call. Verified live: `Lock` via C3 with this client returns
    /// `outcome = accepted`.
    static let commandClientID = "lp8dyrd_10"
    static let commandRedirectURL = URL(string: "polestar-explore://explore.polestar.com")!

    // MARK: Timings

    /// How long VDMS discovery stands down after a failure no retry would fix (a 426, a schema
    /// mismatch, a rejected token).
    static let discoveryBackoffInterval: TimeInterval = 24 * 60 * 60

    /// Token renewal margin: a tenth of the lifetime, clamped so a five-minute command token is
    /// not renewed for most of its life and a long one still absorbs clock and transit skew.
    static let renewalMarginFraction = 0.1
    static let renewalMarginRange: ClosedRange<TimeInterval> = 5...60
    /// Margin used when the lifetime is unknown.
    static let defaultRenewalMargin: TimeInterval = 60
}
