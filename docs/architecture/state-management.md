# State Management

## Where state actually lives

| Kind of state | Owner | Storage | Scope |
|---|---|---|---|
| Application state (loading/error/authenticated flags) | `AppDelegate` | In-memory only | Process lifetime |
| Refresh/polling state (timer, backoff, generation) | `RefreshCoordinator` | In-memory only | Process lifetime, reset on brand switch (a fresh `RefreshCoordinator` is constructed) |
| Authentication tokens | `PolestarAPI` / `VolvoAPI` (actor-isolated) | Access token: in-memory only. Refresh token: Keychain. | Per brand |
| Non-secret settings (VIN, nicknames, feature flags, theme, notification toggles, etc.) | `Preferences` | `UserDefaults` | Per brand where relevant (VIN, theme), global otherwise |
| Vehicle telemetry cache | `VehicleStateStore` | `UserDefaults` (JSON-encoded, 7-day TTL) | Per VIN |
| Charging state-machine baseline | `VehicleStateStore` (same store as above) | `UserDefaults`, 7-day TTL | Per VIN |
| Capability observations | `VehicleState.probedCapabilities` — travels with the cached snapshot | `UserDefaults` (embedded in the cached `VehicleState`) | Per VIN, 6-hour staleness window on top of the store's 7-day TTL |
| UI state (selected tab, settings-mode flag, scroll position) | `StatusItemController` / SwiftUI `@State` | In-memory only | Popover lifetime |
| Reverse-geocode cache | `ReverseGeocoder` (actor) | In-memory only | Process lifetime |
| Update-check result | `UpdateChecker` + `Preferences` | `UserDefaults` (`available_update_version`, `last_successful_update_check`) | Global |

## Who is allowed to mutate what

- **Tokens** are only ever written by the owning provider actor (`PolestarAPI`/`VolvoAPI`) — no other type calls the Keychain token-save methods directly except `AppDelegate.resumeStoredSession()` (read-only) and the sign-out path.
- **`Preferences`** is a `@MainActor enum` with static computed properties — anything on the main actor can read or write any preference. There's no per-feature access control; this is a deliberate simplicity choice appropriate for a single-user local app, not an oversight.
- **`VehicleStateStore`** is written to by exactly two callers: `RefreshCoordinator.apply(_:latency:)` (after every successful fetch) and `Notifier.vehicleStateDidUpdate(_:)` (after every charging-baseline evaluation, even when the resulting notification is suppressed). Both are `@MainActor`, so writes never race — but see [technical-debt.md](technical-debt.md) for why that's an assumption the type system doesn't enforce.
- **`RefreshCoordinator`'s own state** (timer, generation, failure count) is private and mutated only from within its own `@MainActor` methods.
- **UI state** is owned by whichever SwiftUI view declares it (`@State`) or by `StatusItemController` (plain `var` properties); it's never shared outside the popover/menu-bar chain.

## Shared mutable state worth calling out

- `AppDelegate.latest: VehicleState?` is the single source of truth for "what does the UI currently show." It's updated from `RefreshCoordinator.onState`, from cached-snapshot lookups on launch/vehicle-switch, and — unusually — directly by `performRemoteCommand` for four commands (`startClimate`, `stopClimate`, `lock`, `unlock`), which optimistically patch `latest` with the expected post-command state before the next real refresh confirms it. This is a deliberate "instant feedback" UX choice, not a bug, but it does mean `latest` can briefly disagree with what the backend would report if polled at that exact moment. See [domain/vehicle.md](../domain/vehicle.md#remote-command-optimistic-updates).
- `StatusItemController.cachedSnapshots: [String: VehicleState]` is a second, UI-layer cache of per-VIN state (separate from `VehicleStateStore`), used to instantly show the other brand's or another vehicle's last-known data when switching without waiting on a `UserDefaults` round trip. It's populated from `VehicleStateStore` on demand and from every `onState`/`onCars` callback — effectively a hot in-memory mirror of the cold `UserDefaults`-backed store.
- `InMemorySecretCache` (inside `Keychain.swift`) is process-global and shared across every `KeychainStore` instance, keyed only by Keychain *account* name, not by `service` — see [technical-debt.md](technical-debt.md) for the collision risk this creates when tests construct isolated `KeychainStore`s with unique service names but reuse the same static account constants.

## Diagram: state ownership by scope

```mermaid
flowchart TB
    subgraph Process["Process lifetime, in-memory only"]
        AD["AppDelegate.latest / lastError / sessionValid"]
        RC["RefreshCoordinator: task, generation, backoff"]
        TOK["Provider actors: access token, expiry"]
        GEO["ReverseGeocoder cache"]
    end
    subgraph Disk["UserDefaults, survives restart"]
        PREF["Preferences: VIN, nicknames, features, theme, toggles"]
        VSS["VehicleStateStore: VehicleState + ChargingBaseline per VIN, 7-day TTL"]
    end
    subgraph Keychain["Keychain, survives restart, OS-protected"]
        KC["Refresh tokens, Polestar password, Volvo client secret + API key"]
    end
    subgraph UI["Popover lifetime"]
        SC["StatusItemController.cachedSnapshots (hot mirror of VSS)"]
        SUI["SwiftUI @State: selected tab, settings mode"]
    end

    TOK -->|refresh token persisted| KC
    RC -->|save(state) after every fetch| VSS
    VSS -->|snapshot(for:) on launch/switch| SC
    AD -->|render| SC
    SC -->|rootView reassignment| SUI
```
