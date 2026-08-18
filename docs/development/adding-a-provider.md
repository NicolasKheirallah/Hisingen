# Adding Another Provider

What implementing `VehicleProviding` for a third vehicle brand would actually require, based on how cleanly (and not-so-cleanly) that boundary holds up for the existing two. See [architecture/providers.md](../architecture/providers.md) for the current state of the seam before starting.

## What you get for free

Everything above `VehicleProviding` — you do not need to touch or understand:

- `RefreshCoordinator` (polling, coalescing, backoff)
- `Notifier` / `ChargingTransitionDetector` (notifications)
- `VehicleStateStore` / `Preferences` / `Keychain` (persistence — though you will call into `Keychain`/`Preferences` from your own provider code, the same way `PolestarAPI`/`VolvoAPI` do)
- `RemoteActionAuthorizer` (remote-command confirmation/authentication)
- Every SwiftUI view in `UI/` — they render `VehicleState`/`VehicleCapabilityProfile`, not provider-specific types
- `VehicleState.mergingLastKnown`, freshness/staleness logic, `stateSummary`

## What you must implement

1. **Authentication.** Whatever your new brand's login flow requires — OAuth2, a custom scraped flow, or something else. Add a new `Keychain` account (or bundle, following the Volvo pattern) and new `Preferences` keys, kept entirely separate from Polestar's and Volvo's. See [security/keychain.md](../security/keychain.md) and [api/authentication.md](../api/authentication.md) for the two existing patterns to choose from.
2. **Vehicle discovery.** Whatever produces `[CarSummary]` for the account.
3. **Provider DTOs.** New `Decodable`/protobuf types scoped to `Services/API/` for your brand — never expose them outside that directory.
4. **Mapping into `VehicleState`.** Inline in your `fetchVehicleState(vin:features:)`, following the existing pattern (see [architecture/data-flow.md](../architecture/data-flow.md#dto-domain-ui)) — not a requirement of the protocol, but the established convention both existing providers follow.
5. **Capabilities.** Add your brand's cases to `VehicleCapabilityProfile.support(for:)`'s static per-model switch (conservatively — `.backendDependent` where unverified), and wire any live probing your API supports. See [architecture/capabilities.md](../architecture/capabilities.md).
6. **Model identification.** Add cases to `VehicleModelFamily` and a `from(modelName:)`-style matcher, following the existing VIN-prefix-then-substring-matching pattern in `VehicleCapabilities.swift`.
7. **Telemetry, refresh behavior.** Just implement `fetchVehicleState` correctly and wrap optional fields defensively — `RefreshCoordinator`'s cadence/backoff/coalescing applies automatically to any `VehicleProviding` conformance, no brand-specific refresh code needed.
8. **Images (if applicable).** Whatever your brand's studio-image endpoint looks like, following the existing image-caching pattern (fetch once per session, cache the raw `Data`).
9. **Remote commands.** Implement as many `RemoteCommand` cases as your API actually supports; return `RemoteCommandError.unsupported` for the rest, following Volvo's partial-implementation pattern — don't claim support you haven't built.
10. **Tests.** Fixture-based decode tests (see [testing/fixtures.md](../testing/fixtures.md)) plus a credential-gated live integration test following `LivePolestarIntegrationTests.swift`/`LiveVolvoIntegrationTests.swift`'s pattern — runtime `.disabled(if:)` trait based on environment variables, never a compile-time flag, and read-only by default.

## What you should not need to do

- Rewrite any SwiftUI view from scratch — new cards/toggles should compose with the existing `AppFeature`/`VehicleCapabilityProfile` gating pattern.
- Add brand-specific `if brand == .yourNewBrand` checks outside of `Services/API/` and the few UI spots that already do this for Volvo (`ControlsTabView`'s `isBrandVolvo`, `SettingsView`'s badge text) — and even those existing checks are flagged as a rough edge, not a pattern to imitate freely; see [architecture/technical-debt.md](../architecture/technical-debt.md).
- Touch `RefreshCoordinator`'s internals.

## Where the abstraction currently isn't clean enough to just "plug in"

Documented honestly so you don't get surprised: `AppDelegate` currently hardcodes exactly two provider instances (`polestarAPI`, `volvoAPI`) and an `activeProvider` computed property that's a two-way `Preferences.activeBrand == .volvo ? volvoAPI : polestarAPI` ternary, not an N-way lookup. `VehicleBrand` is a two-case enum. Adding a third provider means:

- Changing `VehicleBrand` to accommodate a third case (touches every exhaustive `switch` over it — there are several, in `VehicleCapabilities.swift`'s static table, `Preferences`'s per-brand key helpers, and the UI's brand-switcher menu).
- Replacing the two-instance-plus-ternary pattern in `AppDelegate` with something that scales past two (a dictionary keyed by `VehicleBrand`, or similar).
- Extending `SettingsView`'s brand picker and `AccountCredentialsForm` beyond its current two-brand layout.

None of this is architecturally hard, but it is real work that the current two-provider design didn't need to do yet — this doc says so plainly rather than implying it's a drop-in. If you're planning this seriously, budget time for the `VehicleBrand`/`AppDelegate` generalization as its own step before writing any new-provider-specific code.
