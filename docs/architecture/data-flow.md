# Data Flow: Telemetry, Freshness, and Merging

This traces one refresh cycle end to end: API response → domain model → UI, plus the freshness and merge rules that make cached/partial data safe to show.

## DTO → domain → UI

```
Provider REST/GraphQL/gRPC response
        │  (PolestarAPI / PolestarGRPC / VolvoAPI — inline mapping,
        │   not a separate mapper file; see api/polestar.md, api/volvo.md)
        ▼
VehicleState(...)  — assembled in fetchVehicleState(vin:features:)
        │
        ▼
VehicleState.mergingLastKnown(from: previous, features:)
        │  — fills gaps from the last good value per enabled feature
        ▼
RefreshCoordinator.apply(_:latency:)
        │  — appends a completed ChargingSession if one just finished,
        │    caps chargingSessions at 20, resets failure/backoff counters
        ▼
VehicleStateStore.save(state.cacheableCopy)   (UserDefaults, PII-stripped)
        │
        ▼
RefreshCoordinator.onState(state)  →  AppDelegate.latest = state
        │
        ▼
StatusItemController.render(data:error:authenticated:)
        │  — computes menu-bar title/icon, dims if state.isStale()
        ▼
HisingenContentView / VehicleTabView (SwiftUI)
        — renders cards, each individually nil-able based on
          Preferences.features and per-field presence
```

Unlike some codebases, Polestar and Volvo do **not** funnel through a separate "mapper" type — `PolestarAPI.fetchVehicleState` and `VolvoAPI.fetchVehicleState` each assemble the final `VehicleState(...)` inline, field by field, after a set of concurrent `async let` calls. This is documented honestly rather than papered over: the DTO→domain boundary is real (nothing outside `Services/API/` ever sees a `TelematicsDTO` or `VolvoEnergyStateDTO`), but there's no single named "mapper function" per field — see [api/polestar.md](../api/polestar.md) and [api/volvo.md](../api/volvo.md#supported-endpoints) for exactly where each field comes from.

## Freshness

Two timestamps matter, and they usually disagree:

- **`fetchedAt`** — when Hisingen's HTTP/gRPC call completed.
- **`vehicleReportedAt`** — the timestamp the *vehicle itself* attached to the telemetry sample (when the backend last heard from the car), if the API exposes one.

`VehicleState.dataTimestamp` resolves to `vehicleReportedAt ?? fetchedAt` — the app always prefers the vehicle's own timestamp when one exists. Example: a request completing at `18:42` with a vehicle-reported sample timestamp of `16:10` is **not** live telemetry from 18:42 — it's a ~2.5-hour-old sample that Hisingen happened to fetch just now, because the vehicle has been asleep since 16:10. `VehicleState.freshnessDescription` renders exactly this distinction ("Vehicle asleep · Updated 2h ago" vs. "Updated just now").

`VehicleState.isStale(at:)`:

```swift
if date.timeIntervalSince(fetchedAt) < 120 { return false }   // never "stale" within 2 min of a fetch
let threshold: TimeInterval = isCharging ? 15 * 60 : 60 * 60   // 15 min while charging, 1 hour otherwise
return date.timeIntervalSince(dataTimestamp) > threshold
```

So staleness is judged against `dataTimestamp` (the vehicle's own clock), not `fetchedAt` — a vehicle that's been asleep for three hours is "stale" even if Hisingen successfully fetched that same stale sample thirty seconds ago. The two-minute grace period exists purely to avoid a flash of "stale" immediately after a fetch completes, before the UI has settled.

## Data merging

`VehicleState.mergingLastKnown(from previous:features:)` runs on every fetch, before the result is shown or cached. It exists because optional-capability fetches can fail independently (see [capabilities.md](capabilities.md)) — without merging, a single failed gRPC call would blank out a whole card that was showing data a minute ago.

**Precedence rule, field by field:** the new value wins if present; otherwise, the previous value is kept **only if** that field's owning `AppFeature` is both (a) enabled in `Preferences.features` and (b) present in the new state's `unavailableFeatures` list (i.e., this fetch specifically tried and failed to get that field, rather than the feature being off entirely). Fields whose feature is disabled are not carried forward — they're `nil`, as expected.

**Enum fields get a "unknown means keep old" rule instead:** `chargingState`, `availability`, `chargingType`, `chargerConnection` each have an `.unknown`/`.unavailable` case; if the new fetch produced that sentinel, the previous concrete value is kept rather than overwriting a known state with "unknown."

**What is never carried forward:** `vin`, `fetchedAt`, `dataWarnings`, `unavailableFeatures` always come from the new fetch — merging never hides the fact that *this* fetch had warnings, even while it's filling in stale data for individual fields. `chargingSessions` (the persisted history) is explicitly carried over from `previous` unconditionally — it's accumulated state, not a per-fetch field.

**Missing data never becomes a fabricated zero.** Every numeric field on `VehicleState` is `Optional`; a missing battery percentage renders as "—" in the UI, never as `0%`. This is a stated design principle (see [architecture/technical-debt.md](technical-debt.md) for the one place this is easy to get wrong) rather than an accident of `Codable` defaults.

**Charging samples** are handled separately from the general merge: while charging, a new `ChargingSample(timestamp:batteryPercentage:powerWatts:)` is appended to `previous.chargingSamples` only if at least 20 seconds have passed or the battery percentage moved by ≥0.2% since the last sample (throttling the sparkline buffer), capped at 50 samples. The buffer is cleared entirely once charging stops.

## Sequence: two refresh triggers arriving close together

```mermaid
sequenceDiagram
    participant Timer
    participant Manual as Manual refresh (user click)
    participant RC as RefreshCoordinator
    participant API as Provider actor

    Timer->>RC: refresh(trigger: .timer)
    RC->>RC: guard task == nil → passes, starts Task, generation = N
    RC->>API: fetchVehicleState(vin:features:)
    Manual->>RC: refresh(trigger: .manual)
    RC->>RC: guard task == nil → FAILS (task already set)
    Note over RC: manual trigger is dropped;<br/>caller will see the in-flight fetch's result
    API-->>RC: VehicleState (generation N still current)
    RC->>RC: apply(state) — merge, persist, reset backoff, schedule next timer
    RC-->>Timer: onState(state)
    RC-->>Manual: onState(state) (same callback, same value)
```

No duplicate API call is made — the manual click "rides along" on the timer-triggered fetch that was already in flight. See [refresh-system.md](refresh-system.md) for the coalescing mechanism in full and the retry/backoff formula for the failure case.
