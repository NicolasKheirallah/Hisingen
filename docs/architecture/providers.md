# Provider Architecture

```
                Shared Vehicle Domain
           (VehicleState, VehicleCapabilityProfile,
            RemoteCommand, AppFeature)
                        │
                VehicleProviding protocol
                   /                \
          actor PolestarAPI      actor VolvoAPI
          + actor PolestarGRPC   (REST only)
                 │                       │
     Polestar OIDC / GraphQL /    Volvo ID OAuth2 /
     gRPC Swift + hand-written codecs  Connected Vehicle/Energy API
```

## The `VehicleProviding` protocol

```swift
protocol RemoteCommandExecuting: Sendable {
    var brand: VehicleBrand { get }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}

protocol VehicleProviding: RemoteCommandExecuting {
    var cars: [CarSummary] { get async }
    var hasWarmSession: Bool { get async }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws
    func prepareSession() async throws
    var acceptsStoredPasswordSignIn: Bool { get async }
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
}
```

`PolestarAPI`, `PolestarDataPortalAPI`, `PolestarAugmentedProvider`, and `VolvoAPI` implement this seam. Each adapter resolves its stored credentials internally. Command-only consumers depend on `RemoteCommandExecuting`; refresh and session consumers use `VehicleProviding`. `VehicleMetadataProviding` is a separate optional seam for prepared identity and consumer telemetry supplements. Live streams carry domain `VehicleBatteryReading` values rather than a gRPC wire type. `ProviderCommandCatalog`, derived from the executor's brand, is the conservative implementation map used by `CapabilityGate` and provider dispatch guards. Vehicle capability and application policy remain separate runtime gates.

`VehicleSessionController` owns the user's selected brand and VIN. `SessionManager.restore` owns stored credential resolution, Volvo configuration, and authentication fallback for foreground refresh, connection tests, and dormant-brand scans. Routine resume prefers the stored token; a credential change prefers a newly stored Polestar password. Only authentication failures permit password fallback, and a successful password sign-in deletes the stored password. Interactive browser sign-in remains in `SignInCoordinator`.

## What's genuinely shared

- `VehicleState`, `VehicleCapabilityProfile`/`VehicleProbedCapabilities`, `VehicleModelFamily`, `RemoteCommand`, `AppFeature`, `VehicleServiceError`: the entire `Domain/` layer.
- `RefreshCoordinator`, `Notifier`, `ChargingTransitionDetector`, `VehicleStateStore`, `RemoteActionAuthorizer`: every generic service.
- All of `UI/`, with the one deliberate exception below.

## Polestar gRPC transport

The default transport uses gRPC Swift 2 over NIO HTTP/2, with a client scoped to each call. Hand-written codecs still encode and decode Polestar's undocumented messages. Unary-style reads wait for final status; selected long-lived streams intentionally return their first validated snapshot. Commands are not automatically replayed. An explicit reply followed by deadline status 4 reaches the command parser, while other failing final statuses override it; telemetry, not that reply, confirms the vehicle state. See [the transport record](polestar-trailers-2026-10-31.md).

## What remains provider-specific

- Authentication mechanics (OIDC scraping vs. OAuth2 PKCE), token storage shape (single refresh token vs. a 3-field bundle), request construction, DTOs, wire-format decoding (GraphQL/protobuf vs. JSON), capability-probing heuristics, and error-type definitions (`PolestarError` vs. `VolvoError`), each fully separate, living in `PolestarAPI.swift`/`PolestarGRPC*.swift` vs. `VolvoAPI.swift`/`VolvoModels.swift`.
- Both funnel into the same `VehicleServiceError` via an `asVehicleServiceError` bridge, so the generic layer only ever handles one error type regardless of provider.

## What's backend-specific (inside one brand)

Polestar itself isn't one backend; `PolestarAPI` talks to at least four distinct services (Polestar ID/OIDC, the GraphQL gateway, the C3 gRPC backend, and PCCS/Chronos), because Hisingen is reproducing what the official mobile app does across Polestar's actual internal service topology, not a single documented API. See [api/polestar.md](../api/polestar.md).

