# ADR-0006: Runtime capability observation over static model assumptions

Status: Accepted

## Context

Which features a given vehicle actually supports (charging schedules,
climate timers, tyre-pressure sensors, air quality, and so on) varies by
model, model year, trim, and market, and isn't reliably knowable from a
static table alone — a table would either be too conservative (hiding
features a specific vehicle actually has) or too optimistic (showing UI for
data the vehicle never returns).

## Decision

Maintain a conservative static per-model capability table as a starting
point, and merge it with live observations recorded from actual API
responses as they arrive. An observation is treated as stale, and reverts to
the static baseline, after `VehicleCapabilities.stalenessInterval` — 6 hours
(`6 * 3_600` seconds) — so capability display self-corrects rather than
freezing on a first impression.

## Alternatives considered

- **Pure static table** — breaks silently whenever a real vehicle doesn't
  match the assumed trim/market, with no way to recover without an app
  update.
- **Pure runtime-only (no static table)** — no capability information at all
  until the first successful fetch, a materially worse cold-start
  experience.

## Consequences

Capability display converges to reality within a session even when the
static table is wrong for a specific vehicle, without requiring an app
update. This requires care in one specific direction: a single *failed*
request must never be read as "unsupported" and overwrite a previously
good observation — only a successful response is allowed to update
capability state. See [architecture/capabilities.md](../architecture/capabilities.md)
for the merge logic and [domain/capability-matrix.md](../domain/capability-matrix.md)
for the static baseline table itself.
