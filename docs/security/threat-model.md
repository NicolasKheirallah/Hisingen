# Threat Model

A lightweight, practical pass — not a compliance exercise. Scope: the Hisingen macOS app itself, its two vehicle-provider integrations, and its release pipeline. Out of scope: Polestar's and Volvo's own backend security, which Hisingen has no visibility into or control over.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Polestar/Volvo refresh tokens | Keychain | Long-lived account access; theft gives ongoing read access to vehicle telemetry and (if scopes allow) commands |
| Polestar password | Keychain | Direct account takeover if stolen |
| Volvo client secret / VCC API key | Keychain | Account/app-level access to the user's Developer Portal application |
| Vehicle location | In-memory, `UserDefaults` cache (stripped in the cached copy — see below), opt-in third-party calls | Physical safety/privacy implication if disclosed |
| Vehicle state (battery, locks, warnings) | `UserDefaults` cache | Privacy; also security-relevant (lock state) |
| VIN | Cached state, notification identifiers, logs (never full state) | Identifies a specific physical vehicle |
| Account information (email, nickname) | `UserDefaults`/Keychain | Privacy |
| Future/experimental remote-control credentials or capability | Compile-time flag, in-memory only today | If ever enabled broadly, would allow physical vehicle actuation |
| Release artifacts (`Hisingen.dmg`, `Hisingen.zip`) | GitHub Releases | Supply-chain integrity — a tampered build would run with the user's Polestar/Volvo credentials |

## Threats (STRIDE, where it actually helps)

### Spoofing

- **Threat:** a malicious page or app intercepts the OAuth callback and impersonates Hisingen to capture an authorization code.
  **Mitigation:** PKCE on both providers (a stolen `code` is useless without the matching `code_verifier`, which never leaves the process). Polestar's redirect capture is scoped to an exact scheme/host/path match. Volvo's callback lands on Hisingen's own registered `hisingen://` URL scheme, which macOS restricts to the app that registered it — but see the open-redirect note below.
- **Threat:** a spoofed OIDC discovery document redirects Polestar login to an attacker-controlled endpoint.
  **Mitigation:** every URL from `.well-known/openid-configuration` is validated to be `https` and on a `polestar.com` (sub)domain before use.

### Tampering

- **Threat:** a modified/tampered Hisingen build is distributed and used to harvest credentials.
  **Mitigation:** release builds are Developer ID signed, hardened-runtime, notarized, and stapled; `spctl --assess` and checksum verification happen as part of the release pipeline itself. Ad-hoc local builds (`make app`) are explicitly *not* trusted the same way and re-signing on every rebuild is a known friction point (see [operations/troubleshooting.md](../operations/troubleshooting.md)) rather than a hidden risk — the tradeoff is documented, not silent.
