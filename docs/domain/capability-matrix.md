# Capability Matrix

The static per-model fallback table from `VehicleCapabilityProfile.support(for:)`, plus what's actually verified vs. assumed. This is the fallback used when no live runtime probe exists yet — see [architecture/capabilities.md](../architecture/capabilities.md) for how a live probe overrides it. States: **Verified** (confirmed correct across multiple real vehicles/reports), **Expected** (the static default, plausible but not exhaustively confirmed), **Runtime detected** (only ever known via a live probe, no static default), **Best effort** (`.backendDependent` — deliberately "ask, don't assume"), **Unsupported** (static negative — `.unavailable`), **Unknown** (no claim made either way).

## Polestar

| Capability | Polestar 1 | Polestar 2 | Polestar 3 | Polestar 4 | Polestar 5 / 6 |
|---|---|---|---|---|---|
| Climate start/stop | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Climate temperature selection | Best effort | **Unsupported** (vehicle-managed) | Expected (supported) | Expected (supported) | Best effort |
| Seat / steering-wheel heating selection | Best effort | **Unsupported** (vehicle-managed) | Expected (supported) | Expected (supported) | Best effort |
| Climate timers | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Pre-cleaning | Best effort | Expected (supported) | Best effort | **Unsupported** | Best effort |
| Charge target | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Charging current limit | Best effort | Expected (supported) | Best effort | **Unsupported** | Best effort |
| Charging schedule / override | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Locks / trunk / windows / honk-flash | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Exterior status (doors/windows/lock) | Best effort | Expected (supported) | Expected (supported) | Expected (supported) | Best effort |
| Direct tyre-pressure values | Best effort | **Verified** (kPa decoded) | Expected (supported) | Expected (supported) | Best effort |
| Service / vehicle warnings | Best effort | **Verified** (live decoded) | Expected (supported) | Expected (supported) | Best effort |
| Trip meters | Best effort | **Verified** (live decoded) | Expected (supported) | Expected (supported) | Best effort |
| Connectivity diagnostics | Best effort | **Verified** (live decoded) | Best effort | **Unsupported** | Best effort |
| Software status | Best effort | **Verified** (live decoded) | Expected (supported) | Best effort | Best effort |
| Software install control | Best effort | **Verified** (state-gated) | Best effort | **Unsupported** | Best effort |
| Software install/cancel (OTA writes) | Best effort | **Verified** (state-gated) | Best effort | **Unsupported** | Best effort |
| Remote commands (climate/locks/windows/honk/charging/timers) | Best effort | **Verified** (all live verified) | Best effort | Best effort | Best effort |

Per Hisingen's own README: Polestar 1 needs "broad live verification"; Polestar 2 is "model-aware... direct tyre pressure and selectable climate temperature are not assumed"; Polestar 3 has "runtime confirmation for backend-dependent capabilities"; Polestar 4 has "Digital Twin support; current limit, pre-cleaning, legacy connectivity, and remote OTA are not assumed"; Polestar 5/6 are "conservative backend-dependent" with only positive runtime observations trusted. Future/unrecognized Polestar models preserve their name and remain fully probeable rather than being rejected.

## Volvo

All Volvo models (XC40, XC60, XC90, S60, S90, V60, V90, C40, EX30, EX90, ES90) share one static profile — Hisingen does not currently differentiate Volvo capability defaults by model, only by live probe result:

| Capability | Static default | Notes |
|---|---|---|
| Locks | Expected (supported) | |
| Honk & flash | Expected (supported) | |
| Exterior status | Expected (supported) | |
| Climate start/stop | Expected (supported) | |
| Service warnings | Expected (supported) | |
| Software install control | **Unsupported** | No Volvo OTA endpoint is used — see [architecture/technical-debt.md](../architecture/technical-debt.md#volvo-software-info-is-synthetic-not-derived-from-any-api) |
| Direct tyre-pressure values | **Unsupported** | Volvo's `tyres` endpoint is indirect TPMS (inferred from wheel-speed-sensor imbalance, not a per-wheel pressure sensor) and returns a warning enum only — there is no numeric kPa/PSI field on any Volvo model, so this is a static negative rather than `.backendDependent`. Tyre *warning* status itself (OK/low/very low/high) is still fully supported and displayed; only the numeric-value capability is unavailable. |
| Charge target | Runtime detected | Only ever `.supported`/`.unavailable` once the Energy Capabilities endpoint has been probed; `.backendDependent` before that |
| Charging current limit | Runtime detected | Same as above |
| Everything else (windows, trunk, seat/steering heating, climate temperature, schedules, trip meters, connectivity, climate timers) | Best effort | `.backendDependent` — no static claim either way |
| Remote command execution | Runtime-implemented for 6 of ~20 commands | Lock, unlock, climate start/stop, honk-flash, flash-lights work; everything else returns `RemoteCommandError.unsupported` regardless of capability state — see [api/volvo.md](../api/volvo.md#remote-commands) |

## What this table doesn't claim

Nothing here asserts that a given model *works end-to-end* in Hisingen — it asserts what the static fallback table says about that model's capability set when no live observation exists yet. A specific vehicle's actual behavior always wins once observed (a live probe overriding a "Best effort" default to "Verified-equivalent" for that VIN, cached for up to 6 hours — see [architecture/capabilities.md](../architecture/capabilities.md)). Do not extend this table with new "Verified" claims without a live report backing them; add "Expected" or "Best effort" instead and let runtime probing do the confirming.
