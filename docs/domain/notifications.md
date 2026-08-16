# Notifications

`Services/Notifications/Notifier.swift` (`@MainActor`, `UNUserNotificationCenterDelegate`) + `ChargingTransitionDetector.swift` (pure state machine, see [domain/charging.md](charging.md)).

## Pipeline

```
New VehicleState arrives (RefreshCoordinator.onState)
        │
        ▼
Notifier.vehicleStateDidUpdate(state)
        │
        ├─ ChargingTransitionDetector.evaluate(baseline, state, lowBatteryThreshold)
        │       → (events, newBaseline)
        │  stateStore.save(newBaseline)   ← always persisted, even if notifications are off
        │
        ├─ gate: Preferences.features.contains(.notifications)
        │        && running as a real .app bundle && OS authorization granted
        │        (if any false, nothing posts below — but the baseline above was still saved)
        │
        ├─ for each ChargingEvent: post if the matching toggle is on
        │       .started      → notifyChargingStarted
        │       .completed    → notifyChargingComplete
        │       .fault        → notifyChargingProblem
        │       .interrupted  → notifyChargingProblem
        │       .lowBattery   → notifyLowBattery
        │
        ├─ checkRainWithWindows   (edge-triggered, independent of ChargingTransitionDetector)
        ├─ checkEveningUnlocked   (edge-triggered)
        ├─ checkSoftwareUpdate    (any state transition)
        └─ checkVehicleWarnings  + alarm edge
```

## Conditions, exactly

- **Rain/snow with a window open** — `weather.condition` contains (case-insensitive) `"rain"`, `"drizzle"`, `"shower"`, or `"snow"`, **and** `exteriorStatus.itemsNeedingAttention` contains something whose display name contains `"window"`. Fires only on the **false→true** transition (previous state didn't match, current does) — not on every poll while both conditions hold.
- **Parked and unlocked, evening** — `exteriorStatus.isLocked == false` **and** the local hour (from `state.fetchedAt`) is `>= 21` or `< 6`. Also edge-triggered.
- **Software update** — any change in `softwareInfo?.state` between polls. `.available`/`.downloaded` → "update available"; `.completed` → "updated"; `.failed` → "update failed"; other transitions are ignored.
- **New warnings** — the *set difference* of warning labels between polls (health-detail warnings, fluid warnings, plus a synthetic "Service warning" label if `serviceWarning` just became true), combined into one notification if any are new. Alarm triggering is a separate false→true edge check.
- **Low battery** — see [domain/charging.md](charging.md#low-battery-a-separate-hysteresis-not-part-of-the-state-machine).
- **Authentication required** — not tied to `vehicleStateDidUpdate` at all; triggered directly from `RefreshCoordinator.onError`/`onDiagnostics` via `Notifier.authenticationRequired()`/`authenticationSucceeded()`.

## Deduplication

Two independent mechanisms:

1. **Stable notification identifiers.** Every posted notification uses a deterministic identifier (`"hisingen.\(vin).\(component)"` — e.g. `.charging-started`, `.software`, `.vehicle-warnings`, `.alarm`), so `UNUserNotificationCenter` *replaces* rather than stacks a repeat of the same category for the same vehicle. Grouped into threads by category+VIN (`"hisingen.charging.\(vin)"`, `.weather`, `.security`, `.warnings`) so Notification Center visually collapses related alerts.
2. **Event fingerprinting in the state machine itself.** `ChargingTransitionDetector` fingerprints each surviving event as `vin|eventType|timestamp` and won't re-emit the same fingerprint twice — this catches the case where the same underlying vehicle sample gets polled and re-evaluated more than once.

Rain-with-windows and evening-unlocked notifications are edge-triggered (only fire on a false→true transition) rather than fingerprinted, which is a weaker but sufficient dedup for conditions that are inherently continuous rather than one-shot events.

## Per-VIN state

`Notifier.previousStateByVIN: [String: VehicleState]` and `ChargingBaseline` (persisted per VIN in `VehicleStateStore`) are both keyed by VIN — switching vehicles never carries one car's "already notified" state into another's. See [architecture/state-management.md](../architecture/state-management.md).

## Private notification mode

`Preferences.privateNotificationDetails` (default **true**). When enabled, charging/battery notification **bodies** are replaced with generic text ("Open Hisingen for details," "Your Polestar started/finished charging") — titles are never masked. **This does not apply to rain-with-windows or evening-unlocked notifications**, which always show full detail regardless of the private-mode toggle — a real inconsistency worth knowing about if a user asks why private mode "isn't working" for those two.

## Authorization

`Notifier` queries `UNUserNotificationCenter` authorization status at init and on `applicationDidBecomeActive`. There is **no automatic permission prompt at first launch** — `requestAuthorizationFromSettings()` (requesting `[.alert, .sound]` only, no badge) is only called from the Settings UI, when the user has a relevant notification toggle enabled. `willPresent` always returns `[.banner, .sound]`, so notifications show even while Hisingen is the frontmost app.

## Startup / restart behavior

No dedicated "don't notify on first launch after install" flag exists beyond the natural effect of two things: (1) authorization starts `.notDetermined` and nothing posts until the user opts in, and (2) the charging-baseline TTL (7 days, same as the telemetry cache) means a very old baseline is treated as "no baseline," so a stale-vs-fresh comparison after a long time away won't produce a spurious transition event. Disabling the Notifications feature entirely (`featureSelectionDidChange`) wipes all delivered and pending notifications and resets the auth-required dedup flag.
