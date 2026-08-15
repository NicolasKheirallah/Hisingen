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
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    func selectCar(vin: String, features: FeatureSelection) async throws
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}
```

Nine methods. `PolestarAPI` and `VolvoAPI` each conform via a one-line `extension` in `VehicleProviding.swift` — the protocol itself carries no default implementations. This is the entire seam: everything above it (`RefreshCoordinator`, `AppDelegate`, all of `UI/`) only ever calls through this interface, and never imports a Polestar- or Volvo-specific type.

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

- **The UI does not purely gate on capability.** `ControlsTabView` checks `VehicleCapabilityProfile.permits(_:)` to decide what to *show*, but the actual enable/disable state of every control is a separate, hardcoded `isBrandVolvo` check — Polestar's remote-command buttons are `.disabled(true)` unconditionally regardless of what the capability profile or the `HISINGEN_EXPERIMENTAL_REMOTE` build flag say, and Volvo's charging controls are likewise hardcoded `.disabled(true)` for all brands because they aren't wired to a backend implementation yet. In other words, the provider-agnostic capability system correctly describes *what the vehicle can do*, but a separate, less clean layer decides *what the UI currently lets you try* — those two are not the same today. See [technical-debt.md](technical-debt.md).
- **`VolvoAPI.executeRemoteCommand` only implements 6 of `RemoteCommand`'s ~20 cases** (lock, unlock, climate start/stop, honk-flash, flash-lights); everything else throws `RemoteCommandError.unsupported` even though the capability profile may say a Volvo vehicle `.permits` it. The capability system describes support at the *vehicle* level; it doesn't yet know whether *this provider's client code* has actually implemented the corresponding call.
- **Volvo's remote-command response parsing is untyped** (`JSONSerialization` dictionary lookups for `invokeStatus`/`error.description`) while every read-path DTO in the same file is a strongly-typed `Decodable` struct — a sign the write-path response contract was less confidently understood when it was implemented. Not visible from the `VehicleProviding` seam, but worth knowing if you're extending Volvo's command support.

## Adding a third provider

See [development/adding-a-provider.md](../development/adding-a-provider.md) for what implementing `VehicleProviding` for a new brand actually requires, and which of the "shared" pieces above you get for free.
