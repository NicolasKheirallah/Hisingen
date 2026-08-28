# Repository Layout

```
.
├── Sources/Hisingen/
│   ├── App/            AppDelegate.swift, main.swift
│   ├── Domain/          Shared vehicle model — no networking, no UI
│   ├── Services/
│   │   ├── API/          Both VehicleProviding implementations + shared protocol/errors
│   │   ├── Refresh/      RefreshCoordinator
│   │   ├── Persistence/  Keychain, Preferences, VehicleStateStore
│   │   ├── Notifications/ Notifier, ChargingTransitionDetector
│   │   ├── Security/     RemoteActionAuthorizer, VolvoSignInPresenter
│   │   ├── Location/     ReverseGeocoder
│   │   └── Updates/      UpdateService (Sparkle)
│   ├── Support/          Format, L10n, PKCE — small stateless helpers
│   ├── Resources/        Assets.xcassets, .lproj localization bundles
│   └── UI/               StatusItemController (AppKit) + SwiftUI views
├── Tests/HisingenTests/
│   ├── Unit/             18 files, Swift Testing, no network
│   ├── Integration/      2 files, real network calls, credential-gated
│   └── Fixtures/         26 sanitized JSON response fixtures
├── docs/                 This documentation set (+ oauth-callback.html, the Volvo redirect bridge)
├── Scripts/              doctor.sh, test.sh, check-localization.py (translation coverage/duplicate-key check)
├── .github/
│   ├── workflows/         CI, security, dependency review, live integration, release, and Pages workflows
│   ├── dependabot.yml      Weekly updates for pinned GitHub Actions SHAs and (future) SwiftPM dependencies
│   ├── ISSUE_TEMPLATE/     bug_report.md, feature_request.md, vehicle_compatibility.md, config.yml
│   └── pull_request_template.md
├── Package.swift         SPM manifest — pinned Sparkle updater dependency
├── Makefile              build/test/package/release orchestration
├── README.md             User-facing project README
├── SECURITY.md           Vulnerability reporting policy — see security/overview.md
├── TERMS.md              Legal/liability terms
```

## What belongs where

**`Domain/`** — value types only (`struct`/`enum`, `Codable`, `Sendable`). No `import Foundation.URLSession`-style networking, no AppKit/SwiftUI, no Keychain. If a type represents *what a vehicle is/does* rather than *how to fetch or display it*, it belongs here. See [architecture/components.md](../architecture/components.md#domain-model-domainswift).

**`Services/API/`** — everything that talks to Polestar or Volvo, plus the `VehicleProviding` protocol they both implement. Provider-specific DTOs and wire-format code live here and nowhere else — no other directory should ever import a Polestar/Volvo-specific DTO type. See [architecture/providers.md](../architecture/providers.md).

**`Services/Refresh/`** — polling/coalescing/backoff logic only. Doesn't know about UI, doesn't know about Keychain directly (talks to `VehicleStateStore` and `Preferences`, not `Keychain` directly).

**`Services/Persistence/`** — the only directory that touches Keychain or `UserDefaults` directly for app state. If you're adding a new piece of state that needs to survive a relaunch, it goes through `Preferences` (non-secret) or `Keychain` (secret) or `VehicleStateStore` (per-VIN telemetry-shaped cache) — not a new ad-hoc `UserDefaults.standard.set` call somewhere else in the codebase.

**`Services/Notifications/`** — the charging state machine (`ChargingTransitionDetector`, a pure function — keep it that way) and the actual notification-posting logic (`Notifier`, `@MainActor`). Don't add `UNUserNotificationCenter` calls outside this directory.

**`Services/Security/`** — local-authentication/authorization concerns (`RemoteActionAuthorizer`) and the Volvo OAuth browser-presentation glue (`VolvoSignInPresenter`). Not where Keychain storage itself lives — that's `Persistence/`.

**`Support/`** — small, stateless, dependency-free helpers (`Format`, `L10n`, `PKCE`). If a helper is used by exactly one provider, it likely belongs next to that provider instead (see the `PolestarAPI` vs. `Support/PKCE.swift` duplication noted in [architecture/technical-debt.md](../architecture/technical-debt.md) as a cautionary example).

**`UI/`** — AppKit shell (`StatusItemController`) and every SwiftUI view. Should only ever import `Domain` types and call through `VehicleProviding`-adjacent closures — never a provider-specific DTO.

**`Tests/HisingenTests/Unit/`** — no network calls, ever. **`Integration/`** — real network calls, always credential-gated via a runtime `.disabled(if:)` trait, never a compile flag. **`Fixtures/`** — sanitized JSON only; see [testing/fixtures.md](../testing/fixtures.md) for what "sanitized" means here and how to add a new one.

## Important entry points

| If you're... | Start here |
|---|---|
| Tracing app startup | `Sources/Hisingen/App/AppDelegate.swift` — `applicationDidFinishLaunching` |
| Adding a new telemetry field | `Domain/VehicleState.swift` (the field), then `PolestarAPI.swift`/`VolvoAPI.swift` (populate it) — see [adding-a-feature.md](adding-a-feature.md) |
| Debugging a refresh/polling issue | `Services/Refresh/RefreshCoordinator.swift` |
| Debugging why a feature is greyed out | `Domain/VehicleCapabilities.swift` (`VehicleCapabilityProfile.support(for:)`) |
| Changing what's cached to disk | `Domain/VehicleState.swift` (`cacheableCopy`), `Services/Persistence/VehicleStateStore.swift` |
| Touching Polestar auth/telemetry | `Services/API/PolestarAPI.swift` + `PolestarGRPC*.swift` |
| Touching Volvo auth/telemetry | `Services/API/VolvoAPI.swift` + `VolvoModels.swift` |
| Changing the popover/menu-bar UI | `UI/StatusItemController.swift` (AppKit shell), `UI/HisingenContentView.swift` (SwiftUI root) |
| Changing Settings | `UI/SettingsView.swift`, `UI/AccountCredentialsForm.swift` |
| Adding a build/release step | `Makefile`, `.github/workflows/` |