## Where the abstraction isn't clean today

Documented honestly rather than smoothed over:

- UI availability and provider dispatch now consult the same `ProviderCommandCatalog`; adding a dispatch case without adding catalog support leaves it safely unavailable, and provider entry points also reject anything absent from the catalog. This preserves ADR-0009's separation between compiled implementation, provider support, vehicle capability, and application policy.
- **Volvo's remote-command response parsing is untyped** (`JSONSerialization` dictionary lookups for `invokeStatus`/`error.description`) while every read-path DTO in the same file is a strongly-typed `Decodable` struct, a sign the write-path response contract was less confidently understood when it was implemented. Not visible from the `VehicleProviding` seam, but worth knowing if you're extending Volvo's command support.

## Adding a third provider

See [development/adding-a-provider.md](../development/adding-a-provider.md) for what implementing `VehicleProviding` for a new brand actually requires, and which of the "shared" pieces above you get for free.

### Polestar authentication lifecycle

Interactive web and command grants invalidate earlier work before issuing a new PKCE request. Session and command generations prevent late token responses from overwriting a newer login. Background restoration waits until the interactive web flow has finished or been cancelled.

Password and web login run in an isolated candidate session. The facade publishes tokens and the discovered garage together only while the candidate still owns the session and authorization generation. A failed candidate leaves the working session intact. OIDC discovery, GraphQL transport, discovery merging, and artwork request ownership have separate components; the facade owns publication and reset.

Command access is enabled only after authenticated userinfo responses identify the same account for both clients: matching subjects, or matching verified email addresses when subjects are pairwise. Identity checks fail closed if neither comparison is available. Stored command sessions are verified again after restoration. Refresh-token rotation is retained in memory when verification or Keychain persistence is temporarily unavailable; storage failures are reported to the caller.

Sign-out clears local tokens, passwords, pending requests, and displayed account state before attempting remote revocation. Revocation uses a separate transport and cannot clear a later login.

The embedded browser owns an isolated cookie store per attempt. If a website login lands on polestar.com without returning the app's callback, it retries the original authorization URL once using the same cookies, state, and PKCE challenge. This addresses the lost browser handoff reported in [issue #19](https://github.com/NicolasKheirallah/Hisingen/issues/19); confirmation against an affected account remains necessary. A stored password alone does not mark the Settings account as connected.

### Polestar capability reads

Optional reads check the session generation before returning data or updating caches. Cancellation does not create capability backoff, and a capability remains unavailable while its backoff is active. Exterior status, trip meters, connectivity, and charging-current limits use 30-second caches; climate status uses 15 seconds, schedules use 60 seconds, and slower metadata retains longer lifetimes. Feature aliases share the cache for the underlying reading.

Typed reading definitions bind the reading key to its payload type. Shared probes retain their original request-start time; cancelling one waiter does not cancel other waiters. Command invalidation advances a per-VIN cache generation so an earlier probe cannot repopulate invalidated values. Snapshot assemblers preserve source, request-start time, and cache status for each reading. Charge-target and current-limit confirmation use their own endpoint observations; a fresh battery request cannot confirm a cached target setting.

Data Portal request attempts reserve their quota slot before transport, including token grants and retries. Planning keeps requested battery data first and rotates optional domains within the remaining budget. VIN denials are scoped to credentials and vehicle, while credential changes invalidate tokens, garage, and cache state. Fetch planning and snapshot mapping are pure components with explicit clock and timezone inputs.

Location and weather endpoint fallbacks stop on authentication, rate limiting, cancellation, and transport failures. Unsupported endpoints can try an alternative. HTTP 429 preserves Retry-After. Persistent UNIMPLEMENTED records are scoped by backend URL, VIN, and RPC path, expire after 24 hours, and do not inherit the former unscoped records.
