# Swift Concurrency

Hisingen is built with `-strict-concurrency=complete -warn-concurrency` (enforced in CI — see [operations/ci.md](../operations/ci.md)). Every architecturally significant type declares its isolation explicitly; there are exactly two places that fall back to a manual lock instead of actor isolation, both called out below.

## Isolation by component

| Component | Isolation | Mutable state | How concurrency is prevented |
|---|---|---|---|
| `AppDelegate` | `@MainActor` class | `latest`, `lastError`, `sessionValid`, `remoteCommandInProgress` | Main-actor confinement |
| `RefreshCoordinator` | `@MainActor` class | timer, in-flight `Task`, `generation` counter, failure/backoff state | Main-actor confinement + generation counter (below) |
| `PolestarAPI` | `actor` | tokens, `cars`, capability cache/backoff, discovered gRPC host | Actor isolation; token refresh and C3 host discovery each additionally coalesce concurrent callers onto one stored `Task` |
| `PolestarGRPC` | `actor` | discovered C3 host, in-flight discovery `Task` | Actor isolation |
| `VolvoAPI` | `actor` | tokens, `cars`, capability/vehicle-details cache, endpoint backoff, `remoteCommandsInFlight` | Actor isolation; same single-`Task` refresh coalescing as Polestar |
| `Notifier` | `@MainActor` class | `previousStateByVIN`, permission status | Main-actor confinement |
| `ChargingTransitionDetector` | plain `struct` | none — pure function | Value semantics; no shared state to race |
| `RemoteActionAuthorizer` | `@MainActor` class | none (stateless; needs main actor for `NSAlert`/`LAContext`) | Main-actor confinement |
| `VolvoSignInPresenter` | `@MainActor` class | one pending `CheckedContinuation` | Main-actor confinement; a new `signIn` call rejects any prior pending continuation rather than racing it |
| `ReverseGeocoder` | `actor` | in-memory geocode cache | Actor isolation |
| `UpdateService` | `@MainActor` class | Sparkle controller and UI state | Main-actor confinement; Sparkle serializes update sessions |
| `Preferences` | `@MainActor enum` | none directly (UserDefaults façade) | Main-actor confinement |
| `VehicleStateStore` | plain `final class`, **no isolation annotation** | none held across calls — reads/writes UserDefaults fresh each time | **Not compiler-enforced** — see [technical-debt.md](technical-debt.md); safe today only because both callers (`RefreshCoordinator`, `Notifier`) happen to be `@MainActor` |
| `Keychain` / `KeychainStore` | `struct` (stateless) delegating to `InMemorySecretCache` | none itself | Delegates to the manual-lock singleton below |
| `InMemorySecretCache` | `final class`, `@unchecked Sendable` | `[account: secret]` dictionary | `NSLock` — the one deliberate manual-lock pattern for shared mutable state; see [technical-debt.md](technical-debt.md) for its cache-key caveat |
| `OAuthRedirectDelegate` (Polestar login) | `final class`, `@unchecked Sendable`, `NSObject`/`URLSessionTaskDelegate` | captured redirect `URL` | `NSLock` — required because `URLSessionTaskDelegate` callbacks can't be actor-isolated |
| UI (`StatusItemController`, all SwiftUI views) | `@MainActor` | view-local state only | Main-actor confinement; no cross-actor hop between AppKit and SwiftUI |

Everything that touches AppKit, `LocalAuthentication`, or `UNUserNotificationCenter` is `@MainActor` because those frameworks require it. Everything that talks to the network is an `actor` so the app can run several vehicle-field fetches concurrently (`async let`) without any hand-written locking.

## Specific concurrency scenarios

**Automatic (timer) refresh racing a manual refresh.** `RefreshCoordinator` holds one `task: Task<Void, Never>?`. Every entry point (`refresh(trigger:)`, `selectCar`, `reloadVehicleMetadata`) checks `guard task == nil` before starting new work — if a refresh is already in flight, the trigger is simply dropped rather than queued, and the caller sees the in-flight refresh's result when it lands. Confirmed by `RefreshCoordinatorTests.testConcurrentManualRefreshesCoalesceWithLaunchRefresh`, which starts the coordinator and calls `refreshNow()` twice concurrently and asserts the mock provider's `fetchCount == 1`.

**Network recovery arriving mid-refresh.** `NWPathMonitor`'s callback runs on a private `DispatchQueue`, hops onto the main actor via `Task { @MainActor in ... }`, and only then calls `networkDidChange(_:)`. If a refresh is already running, the existing `guard task == nil` protects it the same way as above.

**Sleep/wake.** `NSWorkspace.willSleepNotification` cancels all current work (`cancelCurrentWork()`, which bumps `generation` so any in-flight completion is discarded) and sets `sleeping = true`. `NSWorkspace.didWakeNotification` clears the flag and issues a `.wake`-triggered refresh. Both handlers use `MainActor.assumeIsolated` rather than a compiler-verified `@MainActor` closure — safe in practice because `NSWorkspace.notificationCenter` observers registered with `queue: .main` always run on the main thread, but it's an assertion, not a guarantee (see [technical-debt.md](technical-debt.md)).

**Vehicle switching mid-refresh.** `selectCar(vin:)` bumps `generation` before doing anything else, so any refresh already in flight for the *previous* vehicle has its eventual completion discarded (every completion handler checks `requestGeneration == generation` before committing results).

**Token refresh under concurrent field fetches.** Both `PolestarAPI` and `VolvoAPI` fetch up to a dozen telemetry fields concurrently via `async let` inside `fetchVehicleState`. If several of those calls discover their token needs refreshing at once, only one actually issues a refresh request — the others `await` the same stored `Task<TokenResponse, Error>`, because actor isolation guarantees the check-and-store of that `Task` can't race.

**Popover activation.** Purely `@MainActor` — `StatusItemController.showPopover()` builds the `NSHostingController` synchronously from whatever state is already cached on `self`; there's no async work on the activation path itself.

## Cancellation

`RefreshCoordinator` cancels via `cancelCurrentWork()`: increments `generation` (invalidating any in-flight completion), cancels the `Task`, invalidates the pending `Timer`. It does not use Swift's structured-cancellation propagation into the provider actors — a cancelled `RefreshCoordinator` task still lets its underlying `PolestarAPI`/`VolvoAPI` network calls run to completion; the generation check just discards the result. This is a deliberate simplicity trade-off, not an oversight: provider calls are idempotent reads (except remote commands, which are separately guarded by `remoteCommandsInFlight`), so letting an already-in-flight fetch finish and then discarding it is cheaper than plumbing cooperative cancellation through the gRPC/GraphQL clients.

## `Sendable`

Every type that crosses an actor boundary is `Sendable`: `VehicleState`, `RemoteCommand`, `RemoteCommandResult`, `VehicleServiceError`, `CarSummary`, `VehicleCapabilityProfile`. The two `@unchecked Sendable` types (`InMemorySecretCache`, `OAuthRedirectDelegate`) are both justified the same way — they wrap a type Swift concurrency can't reason about (a shared dictionary behind a `NSLock`; a `URLSessionTaskDelegate` callback that Foundation invokes on an arbitrary queue) and manually guarantee the safety the compiler can't verify.
