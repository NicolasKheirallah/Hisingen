# Refresh System

`RefreshCoordinator` (`Services/Refresh/RefreshCoordinator.swift`, `@MainActor`) owns the entire polling lifecycle for one `VehicleProviding` instance. `AppDelegate` constructs a fresh one every time the active brand changes.

## Cadence

`RefreshPolicy.regularInterval(isCharging:)`:

- **60 seconds** while `latest.isCharging == true`
- **300 seconds (5 minutes)** otherwise

Plus jitter on every scheduled refresh: `maxJitter = min(15, max(1, interval * 0.1))`, then `Double.random(in: 0...maxJitter)` added on top — so charging gets 0–6s of jitter, idle gets 0–15s, preventing every Hisingen instance from hitting the backend on a perfectly synchronized clock edge.

## Retry / backoff

`RefreshPolicy.retryDelay(failureCount:retryAfter:)`:

- If the failure carried a server-supplied `Retry-After` value, use it, clamped to **30–3600 seconds**.
- Otherwise, exponential: `30 × 2^(failureCount − 1)` seconds, with `failureCount` clamped to `0...5` internally — so the sequence is 30, 60, 120, 240, 480, 900, and it plateaus at **900 seconds (15 minutes)** after the 6th consecutive failure. No further growth beyond that.

There is no separate rate-limit-specific state machine beyond this — a `.rateLimited` error just supplies its `retryAfter` value into the same `retryDelay` function, and `RefreshCoordinator.rateLimitedUntil` short-circuits any new refresh attempt (manual or timer) until that time passes, republishing diagnostics with the pending `nextRefresh` instead of issuing a request.

## Coalescing — how duplicate API calls are avoided

One `task: Task<Void, Never>?` plus a `generation: UInt64` counter. Every entry point (`refresh(trigger:)`, `selectCar`, `reloadVehicleMetadata`) does:

```swift
guard task == nil else { return }   // an equivalent refresh is already in flight — drop this trigger
```

Callers that arrive while a refresh is already running simply don't get a second network call — they'll receive the in-flight refresh's result through the same `onState`/`onError` callback everyone else is listening to. Every async completion additionally checks `requestGeneration == generation && !Task.isCancelled` before committing its result, so if `selectCar`/`credentialsChanged`/`signOut` bumped the generation while a fetch was in flight (superseding it), that stale result is silently discarded rather than overwriting newer state.

```mermaid
sequenceDiagram
    participant T as Timer (5 min mark)
    participant M as Manual click
    participant W as Wake from sleep
    participant RC as RefreshCoordinator
    participant API as Provider actor

    T->>RC: refresh(.timer) — task == nil, proceeds, generation = 7
    RC->>API: fetchVehicleState()
    M->>RC: refresh(.manual) — task != nil, dropped
    W->>RC: refresh(.wake) — task != nil, dropped
    API-->>RC: VehicleState
    RC->>RC: generation check passes (still 7) → apply(state)
    RC-->>T: onState(state)
    RC-->>M: onState(state)
    RC-->>W: onState(state)
```

All three triggers converge on exactly one network call.

## Triggers

| Trigger | Source |
|---|---|
| `.timer` | One-shot `Timer` rescheduled after every fetch (success or failure) |
| `.manual` | `AppDelegate`'s `onRefresh` closure (menu-bar click, context-menu "Refresh", or footer button) |
| `.wake` | `NSWorkspace.didWakeNotification` |
| `.networkRestored` | `NWPathMonitor` flipping from unavailable to available |
| `.vehicleChanged` | After a successful `selectCar(vin:)` |

`refreshIfStale()` — called from `applicationDidBecomeActive` — is a sixth, softer path: it only issues a refresh if `Date().timeIntervalSince(latest.fetchedAt) >= RefreshPolicy.regularInterval(isCharging:)`, i.e. bringing the app to the foreground doesn't force a network call if the current data isn't old enough to need one yet.

## Vehicle switching

`selectCar(vin:)`: no-ops if the VIN is already selected; otherwise bumps `generation` (invalidating any in-flight fetch for the old vehicle), resets `failureCount`, cancels the current task/timer, persists the new VIN to `Preferences`, immediately shows `stateStore.snapshot(for: vin)` if one exists (else shows the loading state), calls `api.selectCar(vin:features:)`, and on success issues a `.vehicleChanged` refresh.

## Credential changes

`credentialsChanged(email:password:preferredVIN:)`: cancels current work and resets failure/backoff state. If the *account itself* changed (case/whitespace-normalized email comparison), it wipes `VehicleStateStore` entirely (`stateStore.clear()`), clears in-memory `latest`/`cars`/`lastError`, and fires `onCleared`. It then calls `api.resetSession()` and re-runs `beginSession`.

## Sleep / wake and network loss / restoration

- **Sleep** (`NSWorkspace.willSleepNotification`): `cancelCurrentWork()` — bumps generation, cancels task/timer — and sets `sleeping = true`. No refresh attempts happen while asleep.
- **Wake** (`NSWorkspace.didWakeNotification`): clears `sleeping`, issues `refresh(trigger: .wake)` (or `beginSession` if the session isn't ready yet).
- **Network loss**: `NWPathMonitor.pathUpdateHandler` sets `networkAvailable = false`; `networkDidChange(false)` cancels current work (a refresh mid-flight against a dead network isn't worth waiting out).
- **Network restoration**: `networkDidChange(true)` issues `refresh(trigger: .networkRestored)` (or `beginSession` if not yet authenticated) — but only if the app isn't currently `sleeping`.

## Stale-on-activation

Distinct from staleness on the *data* (see [data-flow.md](data-flow.md#freshness)): `refreshIfStale()` is stale-on-*activation* — it's the mechanism that makes bringing Hisingen back to focus after a while trigger a refresh without waiting for the next timer tick, but without forcing one if the last fetch is still fresh enough per the current cadence.

## Cancellation

`cancelCurrentWork()` — increments `generation`, cancels the `Task`, invalidates the pending `Timer`, clears `nextRefresh`. It does **not** propagate cancellation into the provider actor's in-flight network call; the underlying `URLSession`/gRPC request is allowed to finish, its result is just discarded by the generation check. See [concurrency.md](concurrency.md#cancellation) for why that's a deliberate trade-off.

## Diagnostics

`DiagnosticsSnapshot` is republished after nearly every state transition: `lastSuccess`, `lastError`, `latency`, `nextRefresh`, `sessionValid`, `networkAvailable`, `refreshInProgress` (`task != nil`). `AppDelegate` uses `diagnostics.sessionValid` (OR'd with `Preferences.hasResumableSession`) to decide whether the UI should be in the authenticated or sign-in state.