- **Threat:** a malicious/compromised vehicle-API response is decoded into a value that corrupts app state or crashes the process.
  **Mitigation:** all decoding uses `Codable`/`try?` with graceful degradation (a decode failure removes that one field, doesn't crash); response size is capped (`HTTPBodyReader`, 5MB image limit, 512KB update-check limit) to bound memory use from a malicious or broken response.

### Repudiation

Not a meaningful category here — there's no multi-party transaction log to dispute; the closest analog is remote-command confirmation, covered under "remote control surface" below.

### Information Disclosure

- **Threat:** Keychain items readable by another process or after device compromise.
  **Mitigation:** `ThisDeviceOnly` accessibility (no iCloud sync), scoped to the app's own Keychain access group by default macOS behavior. See [keychain.md](keychain.md) for the specific accessibility-level discrepancy between docs and code.
- **Threat:** the on-disk telemetry cache leaks PII if the Mac (or a backup of it) is compromised.
  **Mitigation:** `VehicleState.cacheableCopy` strips registration number, owner name, odometer/service details, fluid warnings, weather, and image data before persistence; precise saved-location coordinates are discarded before they ever reach the domain model. What remains cached (VIN, battery%, charging state) is a deliberate, smaller trade-off, not an oversight — see [privacy.md](privacy.md).
- **Threat:** vehicle coordinates leak to a third party unexpectedly.
  **Mitigation:** reverse geocoding (Apple) and weather (Open-Meteo) are both opt-in per feature toggle, and Hisingen's own FAQ discloses this directly to the user rather than burying it.
- **Threat:** logs capture a token or full vehicle payload.
  **Mitigation:** convention-based, not tooling-enforced — see [security/overview.md](overview.md#logs).

### Denial of Service

- Out of Hisingen's control in the sense that Polestar/Volvo could rate-limit or block a client — Hisingen's own behavior here is *defensive*, not offensive: exponential backoff with jitter, `Retry-After` compliance (Polestar), and per-capability cooldowns exist specifically so Hisingen doesn't become a source of excess load against either backend. See [architecture/refresh-system.md](../architecture/refresh-system.md).

### Elevation of Privilege

- **Threat:** a remote command executes without the user's knowledge or consent.
  **Mitigation:** see "remote control surface" below — this is the most deliberately hardened part of the app specifically because the blast radius (an actual vehicle actuation) is the highest of anything Hisingen does.
- **Threat:** a compromised dependency introduces malicious code.
  **Mitigation:** Hisingen has **zero external Swift package dependencies** — `Package.swift` declares no `dependencies:` array at all. The hand-rolled gRPC/protobuf implementation exists in part because pulling in `SwiftProtobuf`/a C++ gRPC runtime was avoided; whatever the original motivation, the practical security consequence is a much smaller supply-chain surface than a typical networked macOS app.

## Remote control surface

The single highest-consequence capability in the app, and the most explicitly guarded:

1. **Compiled out entirely in distributed builds.** `HISINGEN_EXPERIMENTAL_REMOTE` is a Swift compile flag, not a runtime toggle — it's never set in CI or release builds (`Package.swift`), so a downloaded release binary has no code path capable of dispatching a Polestar vehicle command at all.
2. **Even with the flag set locally**, Polestar's backend is expected to reject unpaired-client write RPCs (`grpc-status 16`), so enabling the flag for local experimentation doesn't grant working remote control against the real backend today — it's a development scaffold, not a bypass.
3. **Volvo's remote commands are always compiled in** (no equivalent flag) but only 6 of ~20 `RemoteCommand` cases are actually implemented, and the UI currently disables all Volvo controls in the shipped build regardless (`ControlsTabView`'s `isBrandVolvo` gate is present in code but every control is still hardcoded off pending further verification — see [architecture/technical-debt.md](../architecture/technical-debt.md)).
4. **Every command, when reachable, requires an explicit confirmation dialog** (`RemoteActionAuthorizer`, `NSAlert`) naming the exact vehicle and command.
5. **Security-sensitive and destructive commands additionally require local device-owner authentication** (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` — Touch ID or the Mac's own login password) before dispatch. Routine commands (lock, climate start) skip this and rely on the confirmation dialog alone.
6. **A backend acknowledgment is never treated as confirmed execution** — `RemoteCommandOutcome` distinguishes `.accepted`/`.delivered`/`.completed`, and TERMS.md is explicit that Hisingen does not guarantee a command was actually executed by the vehicle. The one place this line blurs is the optimistic local-state patch on four commands — see [architecture/technical-debt.md](../architecture/technical-debt.md#optimistic-local-state-patch-on-remote-commands-vs-ack-execution-stance).

## Open redirect note (Volvo bridge page)

`docs/oauth-callback.html` (served from GitHub Pages) forwards its entire query string verbatim to `hisingen://oauth/volvo/callback`. Because Hisingen validates the OAuth `state` parameter after receiving the callback, an attacker who could get a user to visit that bridge page with a crafted query string couldn't complete a real sign-in (no valid `code`/`state` pair without going through Volvo's actual authorization server) — but this is worth naming explicitly as a control that depends on `state` validation happening correctly on the receiving end, not on the bridge page itself doing any validation (it does none, by design — it's a dumb pass-through).

## Not modeled here

Physical vehicle security (locks, alarm, actual driving systems) is Polestar's/Volvo's responsibility, not Hisingen's — Hisingen is a read-mostly telemetry client, and its threat surface is credential handling, local caching, and (for the narrow, gated remote-control path) command confirmation — not vehicle firmware or CAN-bus security.
