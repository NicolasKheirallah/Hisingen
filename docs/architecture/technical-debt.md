# Technical Debt

Real findings from reading the implementation, not a wishlist. Severity is about impact if it goes wrong, not how hard it is to fix.

## Documentation vs. code discrepancy — Keychain accessibility level

**Severity: Low (documentation accuracy, not a security bug)**

README.md and TERMS.md both state Keychain items use `WhenUnlockedThisDeviceOnly`. The actual code (`Services/Persistence/Keychain.swift`) sets `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every write. These are different accessibility levels: `WhenUnlockedThisDeviceOnly` requires the device to be unlocked *at the moment of access*; `AfterFirstUnlockThisDeviceOnly` only requires that the device has been unlocked *once since boot* — a background process could read the item while the screen is locked, as long as the Mac has been unlocked since the last restart. Both are still `ThisDeviceOnly` (no iCloud Keychain sync), and both are reasonable choices for a menu-bar app that needs to refresh tokens without the screen being unlocked — but the public-facing docs currently describe a stricter guarantee than the code provides. See [security/keychain.md](../security/keychain.md). **Fix direction:** align the README/TERMS wording with the actual `AfterFirstUnlock` behavior, or tighten the code to match the documented claim if the stricter behavior was actually intended.

**Status: RESOLVED.** Resolved. README.md and TERMS.md now describe `AfterFirstUnlockThisDeviceOnly` and why a background-refreshing menu-bar app needs it.

## `InMemorySecretCache` keyed by account only, not service+account

**Severity: Medium**

`Keychain.swift`'s `InMemorySecretCache` is a process-global singleton (`@unchecked Sendable`, `NSLock`-protected) that caches secrets after first read, keyed only by the Keychain *account* string. `KeychainStore` instances are parameterized by `service`, and tests construct isolated stores with unique per-test `service` values (e.g. `io.kheirallah.hisingen.tests.\(UUID())`) — but if two such instances ever used the same *account* constant (which they do, since account names are static), cache entries would be shared across them regardless of `service`. This is currently masked because the Keychain "draft" methods (the only place this could realistically bite in tests) are no-op stubs (see below), but it's a latent bug waiting for the draft methods to become real, or for any other code path that constructs a second `KeychainStore` with a different service and the same account name. **Fix direction:** key the cache by `service + account`, not `account` alone.

**Status: RESOLVED.** Resolved. `cacheKey(account:)` returns `"\(service)|\(account)"`, so entries are scoped per store.

## Keychain "draft" methods are dead code

**Severity: Low**

`savePasswordDraft`/`readPasswordDraft`/`deletePasswordDraft` and the Volvo equivalents always no-op / return `nil`, despite `Tests/HisingenTests/Unit/KeychainDraftTests.swift` exercising them and asserting drafts never collide with committed credentials — an assertion that's trivially true today since nothing is ever actually written. Either the draft-persistence feature was never finished, or it was intentionally reverted to no-ops and the tests weren't removed. **Fix direction:** implement real draft storage, or delete the dead API surface and its tests.

**Status: RESOLVED.** Resolved. The draft methods are real Keychain reads/writes; `KeychainDraftTests` now exercises actual storage.

## `VehicleStateStore` has no compiler-enforced isolation

**Severity: Medium**

`VehicleStateStore` is a plain `final class` with no `actor`/`@MainActor` annotation, despite holding an implicit assumption that it's only ever touched from the main actor (its two callers, `RefreshCoordinator` and `Notifier`, are both `@MainActor`). Nothing in the type system prevents a future `@MainActor`-unaware caller from reading/writing it concurrently and corrupting the `UserDefaults`-backed dictionaries. **Fix direction:** annotate it `@MainActor`, or make it a true `actor` if a background caller is ever needed.

**Status: RESOLVED.** Resolved. Annotated `@MainActor`, making the existing assumption compiler-enforced.

## `MainActor.assumeIsolated` instead of compiler-verified isolation

**Severity: Low**

`RefreshCoordinator`'s `NSWorkspace` sleep/wake notification handlers use `MainActor.assumeIsolated { ... }` rather than a `@MainActor`-typed closure. This is safe today because `NSWorkspace.notificationCenter` observers registered with `queue: .main` do run on the main thread — but it's a runtime assertion (crashes if wrong) rather than something the compiler verifies, and would silently become a crash risk if that registration detail ever changed.

**Status: RESOLVED.** Resolved. `addMainActorObserver(for:)` binds `queue: .main` and the isolation assumption together so they cannot drift.

## Duplicate PKCE implementation

**Severity: Low**

`Support/PKCE.swift` is a complete, working PKCE implementation (`randomURLSafeString()`, `codeChallenge(for:)`). `VolvoAPI` uses it. `PolestarAPI` does not — it has its own private, functionally-identical re-implementation of the same two functions inline. This looks like an incomplete refactor (`Support/PKCE.swift` was presumably meant to replace both) rather than a deliberate choice. **Fix direction:** have `PolestarAPI` call into `Support/PKCE.swift` and delete its private copy.

**Status: RESOLVED.** Resolved. `PolestarAPI` calls `Support/PKCE.swift`; its private copy and the local `base64URLEncoded` helper are gone.

## Volvo `restrictedScopes` defined but never requested

**Severity: Medium (functional, not just cosmetic)**

`VolvoAPI` defines a `restrictedScopes` array (`conve:lock`, `conve:unlock`, `conve:engine_start_stop`, `conve:honk_flash`, `location:read`) that is never appended to the actual OAuth authorize request — only `readScopes` is sent. If Volvo's authorization server strictly enforces scope-gated access per endpoint, this could mean the Location API and lock/unlock/honk-flash commands fail with a permission error that looks like a backend problem but is actually a missing scope request. It's unclear from the code whether this is intentional (e.g. these scopes require manual approval on the Developer Portal and aren't meant to be requested per-session) or an oversight. **Fix direction:** confirm with Volvo's Developer Portal documentation whether these scopes need to be requested, and either add them to the authorize call or document why they're deliberately excluded.

## Volvo 403 → `regionRestricted` inference is a narrow, undocumented heuristic

**Severity: Low**

`VolvoAPI`'s generic `get<T>` helper treats a 403 on a per-vehicle telemetry GET as `VolvoError.regionRestricted(service:)` rather than a permission error — but this override is applied only to individual-vehicle telemetry GETs, not to vehicle discovery or remote commands, which still map 403 to plain `.permissionDenied`. There's no comment explaining the asymmetry beyond a blank-line marker in the source. This is an empirically-tuned assumption about Volvo's API behavior, not something derived from Volvo's own documentation. See [api/errors-and-rate-limits.md](../api/errors-and-rate-limits.md).

**Status: RESOLVED.** Resolved as a documentation gap — the asymmetry is now explained in a comment at the throw site.

## Volvo remote-command response parsing is untyped

**Severity: Low**

Every read-path Volvo DTO is a strongly-typed `Decodable` struct. `dispatchCommand`'s response parsing (`invokeStatus`, `error.description`) uses raw `JSONSerialization` dictionary lookups instead. This is a signal the write-path response contract was less confidently understood than the read endpoints when it was implemented, and it means a shape change on Volvo's side would fail silently (falling back to a generic `.accepted` outcome) rather than surfacing a decode error.

**Status: RESOLVED.** Resolved. `VolvoCommandResponseDTO`/`VolvoCommandErrorDTO` replace the dictionary lookups, and a `FAILED`/`REJECTED` poll result now throws instead of reporting `.accepted`.

## `VolvoAPI.executeRemoteCommand` only implements 6 of ~20 `RemoteCommand` cases

**Severity: Medium (feature gap, not a bug)**

Charge-target/amp-limit/schedule/pre-cleaning/OTA commands all fall through to `RemoteCommandError.unsupported` for Volvo, even where `VehicleCapabilityProfile` might report the underlying capability as supported. The capability system describes what the *vehicle* can do; it doesn't yet track what the *provider client code* has actually implemented. See [architecture/providers.md](providers.md#where-the-abstraction-isnt-clean-today).

**Status: RESOLVED.** Resolved as a *visibility* problem. `RemoteCommand.isImplemented(by:)` states what each provider's client code dispatches, and the UI gates on it. The endpoints Volvo does not expose remain unimplemented.

## UI enable/disable state doesn't purely follow the capability system

**Severity: Medium (user-facing, but currently fails safe)**

**Status: RESOLVED.** Every control now gates through `ControlsTabView.isDisabled(_:)` /
`cardOpacity(_:)`, which combine `RemoteCommand.isImplemented(by:)`,
`VehicleCapabilityProfile.permits(_:)`, and `remoteCommandInProgress`. No `.disabled(true)`
literal remains in the file. Polestar's climate/locks/windows/honk/charging/timer controls are
live (invocation via C3 + command token, chronos via PCCS + web token; both paths verified
against a real vehicle — see the internal-only `docs/api/polestar-backend-map.md`).

The original problem, for the record: the UI used to *enable* controls on a hardcoded
`isBrandVolvo` check independent of the capability system, so the two could drift apart. They no
longer can — a control is enabled iff all three layers agree.

**Status: RESOLVED.** Resolved. `ControlsTabView.isDisabled(_:)`/`cardOpacity(_:)` gate on implementation + capability + in-flight state; the `isBrandVolvo` overrides are gone.

## Optimistic local state patch on remote commands vs. "ack ≠ execution" stance

**Severity: Low–Medium (UX/trust tension, not a crash risk)**

`AppDelegate.performRemoteCommand` patches `latest` (and persists it) with the expected post-command state for four commands (`startClimate`, `stopClimate`, `lock`, `unlock`) as soon as `executeRemoteCommand` returns *any* result — including a `.accepted` outcome, not only `.completed`. TERMS.md is explicit that "a backend acknowledgment is confirmation of delivery only, not of execution." The optimistic UI update is a reasonable UX choice (waiting a full refresh cycle for a lock icon to flip is bad UX) and is corrected on the next real refresh, but it does mean the app can briefly show a lock/climate state that hasn't actually been confirmed by the vehicle — worth knowing if you're debugging a "Hisingen said locked but it wasn't" report.

**Status: RESOLVED.** Resolved. `applyConfirmedStateChange(for:outcome:)` only patches on `.completed`; weaker acknowledgments wait for the follow-up refresh.

## Volvo software info is synthetic, not derived from any API

**Severity: Low (currently harmless, but a latent trust issue)**

`VolvoAPI.fetchVehicleState` hardcodes `VehicleSoftwareInfo(version: "Google built-in (AAOS)", ..., state: .completed)` for every Volvo vehicle — Volvo doesn't expose an OTA/software-update REST endpoint through the APIs this app uses. This is a static placeholder, not telemetry. It's currently rendered the same way as Polestar's real software-status card, which could read as more informative than it is. **Fix direction:** either suppress the software card for Volvo entirely, or visibly label it as "not available via API" rather than a static string that resembles real data.

**Status: RESOLVED.** Resolved. Volvo returns no software payload at all and `.softwareUpdates` is reported unavailable; `softwareStatus` is `.unavailable` in the Volvo capability profiles.

## No schema versioning beyond a `_v1` key-name suffix

**Severity: Low**

`VehicleStateStore`'s two `UserDefaults` keys (`cached_vehicle_snapshots_v1`, `charging_baselines_v1`) rely entirely on the `_v1` suffix as their versioning strategy — there's no migration path if a future `Codable` shape change isn't backward-compatible; a decode failure just degrades silently to "no cache." Acceptable for a small local cache with a 7-day TTL, but worth knowing if you're changing `VehicleState`'s shape and want to reason about what existing users will see on upgrade (answer: a one-time cold start for that VIN, not a crash).

## Legacy `Theme.swift` still present alongside `HisingenTheme.swift`

**Severity: Trivial**

`UI/Theme.swift` is a small, mostly-superseded set of AppKit label/color helpers; `UI/HisingenTheme.swift` is the real, actively-used design system. `Theme.swift` isn't fully dead (a few AppKit call sites still use it), but it's a candidate for consolidation next time someone touches AppKit-facing label styling.

## Polestar exposes 6 vehicle-image angles, `CarRenderAngle` only names 4

**Severity: Low**

Polestar's `GetCarImages` query returns angles `0`–`5` (confirmed via a real captured response in the independent [pypolestar](https://github.com/pypolestar/pypolestar) project's test fixtures), but `Preferences.swift`'s `CarRenderAngle` enum only defines four named cases (`frontThreeQuarter=0`, `rearThreeQuarter=1`, `sideProfile=2`, `overhead=3`), so Settings' angle picker can never select angle `4` or `5`. The data layer doesn't know about this gap — `PolestarAPI.fetchCarImage()`'s background prefetch loop downloads and caches *every* angle present in the response pool regardless of whether it has a UI name, so a Polestar user's disk cache silently accumulates two unreachable images per vehicle. See [api/polestar.md#vehicle-images](../api/polestar.md#vehicle-images). **Fix direction:** visually inspect what angles `4`/`5` actually show for a real vehicle (no semantic label exists in the API itself — it's a bare `Int`, not an enum), then either give them real names in `CarRenderAngle` or, if they turn out to be low-value duplicates/close variants of 0-3, leave them unexposed deliberately and note why.

## PCCS gRPC calls used C3 package prefixes

**Severity: High — CONFIRMED AND FIXED**

Every request Hisingen sent to the PCCS host (`api.pccs-prod.plstr.io`) used the **C3** package names. Probed live against a real vehicle, each one is `UNIMPLEMENTED` there while the `pccs.`-prefixed name exists:

| Service | Unprefixed (was used) | `pccs.`-prefixed |
| --- | --- | --- |
| `TargetSocService/GetTargetSoc` | absent | present |
| `AmpLimitService/GetAmpLimit` | absent | present |
| `ChargeNowService/StartOverrideChargeTimer` | absent | present |
| `GlobalChargeTimerService/GetGlobalChargeTimerStream` | absent | present |
| `ParkingClimateTimerService/GetTimers` | absent | present |
| `ChargeLocationService/GetChargeLocations` | absent | present |
| `invocation.InvocationService/Lock` | "Service is unimplemented" | present as `pccs.invocation.v1.InvocationService` |

So charge target, current limit, charge windows, climate timers, charge locations — and *every* Polestar remote command — had never reached a real endpoint. Fixed by moving all PCCS-bound paths to `pccs.chronos.services.vN.*` and `pccs.invocation.v1.InvocationService`; note invocation gains a `.v1` the chronos services do not.

Verified after the change: a live refresh now reports `Charge Target: 90%`, which was previously unavailable.

