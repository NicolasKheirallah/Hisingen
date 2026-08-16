# Hisingen Technical Documentation

Hisingen is a native macOS menu-bar application (AppKit + SwiftUI, `LSUIElement` accessory app) that monitors and, on an opt-in experimental basis, controls Polestar and Volvo vehicles. It has no backend of its own: every request goes straight from the user's Mac to Polestar's or Volvo's own cloud services, using credentials the user supplies.

This directory is the engineering documentation. The root [README.md](../README.md) stays user-facing (features, screenshots, installation); everything about *how the app is built* lives here.

## How the codebase is organized

```
Sources/Hisingen/
├── App/          AppDelegate, main.swift — app shell, launch sequence, menu, URL handling
├── Domain/       Brand-agnostic vehicle model: VehicleState, VehicleCapabilities, RemoteCommand, AppFeature
├── Services/
│   ├── API/          PolestarAPI, PolestarGRPC*, VolvoAPI — the two VehicleProviding implementations
│   ├── Refresh/       RefreshCoordinator — polling, backoff, coalescing
│   ├── Persistence/   Keychain, Preferences, VehicleStateStore
│   ├── Notifications/ Notifier, ChargingTransitionDetector
│   ├── Security/      RemoteActionAuthorizer, VolvoSignInPresenter
│   ├── Location/      ReverseGeocoder
│   └── Updates/       UpdateChecker
├── Support/      Format, L10n, PKCE — small stateless helpers
└── UI/           StatusItemController (AppKit shell) + SwiftUI views
```

41 Swift files, ~15,000 lines. See [architecture/components.md](architecture/components.md) for what each piece owns.

## Main architectural concepts

- **One shared vehicle domain, two providers.** `VehicleState`, `VehicleCapabilities`, `RemoteCommand` (Domain/) are brand-agnostic. `PolestarAPI` and `VolvoAPI` each implement the `VehicleProviding` protocol and map their own wire formats into that shared domain. See [architecture/providers.md](architecture/providers.md).
- **Runtime capability probing, not model-name guessing.** Whether a vehicle supports a feature is a mix of a conservative static per-model table and live observations from real API responses, merged with a 6-hour staleness window. A failed request does not automatically mean "unsupported." See [architecture/capabilities.md](architecture/capabilities.md).
- **`RefreshCoordinator` owns the polling loop.** One `@MainActor` class serializes timer, manual, wake, and network-recovery refreshes into a single in-flight task per generation, so none of them race each other. See [architecture/refresh-system.md](architecture/refresh-system.md).
- **The Polestar backend is fully mapped.** [api/polestar-backend-map.md](api/polestar-backend-map.md) records every host, service, method and protobuf field observed against a live vehicle — including the two-OAuth-client allowlist rule that remote commands depend on.
- **Read-only unless you opt in.** No remote feature is enabled by default, and every non-routine command needs Touch ID. Dispatch is compiled into all builds as of [ADR-0009](adr/0009-remote-commands-compiled-into-all-builds.md), which removed the former `HISINGEN_EXPERIMENTAL_REMOTE` flag. See [domain/vehicle.md](domain/vehicle.md) and [security/threat-model.md](security/threat-model.md).
- **VIN-scoped state everywhere it matters.** Caches, capability observations, charging baselines, and notification dedup state are all keyed by VIN. Credentials are keyed by brand, not by VIN — see [security/keychain.md](security/keychain.md).

## Supported vehicle providers

| Provider | Auth | API family | File |
|---|---|---|---|
| Polestar | Scraped PingFederate/OIDC login (undocumented) | GraphQL + hand-rolled gRPC (C3 / PCCS-Chronos) | [api/polestar.md](api/polestar.md) |
| Volvo | OAuth2 PKCE against Volvo ID (documented) | REST — Connected Vehicle API v2, Energy API v2, Location API v1 | [api/volvo.md](api/volvo.md) |

Both are documented in detail, including which parts are officially documented by the vendor versus reverse-engineered — see [api/overview.md](api/overview.md#api-confidence).

## Where things live

- API integrations: `Sources/Hisingen/Services/API/` — see [api/](api/)
- Domain logic: `Sources/Hisingen/Domain/` — see [domain/](domain/)
- Capability/refresh/concurrency architecture: [architecture/](architecture/)
- Security posture, threat model, privacy: [security/](security/)
- Contributor workflow: [development/](development/)
- Test suite and fixtures: [testing/](testing/)
- Build, CI, and release process: [operations/](operations/)
- Recorded architectural decisions: [adr/](adr/)

## Reading paths

**New developer**
```
development/getting-started.md
→ architecture/overview.md
→ development/repository-layout.md
→ architecture/runtime.md
→ testing/strategy.md
```

**Working on vehicle APIs**
```
api/overview.md
→ api/authentication.md
→ architecture/providers.md
→ architecture/capabilities.md
→ api/polestar.md (+ api/polestar-backend-map.md) or api/volvo.md
```

**Maintainer**
```
architecture/overview.md
→ security/overview.md
→ operations/ci.md
→ operations/releases.md
→ adr/README.md
```

## Documentation index

- **architecture/** — [overview](architecture/overview.md), [theme-and-caching](architecture/theme-and-caching-architecture.md), [system-context](architecture/system-context.md), [components](architecture/components.md), [runtime](architecture/runtime.md), [concurrency](architecture/concurrency.md), [state-management](architecture/state-management.md), [data-flow](architecture/data-flow.md), [persistence](architecture/persistence.md), [capabilities](architecture/capabilities.md), [providers](architecture/providers.md), [refresh-system](architecture/refresh-system.md), [technical-debt](architecture/technical-debt.md)
- **api/** — [overview](api/overview.md), [authentication](api/authentication.md), [polestar](api/polestar.md), [**polestar-backend-map**](api/polestar-backend-map.md), [polestar-probe-transcripts](api/polestar-probe-transcripts.md), [volvo](api/volvo.md), [errors-and-rate-limits](api/errors-and-rate-limits.md)
- **domain/** — [vehicle](domain/vehicle.md), [capability-matrix](domain/capability-matrix.md), [charging](domain/charging.md), [notifications](domain/notifications.md)
- **security/** — [overview](security/overview.md), [keychain](security/keychain.md), [threat-model](security/threat-model.md), [privacy](security/privacy.md)
- **development/** — [getting-started](development/getting-started.md), [repository-layout](development/repository-layout.md), [development-workflow](development/development-workflow.md), [adding-a-feature](development/adding-a-feature.md), [adding-a-provider](development/adding-a-provider.md)
- **testing/** — [strategy](testing/strategy.md), [fixtures](testing/fixtures.md)
- **operations/** — [build](operations/build.md), [ci](operations/ci.md), [releases](operations/releases.md), [troubleshooting](operations/troubleshooting.md)
- **adr/** — [index](adr/README.md)
- [glossary](glossary.md)
