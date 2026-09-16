# Glossary

Terms used throughout this documentation set that aren't self-explanatory
from context alone.

**AppFeature**: an enum of individually toggleable capabilities (e.g.
`.remoteClimate`, `.chargingSchedule`, `.vehicleImage`) that gates which data
a provider fetches and which UI is shown. `isRemoteControl` distinguishes
read-only features from ones that would dispatch a command.

**C3 / PCCS-Chronos**: the internal names used for Polestar's newer
gRPC-based vehicle-data API, which Hisingen talks to via a hand-rolled
client; see [ADR-0008](adr/0008-hand-rolled-grpc-no-swiftprotobuf.md).

**Capability staleness window**: the 6-hour period after which a
runtime-observed vehicle capability reverts to the static baseline if not
reconfirmed; see [ADR-0006](adr/0006-runtime-capability-probing.md).

**Developer ID**: the Apple code-signing certificate type used to sign
software distributed outside the Mac App Store. Required for notarization.

**Remote Command dispatch**: the awaited seam every Remote Command entry
point (Controls tab, `hisingen://` deep links, Shortcuts intents) crosses once
the app shell is wired: vehicle selection plus one dispatch that returns the
outcome. Brand policy lives in `CapabilityGate` and the provider command
catalog, never in an entry point; see
[ADR-0012](adr/0012-single-remote-command-dispatch-authority.md).

**Command receipt**: the display-only record of an accepted Remote Command in any lifecycle
state: awaiting confirmation, provider-acknowledged (when no observable reading exists), confirmed,
or timed out. `CommandReceiptLedger` owns the lifecycle — filing against the Remote Command
target, confirmation, suspension, timeout, dismissal, and relaunch restore — while
`RefreshCoordinator` carries out the transport the ledger asks for. A bounded per-vehicle receipt
collection survives relaunch; provider telemetry and persisted vehicle snapshots never own the
receipts.

**CommandReceiptLedger**: the module that owns the Command receipt lifecycle end to end: filing a
receipt under the selected VIN or under the Remote Command target's VIN, the records and their
confirmation deadlines, suspension across sleep or brand switches, the timeout transition,
individual dismissal, relaunch restore, the display fields an awaiting command still owns, and
which transport could prove it. See
`Services/Coordination/CommandReceiptLedger.swift`.

**Remote Command target**: the vehicle identity and provider captured when a command is approved.
It stays fixed until execution completes, even if the visible vehicle selection changes;
`CommandReceiptLedger` files the receipt against this VIN rather than the selection's.

**Gatekeeper**: macOS's system that checks code signing and notarization
status before allowing a downloaded app to run; `spctl --assess` simulates
this check.

**Charging Session ledger**: the module that owns the Charging Session
lifecycle: it ingests observations into `charging_samples`, advances
`charging_sessions` through its explicit states, produces each session's
authoritative energy summary, and is the one place where sample integration
and its gap-tolerance policies live. See
`Services/Persistence/ChargingSessionLedger.swift`.

**Vehicle History ledger**: the read interface over the remaining local
history tables (battery health, air quality, telemetry, trips, Remote Command
outcomes, connectivity, cabin climate, fuel entries): one typed surface that
assembles the History dashboard and Info tab bundles and owns the row-cap and
freshness policy those consumers used to re-derive at every call site. See
`Services/Persistence/VehicleHistoryLedger.swift`.

**Hardened runtime**: an Apple code-signing option (`codesign --options
runtime`) that restricts a process's own capabilities (e.g. blocks arbitrary
code injection into it); required for notarization.

**KeychainStore**: Hisingen's wrapper around the macOS Keychain
(`Services/Persistence/Keychain.swift`) used to store Polestar/Volvo
credentials and tokens; see [ADR-0004](adr/0004-keychain-for-credentials.md).

**LSUIElement**: the `Info.plist` key that makes Hisingen a menu-bar-only
"accessory" app: no Dock icon, no app switcher entry, no main menu bar.

**Notarization**: Apple's automated scan (`notarytool submit`) that a
signed app is submitted to before distribution outside the Mac App Store; a
successful result lets the app be "stapled" so Gatekeeper can verify it
offline.

**PKCE** (Proof Key for Code Exchange, RFC 7636): the OAuth2 extension
Hisingen uses for the Volvo sign-in flow, avoiding the need for a client
secret to be embedded for the authorization step itself.

