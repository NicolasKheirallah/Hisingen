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

- **Historical note, now fixed:** this section used to say the UI's enable/disable state was a separate hardcoded `isBrandVolvo` check independent of the capability system, and that Polestar's remote-command buttons were `.disabled(true)` unconditionally behind a `HISINGEN_EXPERIMENTAL_REMOTE` build flag. Neither is true of the current code. ADR-0009 removed that flag entirely, and `ControlsTabView.isDisabled(_:)`/`cardOpacity(_:)` now route every command's enable/disable state through one `CapabilityGate.availability(for:state:brand:enabledFeatures:commandInProgress:)` call — the same three-layer check (provider implementation × vehicle capability profile × busy state) for both brands. `isBrandVolvo` still exists in `ControlsTabView`, but only for presentation choices (which label/section to show), not for gating whether a control is enabled.
- **`VolvoAPI.executeRemoteCommand` implements 10 of `RemoteCommand`'s ~20 cases** (lock, lock-reduced-guard, unlock, climate start/stop, engine start/stop, honk-flash, flash-lights, honk); everything else throws `RemoteCommandError.unsupported` even though the capability profile may say a Volvo vehicle `.permits` it. The capability system describes support at the *vehicle* level; it doesn't yet know whether *this provider's client code* has actually implemented the corresponding call — this part of the original observation still holds, only the exact count was stale.
- **Volvo's remote-command response parsing is untyped** (`JSONSerialization` dictionary lookups for `invokeStatus`/`error.description`) while every read-path DTO in the same file is a strongly-typed `Decodable` struct — a sign the write-path response contract was less confidently understood when it was implemented. Not visible from the `VehicleProviding` seam, but worth knowing if you're extending Volvo's command support.

## Adding a third provider

See [development/adding-a-provider.md](../development/adding-a-provider.md) for what implementing `VehicleProviding` for a new brand actually requires, and which of the "shared" pieces above you get for free.
