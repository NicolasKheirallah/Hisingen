# Technical Debt

Real findings from reading the implementation, not a wishlist. Severity is about impact if it goes wrong, not how hard it is to fix.

## Known remaining debt (post 2026-08 hardening pass)

The items below survived the August 2026 reliability/security pass on purpose: each needs
design work or visual verification rather than a mechanical fix. Everything else from that
audit (SQLITE_TRANSIENT binds, Keychain migration ordering, refresh credential recovery,
`PRAGMA user_version` migrations, transactional wipes/prunes, session epoch guards, hot-key
modifier gating, dead `Preferences` removal) landed in code.

1. **God files.** `AppDelegate.swift` (~1k lines), `HisingenContentView.swift` (~3k lines),
   and `VehicleDatabase.swift` (~1.5k lines) still carry too many responsibilities.
   `SessionManager` extracted the duplicated credential assembly; the next extractions are a
   command coordinator out of AppDelegate and per-card view files plus a repository split
   (`Schema` / `HistoryRepository` / `AuditRepository` / `Exporter`) for VehicleDatabase.
   Both are mechanical but need UI verification time.

2. **`VehicleState` is a 60+-property flat struct.** Adding one field touches the property
   list, the memberwise init, `CodingKeys`, hand-written `init(from:)`, `cacheableCopy`,
   and `mergingLastKnown`. Nested sub-structs (the pattern `ExteriorSnapshot` already uses)
   would let whole blocks merge wholesale instead of line-by-line `??`.

3. **Scripted PingFederate sign-in** (`PolestarAPI.obtainAuthorizationCode`) scrapes the
   login form's HTML with regexes. Any PingFederate redesign breaks it with a generic error.
   It should move behind a protocol so the browser-based flow used for remote commands can
   replace it without touching the API core.

4. **Volvo telemetry fan-out.** A single Volvo refresh issues up to ~15 parallel GETs plus
   capabilities and images. Correct per endpoint, but a refresh coordinator-level budget or
   stagger would protect against future rate-limit tightening.

5. **Test coverage gaps.** Auth/token-refresh lifecycle is now covered by
   `RefreshCoordinatorTests.testTokenExpiryMidRunRecoversSessionFromStorage`; still missing:
   schema-migration fixtures exercising an old database through the `user_version` path,
   Notifier privacy-body branches, UpdateChecker semver edge cases, AppIntents dialogs.

6. **Localization of Shortcuts dialogs.** All `AppIntents` user-facing strings are English
   only; every other surface resolves through `L10n`.
