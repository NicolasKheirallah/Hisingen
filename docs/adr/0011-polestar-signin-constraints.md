# ADR-0011: Polestar Sign-In Architecture Constraints

Date: 2026-08-22 · Status: Accepted (documents current constraints; replacement flow is
future work requiring live verification)

## Context

Hisingen authenticates against Polestar ID with two OAuth clients, and the two are not
interchangeable — verified live against a real account:

| Client | ID | Redirect URI | Reads (`mystar-v2` GraphQL) | Commands (C3 invocation) |
|---|---|---|---|---|
| Web (`polestar.com`) | `l3oopkc_10` | `https://www.polestar.com/sign-in-callback` | ✓ | ✗ (`Client id … is not a required client id`) |
| Mobile app | `lp8dyrd_10` | `polestar-explore://explore.polestar.com` | ✗ (`UnauthorizedException`) | ✓ |

Consequences:

1. **Vehicle discovery and telemetry require the web client**, whose redirect lands on an
   HTTPS page on `polestar.com`. `ASWebAuthenticationSession` can only hand back redirects to
   a custom scheme (or an associated domain Hisingen controls) — Polestar's domain is neither,
   so a standards-compliant browser handoff is impossible for this client today.
2. Hisingen therefore scripts the PingFederate login form itself inside its own URLSession
   (`PolestarAPI.performLogin`, form fields `pf.username`/`pf.pass`), capturing the
   authorization code from the redirect before it leaves the session.
3. **Remote commands require the mobile client.** Its custom-scheme redirect works with the OS
   and is already browser-based via `ASWebAuthenticationSession`
   (`PolestarCommandSignInPresenter`) — Hisingen never sees that password.

The scripted form-fill means the primary session's password must persist in Keychain so a dead
refresh token can be replayed into a fresh login without user interaction.

## Decision

- Keep the scripted web-client flow for reads until one of the triggers below fires; the risk
  is documented rather than silently carried.
- Keep the command client on the real-browser flow.
- Do not add flows that bypass or weaken Polestar ID's own authentication (no MFA automation,
  no captcha solving, no credential stuffing resilience beyond honest error reporting).

## Triggers for revisiting

1. Polestar publishes a supported third-party API (EU Data Act pressure continues; the Data
   Portal currently exposes human-readable snapshots only).
2. Polestar registers a custom-scheme or associated-domain redirect usable by third parties.
3. The PingFederate form contract changes (MFA rollout, resume-path format), which breaks the
   scripted flow anyway and forces the redesign.

## Consequences

- Password replay is the single most sensitive credential operation in the app: it is stored
  with `AfterFirstUnlockThisDeviceOnly`, cleared on sign-out, wiped by `wipeAll`, never logged,
  and never included in diagnostic exports.
- A future migration to browser-first for both clients removes the long-term password storage
  requirement entirely; that is the target end-state.
