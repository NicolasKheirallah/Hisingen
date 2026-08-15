# ADR-0005: Read-only by default; remote control gated behind an experimental compile flag

Status: Accepted

## Context

Remote commands (lock/unlock, climate, charging schedule changes) are real,
physical, state-changing actions on someone's vehicle, dispatched from
third-party (non-vendor-official) software. Polestar in particular currently
requires official paired-mobile authorization for these commands — see the
comment in `Package.swift` above `HISINGEN_EXPERIMENTAL_REMOTE`. Shipping
this capability by default, or even as a hidden settings toggle, means every
distributed build carries code that can act on a real vehicle.

## Decision

Gate all remote-command dispatch code behind a compile-time Swift flag,
`HISINGEN_EXPERIMENTAL_REMOTE` (`.define("HISINGEN_EXPERIMENTAL_REMOTE")` in
`Package.swift`, applied only when that environment variable is `"1"` at
build time). Standard builds — including every CI build and every release
build — never set it, so the remote-command code path is not compiled into
any distributed binary at all. Enabling it requires a developer to build
from source with the flag deliberately set, for owner-authorized
experimentation.

## Alternatives considered

- **Runtime feature flag / hidden settings toggle** — ships the
  remote-command code path in every distributed build regardless of default
  state, so a bug, a misconfigured default, or an unlocked settings screen
  could enable vehicle control unintentionally. A compile-time flag removes
  that class of risk entirely rather than defending against it at runtime.

## Consequences

No build a user downloads from a GitHub Release — or that CI produces — can
issue a vehicle command, by construction, not by configuration. This extends
into the CI/CD pipeline itself: `ci.yml` and `release.yml` never set the
flag, and additionally run tests with `--skip Live` as defense-in-depth so
the one Swift Testing suite that does dispatch a live remote command
(`LivePolestarRemoteCommandIntegrationTests`) can never run from automation —
see [operations/ci.md](../operations/ci.md). The cost: remote-control code
paths get materially less automated test coverage than read-only code paths,
since they're excluded from every standard build and CI run.
