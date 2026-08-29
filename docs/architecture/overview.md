# Architecture Overview

## Shape of the app

Hisingen is a single-process, single-target macOS app. There is no separate backend, no daemon, no XPC service. Everything below runs inside the one `Hisingen.app` process, coordinated from the main actor.

```
                     ┌────────────────────────────┐
                     │   UI (AppKit + SwiftUI)     │
                     │  StatusItemController       │
                     │  HisingenContentView & co.  │
                     └──────────────┬──────────────┘
                                    │ closures / render(data:error:authenticated:)
                     ┌──────────────▼──────────────┐
                     │        AppDelegate           │
                     │  (@MainActor, app shell)     │
                     └──────┬────────────────┬──────┘
                            │                │
              ┌─────────────▼───────┐  ┌─────▼──────────────┐
              │  RefreshCoordinator  │  │ Notifier /          │
              │  (@MainActor)        │  │ RemoteActionAuthorizer│
              └─────────┬────────────┘  └─────────────────────┘
                        │ VehicleProviding
              ┌─────────▼────────────┐
              │  PolestarAPI (actor) │   or   │  VolvoAPI (actor)  │
              │  + PolestarGRPC      │        │  (REST only)        │
              └─────────┬────────────┘        └──────────┬──────────┘
                        │                                 │
                Polestar cloud services            Volvo cloud services
                (OIDC, GraphQL, C3, PCCS)          (Volvo ID, Connected
                                                     Vehicle/Energy API)
```

`VehicleState` (Domain/) is the one shared model both providers produce and everything above `RefreshCoordinator` consumes. Nothing above the provider boundary knows whether it's looking at a Polestar or a Volvo.

## Layers and what's generic vs. brand-specific

| Layer | Files | Generic or brand-specific |
|---|---|---|
| UI (AppKit shell + SwiftUI views) | `UI/*.swift` | Generic — reads `VehicleState`/`VehicleCapabilityProfile`, brand only matters for a few explicit `isBrandVolvo` checks in `ControlsTabView` and badge text in `SettingsView` |
| App shell | `App/AppDelegate.swift`, `main.swift` | Generic — holds one `polestarAPI` and one `volvoAPI` instance, picks `activeProvider` from `Preferences.activeBrand` |
| Refresh / notifications / persistence | `Services/Refresh`, `Services/Notifications`, `Services/Persistence` | Generic — operate purely on `VehicleProviding`, `VehicleState`, and VIN strings |
| Domain model | `Domain/*.swift` | Generic — `VehicleState`, `VehicleCapabilityProfile`, `RemoteCommand`, `AppFeature` |
| Provider implementation | `Services/API/PolestarAPI.swift` + gRPC files | Polestar-specific |
| Provider implementation | `Services/API/VolvoAPI.swift` + `VolvoModels.swift` | Volvo-specific |
| Provider contract | `Services/API/VehicleProviding.swift` | The seam between the two — one protocol, two conformances |

Everything above `VehicleProviding` is written once and works for either brand. Everything below it — request construction, DTOs, wire-format decoding, capability heuristics, error mapping — is duplicated per provider because Polestar and Volvo genuinely have nothing in common at the wire level (GraphQL + hand-rolled gRPC vs. REST/OAuth2). See [providers.md](providers.md) for how clean that boundary actually is in practice.

## Where to go next

- [system-context.md](system-context.md) — what Hisingen talks to and why
- [components.md](components.md) — per-component responsibilities, state, isolation, failure modes
- [runtime.md](runtime.md) — what actually happens from process launch to first render
- [providers.md](providers.md) — the `VehicleProviding` seam in detail
- [capabilities.md](capabilities.md) — how "does this vehicle support X" is decided
- [refresh-system.md](refresh-system.md) — polling cadence, coalescing, backoff
- [motion-system.md](motion-system.md) — the shared `Motion` tokens, the menu-bar charging animation, and how Reduce Motion is resolved in one place
- [vehicle-motion.md](vehicle-motion.md) — the vehicle roll-in and angle transitions, and why they don't replay on a refresh
- [concurrency.md](concurrency.md) — actors, `@MainActor`, and the two places that use manual locks
- [technical-debt.md](technical-debt.md) — known rough edges, named honestly
