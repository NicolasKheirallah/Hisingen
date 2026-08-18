# ADR-0009: Remote commands are compiled into all builds

Status: Accepted — supersedes [ADR-0005](0005-read-only-remote-controls-by-default.md)

## Context

ADR-0005 gated every Polestar remote-command dispatch behind the
`HISINGEN_EXPERIMENTAL_REMOTE` compile flag, on the premise — recorded in
`Package.swift` — that "Polestar currently requires official paired-mobile
authorization for these commands." That premise turned out to be a
consequence of how Hisingen authenticated, not a property of the backend.

Hisingen was requesting only the read scope `openid profile email
customer:attributes`. Adding `customer:attributes:write` to the same
polestar.com web client (`l3oopkc_10`) is accepted by the authorization
server and does not disturb vehicle discovery — verified live. Software-update
dispatch (`ota_mobcache.SchedulerService/{Schedule,InstallNow,CancelSchedule}`
on C3) then reaches the backend and is answered on its merits rather than
refused, so the blanket "unpaired clients are rejected" reading no longer
holds.

(The Polestar mobile-app client `lp8dyrd_10` was evaluated and rejected: its
token is not accepted by `mystar-v2`, which breaks vehicle discovery entirely.
See [api/polestar.md](../api/polestar.md#remote-commands).)

Keeping the flag meant the OTA install control could never work in a build
anyone actually runs: `PolestarAPI.executeRemoteCommand` threw
`RemoteCommandError.unsupported` before touching the network.

## Decision

Remove `HISINGEN_EXPERIMENTAL_REMOTE` entirely. `Package.swift` no longer
defines it and `PolestarAPI.executeRemoteCommand` no longer branches on it,
so remote-command dispatch is compiled into every build including releases.

The protections that remain are runtime, not compile-time:

- **Per-feature opt-in.** Each remote capability is an `AppFeature` the user
  must enable in Settings; `FeatureSelection.default` enables none of them,
  and `AppDelegate.performRemoteCommand` refuses anything whose feature is
  off.
- **Capability gating.** `VehicleCapabilityProfile.permits(_:)` rejects a
  command the model cannot accept before any network call.
- **Local device-owner authentication.** `RemoteActionAuthorizer` requires
  Touch ID or the Mac password for every non-routine command;
  `installOTANow` is classified `.destructive` and always prompts.
- **Client-side validation.** Bounds (charge target 40–100%, amp limit
  1–64 A, OTA delay 1–1440 min) are enforced before dispatch.

## Consequences

A downloaded release binary now *does* contain code capable of issuing a
vehicle command, which ADR-0005 deliberately prevented "by construction, not
by configuration." That guarantee is replaced by the runtime chain above.
Anyone relying on the old property — that no distributed build could act on a
vehicle at all — needs to know it no longer holds.

CI keeps `--skip Live` so no automated run dispatches a live command; that
safeguard is unaffected and remains the reason the remote paths still get
less automated coverage than read-only ones.

Commands other than OTA remain unreachable from the UI: `ControlsTabView`
still hardcodes Polestar's lock/window/climate/charging buttons to
`.disabled(true)`, and their PCCS request paths are unverified — see