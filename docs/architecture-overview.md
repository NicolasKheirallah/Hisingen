# Hisingen runtime architecture

## Composition and state ownership

`AppDelegate` is the composition root and lifecycle owner. It constructs provider clients, persistence, notifications, UI/status-item controllers, the `RefreshCoordinator`, and the `CommandCoordinator`. The active brand selects exactly one `VehicleProviding` implementation at a time (`PolestarAPI` or `VolvoAPI`).

`RefreshCoordinator` is `@MainActor` and owns the active snapshot, vehicle selection, refresh timer, retry/rate-limit state, environment observers, and live-stream task. Every refresh/session/selection operation has a generation value; completions from superseded work are discarded before state publication.

## Main flows

1. Launch restores a cached snapshot, builds the UI, then asks `SessionManager`/`RefreshCoordinator` to restore the active provider session.
2. Refresh obtains/restores credentials, resolves the selected VIN, fetches provider state, merges safe last-known fields, persists it through `VehicleStateStore`/`VehicleDatabase`, and publishes it to AppKit/SwiftUI, notifications, Spotlight, and diagnostics.
3. A remote command passes capability/settings gating, explicit user/device authorization, a post-authorization VIN/provider/session recheck, provider execution, audit logging, an in-memory optimistic patch, and one authoritative delayed refresh.
4. Sign-out cancels work, clears local vehicle data first, then attempts remote revocation. Sleep/network loss cancels active work; wake/connectivity restoration starts a bounded refresh/recovery path.

## Boundaries

- `Services/API`: provider-specific authentication, DTO decoding, endpoint behavior, transport, and error mapping.
- `Domain`: vehicle state, capabilities, calculations, and remote-command model.
- `Services/Refresh` and `Services/Coordination`: application state transitions and command orchestration.
- `Services/Persistence`: Keychain, SQLite history/cache, preferences, and diagnostic retention.
- `UI`: rendering and direct interaction only; it asks the app shell/coordinators to perform side effects.

The architecture deliberately avoids a shared provider-wire abstraction: Volvo REST/OAuth and Polestar GraphQL/gRPC differ materially. Shared behavior is limited to domain models and the `VehicleProviding` contract.
