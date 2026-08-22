# Glossary

Terms used throughout this documentation set that aren't self-explanatory
from context alone.

**AppFeature** — an enum of individually toggleable capabilities (e.g.
`.remoteClimate`, `.chargingSchedule`, `.vehicleImage`) that gates which data
a provider fetches and which UI is shown. `isRemoteControl` distinguishes
read-only features from ones that would dispatch a command.

**C3 / PCCS-Chronos** — the internal names used for Polestar's newer
gRPC-based vehicle-data API, which Hisingen talks to via a hand-rolled
client — see [ADR-0008](adr/0008-hand-rolled-grpc-no-swiftprotobuf.md).

**Capability staleness window** — the 6-hour period after which a
runtime-observed vehicle capability reverts to the static baseline if not
reconfirmed — see [ADR-0006](adr/0006-runtime-capability-probing.md).

**Developer ID** — the Apple code-signing certificate type used to sign
software distributed outside the Mac App Store. Required for notarization.

**Gatekeeper** — macOS's system that checks code signing and notarization
status before allowing a downloaded app to run; `spctl --assess` simulates
this check.

**Hardened runtime** — an Apple code-signing option (`codesign --options
runtime`) that restricts a process's own capabilities (e.g. blocks arbitrary
code injection into it); required for notarization.

**KeychainStore** — Hisingen's wrapper around the macOS Keychain
(`Services/Persistence/Keychain.swift`) used to store Polestar/Volvo
credentials and tokens — see [ADR-0004](adr/0004-keychain-for-credentials.md).

**LSUIElement** — the `Info.plist` key that makes Hisingen a menu-bar-only
"accessory" app: no Dock icon, no app switcher entry, no main menu bar.

**Notarization** — Apple's automated scan (`notarytool submit`) that a
signed app is submitted to before distribution outside the Mac App Store; a
successful result lets the app be "stapled" so Gatekeeper can verify it
offline.

**PKCE** (Proof Key for Code Exchange, RFC 7636) — the OAuth2 extension
Hisingen uses for the Volvo sign-in flow, avoiding the need for a client
secret to be embedded for the authorization step itself.

**Read-only integration test** — a Swift Testing suite (e.g.
`LivePolestarReadOnlyIntegrationTests`) that calls real vendor APIs with real
test-account credentials but never dispatches a state-changing command — see
[operations/releases.md](operations/releases.md#live-integrationyml).

**RefreshCoordinator** — the single `@MainActor` class that serializes all
vehicle-state refresh triggers (timer, manual, wake-from-sleep,
network-recovery) into one in-flight fetch per "generation," so they never
race each other.

**Stapling** — attaching Apple's notarization ticket directly to a signed
app or DMG (`xcrun stapler staple`) so Gatekeeper can verify it was
notarized even without a network connection at launch time.

**Universal binary** — a single executable containing both `arm64` and
`x86_64` code, produced via `lipo -create`, so one download runs natively on
both Apple Silicon and Intel Macs.

**VCC API key** — a Volvo Cars Connected (developer portal) API key,
required alongside OAuth client credentials to call Volvo's REST APIs.

**VehicleProviding** — the protocol both `PolestarAPI` and `VolvoAPI`
conform to, defining the one interface the rest of the app uses regardless
of vehicle brand — see [ADR-0003](adr/0003-shared-vehicle-domain-provider-dtos.md).

**VIN** (Vehicle Identification Number) — the key nearly all per-vehicle
state is scoped by — see [ADR-0007](adr/0007-vin-scoped-state.md). Treated as
sensitive: never logged or included in issue reports.

## Added 2026-08-22

**iTPMS** — indirect tyre-pressure monitoring: infers pressure loss from wheel-speed sensor
imbalance rather than in-wheel sensors. Reports a warning level per corner but has no numeric
pressure value. Polestar 2 (SPA platform) behaves this way over telematics.

**Wake reason** — why the vehicle's connectivity module is currently awake (scheduled climate,
active charging, telemetry poll), reported by the C3 DashboardService.

**Charge location** — a saved GPS position in Polestar's Chronos backend with per-location
charging settings (amp limit, minimum SoC, optimised-charging mode).

**Optimised charging mode** — per-location strategy: *intelligent timer* or *price-optimised*.

**SoH (State of Health)** — remaining usable battery capacity vs reference. Hisingen always
labels it a **calculated estimate**; neither provider exposes a BMS measurement.