**Read-only integration test**: a Swift Testing suite (e.g.
`LivePolestarReadOnlyIntegrationTests`) that calls real vendor APIs with real
test-account credentials but never dispatches a state-changing command; see
[operations/releases.md](operations/releases.md#live-integrationyml).

**RefreshCoordinator**: the single `@MainActor` class that serializes all
vehicle-state refresh triggers (timer, manual, wake-from-sleep,
network-recovery) into one in-flight fetch per "generation," so they never
race each other.

**Command overlay**: the display-only part of Vehicle State — the Command receipts on screen and the
optimistic lock a just-accepted command claimed (`CommandPresentationState`). `CommandReceiptLedger`
produces it and `Domain/VehicleState+Merging.swift` is its only writer; the rest of the app reads it
off the published Vehicle State.

**Provider registry**: the module that answers "which adapter backs this brand, and what can it
do that `VehicleProviding` does not say" — selection, the live-streaming view, and the
brand-specific session preparation — so no caller writes the brand ternary or downcasts an adapter.
See `Services/Refresh/ProviderRegistry.swift`.

**Refresh clock**: the injectable wait the refresh module sleeps on (`AsyncTimerLoop.Wait`). The app
supplies `Task.sleep`; a test supplies a recording or gated clock, which is what lets it assert the
delay the coordinator asked for instead of waiting it out. See
`Services/Integration/AsyncTimerLoop.swift`.

**Provider backoff**: a provider's stand-down from one endpoint or secondary source: how long it
will not be probed and why (a market restriction, a not-exposed resource, a client rejection).
`ProviderBackoffStore` owns them for both providers, keyed by a **Subject** that carries the VIN
when the stand-down is per-vehicle. A session erase drops the vehicle-scoped ones; a fleet-wide
erase drops all of them. See `Services/Persistence/ProviderBackoffStore.swift`.

**Snapshot schema version**: the marker every encoded Vehicle State snapshot carries. A payload that has it
decodes its clusters strictly — the flat member keys are not consulted and a missing cluster is a
corrupt snapshot rather than an old one — so only a payload written before the marker may be
rescued by the legacy flat keys. That absence is what makes those keys a migration with a defined
end rather than a permanent compatibility layer.

**Stapling**: attaching Apple's notarization ticket directly to a signed
app or DMG (`xcrun stapler staple`) so Gatekeeper can verify it was
notarized even without a network connection at launch time.

**Token lifecycle**: the module that owns one provider's refresh-token lifetime — the renewal
decision, the single-flight grant, rotate-on-use persistence, the grant cooldown, and the
classification of a permanently dead grant — while each provider keeps its wire transport and its
error vocabulary. See `Services/API/TokenLifecycle.swift`.

**Universal binary**: a single executable containing both `arm64` and
`x86_64` code, produced via `lipo -create`, so one download runs natively on
both Apple Silicon and Intel Macs.

**VCC API key**: a Volvo Cars Connected (developer portal) API key,
required alongside OAuth client credentials to call Volvo's REST APIs.

**VehicleProviding**: the protocol both `PolestarAPI` and `VolvoAPI`
conform to, defining the one interface the rest of the app uses regardless
of vehicle brand; see [ADR-0003](adr/0003-shared-vehicle-domain-provider-dtos.md).

**VIN** (Vehicle Identification Number): the key nearly all per-vehicle
state is scoped by; see [ADR-0007](adr/0007-vin-scoped-state.md). Treated as
sensitive: never logged or included in issue reports.

## Added 2026-08-22

**iTPMS**: indirect tyre-pressure monitoring: infers pressure loss from wheel-speed sensor
imbalance rather than in-wheel sensors. Reports a warning level per corner but has no numeric
pressure value. Polestar 2 (SPA platform) behaves this way over telematics.

**Wake reason**: why the vehicle's connectivity module is currently awake (scheduled climate,
active charging, telemetry poll), reported by the C3 DashboardService.

**Charge location**: a saved GPS position in Polestar's Chronos backend with per-location
charging settings (amp limit, minimum SoC, optimised-charging mode).

**Optimised charging mode**: per-location strategy: *intelligent timer* or *price-optimised*.

**SoH (State of Health)**: remaining usable battery capacity vs reference. Hisingen always
labels it a **calculated estimate**; neither provider exposes a BMS measurement.
