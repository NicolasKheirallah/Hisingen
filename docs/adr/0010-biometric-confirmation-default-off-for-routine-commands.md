# ADR-0010: Biometric confirmation defaults off for routine remote commands

Status: Accepted

## Context

`RemoteActionAuthorizer.authorize(_:vehicle:)` gates every remote command
behind two independent checks:

1. A confirmation dialog (`NSAlert`, naming the exact command and vehicle),
   shown whenever `command.risk != .routine` **or** the user has turned on
   `requireBiometricsForRemoteControls`.
2. Device-owner authentication (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`
   — Touch ID or the account password), required whenever
   `requireBiometricsForRemoteControls` is on **or**
   `command.risk.requiresDeviceOwnerAuthentication` is true.

`RemoteCommand.risk` (`Domain/RemoteCommand.swift`) sorts every command into
one of three tiers:

- `.securitySensitive` — `unlock`, `unlockTrunk`, `openTailgate`, `openWindows`, `startEngine`
- `.destructive` — `installOTANow`, `deleteClimateTimer`
- `.routine` — everything else, including `lock`, `startClimate`/`stopClimate`,
  `flashLights`/`honkAndFlash`, `setChargeTarget`, `setAmpLimit`,
  `startChargingOverride`/`stopChargingOverride`, `scheduleOTA`, `cancelOTA`

`requireBiometricsForRemoteControls` (`PreferencesStore.swift`) is a plain
`UserDefaults` boolean with **no explicit default registered**, which means
it reads as `false` until the user turns it on in Settings.

The practical consequence: out of the box, a routine command — lock, start
climate, honk, change the charge target — fires from a single unconfirmed
click, with no dialog and no biometric/password check. Only the five
security-sensitive commands and the two destructive ones require
confirmation and device-owner authentication by default.

This was flagged as worth an explicit decision during a broader API/security
review (2026-08), rather than left as an implicit default someone could
mistake for an oversight.

## Decision

Keep the default as-is: `requireBiometricsForRemoteControls` defaults to
`false`, and only `.securitySensitive`/`.destructive` commands are gated by
default. The reasoning:

- The commands gated by default are exactly the ones with a plausible
  safety or property angle — unlocking the car, opening it up, or starting
  the engine are the cases where an attacker with momentary access to an
  unlocked, unattended Mac could cause real-world harm or theft risk.
  Locking the car, starting climate, or nudging a charge target are
  inconvenient if misused, not dangerous.
- Every command, regardless of tier, still goes through `RemoteActionAuthorizer`
  — routine commands are not unauthenticated, they're just not re-confirmed
  on top of the app's own access control (the Mac's own login/unlock is the
  first gate; Hisingen's biometric check is a second one, reserved for the
  commands where a second gate earns its friction).
- Requiring Touch ID for every single routine command (a very common
  interaction — checking in on charging, running climate before a trip)
  would make the app meaningfully more annoying to use for its most
  frequent operations, for a marginal security gain given the Mac itself is
  already access-controlled.

## Alternatives considered

- **Require biometrics for every remote command by default.** Rejected: the
  friction cost lands on the highest-frequency interactions (climate,
  honk/flash, charge target) while providing little additional protection
  beyond what the Mac's own lock screen already provides for those
  low-consequence actions.
- **Drop the routine/security-sensitive/destructive distinction and use a
  single global toggle only.** Rejected: this either forces every user into
  the "biometrics for everything" friction, or leaves unlock/engine-start
  unconfirmed for users who never visit Settings — the tiered default is
  strictly safer than a single global switch defaulting to off.
- **Add a cooldown or rate limit on top of confirmation, instead of/alongside
  biometrics.** Not rejected, just out of scope for this ADR — a per-command
  minimum interval would address a different threat (rapid repeated
  commands) than device-owner authentication does (a single unauthorized
  command from an unattended, unlocked Mac). Tracked as a separate,
  unimplemented idea, not a decision made here.

## Consequences

A compromised or borrowed, already-unlocked Mac running Hisingen can lock
the vehicle, start/stop climate, honk/flash, or adjust charging with a
single click and no further authentication. This is accepted as a
reasonable default given the commands involved are not safety- or
theft-relevant. Users who want stricter behavior can turn on "Require Touch
ID for Remote Controls" in Settings, which applies device-owner
authentication uniformly to every command regardless of tier — that path
already exists and is unaffected by this ADR.

If real-world reports establish this default is being relied on for actual
account/vehicle compromise (not just theoretical unattended-Mac access),
revisit the default rather than only the documentation.
