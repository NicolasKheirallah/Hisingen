# Technical Debt

Real findings from reading the implementation, not a wishlist. Severity is about impact if it goes wrong, not how hard it is to fix.

## Known remaining debt (post 2026-08 hardening pass)

The items below survived the August 2026 reliability/security pass on purpose: each needs
design work or visual verification rather than a mechanical fix. Everything else from that
audit (SQLITE_TRANSIENT binds, Keychain migration ordering, refresh credential recovery,
`PRAGMA user_version` migrations, transactional wipes/prunes, session epoch guards, hot-key
modifier gating, dead `Preferences` removal) landed in code.

1. **Large implementation files remain.** `HisingenContentView.swift` and
   `VehicleDatabase.swift` are still large. `CommandCoordinator`, `VehicleSessionController`,
   and `VehicleHistoryRecorder` now hide their end-to-end workflows behind smaller interfaces,
   so future work should deepen a concrete query/export workflow when it changes rather than
   mechanically splitting SQL into shallow repository wrappers.

2. **Scripted PingFederate sign-in** (`PolestarAPI.obtainAuthorizationCode`) scrapes the
   login form's HTML with regexes. Any PingFederate redesign breaks it with a generic error.
   It should move behind a protocol so the browser-based flow used for remote commands can
   replace it without touching the API core.

3. **Volvo telemetry fan-out.** A single Volvo refresh issues up to ~15 parallel GETs plus
   capabilities and images. Correct per endpoint, but a refresh coordinator-level budget or
   stagger would protect against future rate-limit tightening.

4. **Test coverage gaps.** Auth/token-refresh and old-schema migration paths now have direct
   regression coverage. Still missing: Notifier privacy-body branches, Sparkle end-to-end
   signed-feed staging coverage, and AppIntents dialogs.

5. **Localization of Shortcuts dialogs.** All `AppIntents` user-facing strings are English
   only; every other surface resolves through `L10n`.
