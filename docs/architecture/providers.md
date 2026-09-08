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
     hand-rolled gRPC (C3, PCCS)  Connected Vehicle/Energy API
```

## The `VehicleProviding` protocol

```swift
protocol VehicleProviding: Sendable {
    var brand: VehicleBrand { get }
    var cars: [CarSummary] { get async }
    var hasWarmSession: Bool { get async }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}
```

`PolestarAPI` and `VolvoAPI` are the two production adapters at this seam. Refresh, vehicle switching, and garage scanning fetch directly by VIN without a preceding selection call. Polestar prepares identity, artwork, and owner information inside the fetch implementation; discovery retains identities for every returned vehicle. Volvo already loads details by VIN. Explicit metadata reload remains a separate operation.

`VehicleSessionController` owns the user's selected brand and VIN. `SessionManager.restore` owns stored credential resolution, Volvo configuration, and authentication fallback for foreground refresh, connection tests, and dormant-brand scans. Routine resume prefers the stored token; a credential change prefers a newly stored Polestar password. Only authentication failures permit password fallback, and a successful password sign-in deletes the stored password. Interactive browser sign-in remains in `SignInCoordinator`.

## What's genuinely shared

- `VehicleState`, `VehicleCapabilityProfile`/`VehicleProbedCapabilities`, `VehicleModelFamily`, `RemoteCommand`, `AppFeature`, `VehicleServiceError` — the entire `Domain/` layer.
- `RefreshCoordinator`, `Notifier`, `ChargingTransitionDetector`, `VehicleStateStore`, `RemoteActionAuthorizer` — every generic service.
- All of `UI/` — with the one deliberate exception below.

## What remains provider-specific

- Authentication mechanics (OIDC scraping vs. OAuth2 PKCE), token storage shape (single refresh token vs. a 3-field bundle), request construction, DTOs, wire-format decoding (GraphQL/protobuf vs. JSON), capability-probing heuristics, and error-type definitions (`PolestarError` vs. `VolvoError`) — each fully separate, living in `PolestarAPI.swift`/`PolestarGRPC*.swift` vs. `VolvoAPI.swift`/`VolvoModels.swift`.
- Both funnel into the same `VehicleServiceError` via an `asVehicleServiceError` bridge, so the generic layer only ever handles one error type regardless of provider.

## What's backend-specific (inside one brand)

Polestar itself isn't one backend — `PolestarAPI` talks to at least four distinct services (Polestar ID/OIDC, the GraphQL gateway, the C3 gRPC backend, and PCCS/Chronos), because Hisingen is reproducing what the official mobile app does across Polestar's actual internal service topology, not a single documented API. See [api/polestar.md](../api/polestar.md).

## Where the abstraction isn't clean today

Documented honestly rather than smoothed over:

- **Historical note, now fixed:** this section used to say the UI's enable/disable state was a separate hardcoded `isBrandVolvo` check independent of the capability system, and that Polestar's remote-command buttons were `.disabled(true)` unconditionally behind a `HISINGEN_EXPERIMENTAL_REMOTE` build flag. Neither is true of the current code. ADR-0009 removed that flag entirely, and `ControlsTabView.isDisabled(_:)`/`cardOpacity(_:)` now route every command's enable/disable state through one `CapabilityGate.availability(for:state:brand:enabledFeatures:commandInProgress:)` call — the same three-layer check (provider implementation × vehicle capability profile × busy state) for both brands. `isBrandVolvo` still exists in `ControlsTabView`, but only for presentation choices (which label/section to show), not for gating whether a control is enabled.
- **`VolvoAPI.executeRemoteCommand` implements 10 of `RemoteCommand`'s ~20 cases** (lock, lock-reduced-guard, unlock, climate start/stop, engine start/stop, honk-flash, flash-lights, honk); everything else throws `RemoteCommandError.unsupported` even though the capability profile may say a Volvo vehicle `.permits` it. The capability system describes support at the *vehicle* level; it doesn't yet know whether *this provider's client code* has actually implemented the corresponding call — this part of the original observation still holds, only the exact count was stale.
- **Volvo's remote-command response parsing is untyped** (`JSONSerialization` dictionary lookups for `invokeStatus`/`error.description`) while every read-path DTO in the same file is a strongly-typed `Decodable` struct — a sign the write-path response contract was less confidently understood when it was implemented. Not visible from the `VehicleProviding` seam, but worth knowing if you're extending Volvo's command support.

## Adding a third provider

See [development/adding-a-provider.md](../development/adding-a-provider.md) for what implementing `VehicleProviding` for a new brand actually requires, and which of the "shared" pieces above you get for free.

### Polestar authentication lifecycle

Interactive web and command grants invalidate earlier work before issuing a new PKCE request. Session and command generations prevent late token responses from overwriting a newer login. Background restoration waits until the interactive web flow has finished or been cancelled.

Command access is enabled only after authenticated userinfo responses identify the same account for both clients: matching subjects, or matching verified email addresses when subjects are pairwise. Identity checks fail closed if neither comparison is available. Stored command sessions are verified again after restoration. Refresh-token rotation is retained in memory when verification or Keychain persistence is temporarily unavailable; storage failures are reported to the caller.

Sign-out clears local tokens, passwords, pending requests, and displayed account state before attempting remote revocation. Revocation uses a separate transport and cannot clear a later login.

The embedded browser owns an isolated cookie store per attempt. If a website login lands on polestar.com without returning the app's callback, it retries the original authorization URL once using the same cookies, state, and PKCE challenge. This addresses the lost browser handoff reported in [issue #19](https://github.com/NicolasKheirallah/Hisingen/issues/19); confirmation against an affected account remains necessary. A stored password alone does not mark the Settings account as connected.

### Polestar capability reads

Optional reads check the session generation before returning data or updating caches. Cancellation does not create capability backoff, and a capability remains unavailable while its backoff is active. Exterior status, trip meters, connectivity, and charging-current limits use 30-second caches; climate status uses 15 seconds, schedules use 60 seconds, and slower metadata retains longer lifetimes. Feature aliases share the cache for the underlying reading.

Location and weather endpoint fallbacks stop on authentication, rate limiting, cancellation, and transport failures. Unsupported endpoints can try an alternative. HTTP 429 preserves Retry-After. Persistent UNIMPLEMENTED records are scoped by backend URL, VIN, and RPC path, expire after 24 hours, and do not inherit the former unscoped records.
