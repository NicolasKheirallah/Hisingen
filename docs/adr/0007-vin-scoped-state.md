# ADR-0007: VIN-scoped state throughout, not account- or session-scoped

Status: Accepted

## Context

A single Polestar or Volvo account can have more than one vehicle. Cached
vehicle state, charging baselines, capability observations, and notification
dedup state all need to avoid bleeding between vehicles when the user
switches the selected car — showing one vehicle's cached battery level or
notification history against another vehicle would be a real, user-visible
bug.

## Decision

Key all per-vehicle state by VIN. `VehicleStateStore` stores snapshots and
charging baselines as `[String: VehicleState]` / `[String: ChargingBaseline]`
dictionaries keyed by VIN (`snapshot(for vin:)`, `baseline(for vin:)`, and a
scoped `clear(vin:)`). Capability observations and notification dedup state
follow the same pattern.

## Alternatives considered

- **Single-vehicle-assumption global state** — simpler for the common
  single-car account, but breaks multi-vehicle accounts outright and would
  surface stale or wrong-vehicle data on every switch.

## Consequences

Switching the selected vehicle in the UI doesn't require re-fetching
everything from scratch, and doesn't leak one vehicle's cached data into
another's display. The one deliberate exception is credentials
([0004](0004-keychain-for-credentials.md)): those are keyed by brand account,
not VIN, since a login session authenticates an account, not an individual
vehicle. See [architecture/state-management.md](../architecture/state-management.md).
