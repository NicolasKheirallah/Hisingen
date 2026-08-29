# Persistence Architecture

Hisingen uses several local persistence mechanisms with different security, lifetime, and performance characteristics.

The current architecture consists of:

| Data | Storage | Scope | Lifetime | Sensitive | Migration |
|---|---|---|---|---|---|
| Polestar refresh token | Keychain, account `polestar-refresh-token` | Per brand | Until sign-out or revoked | Yes | — |
| Polestar account email | Keychain, account `polestar-email` | Per brand | Until sign-out | Yes | Migrated from the legacy `polestar_email` UserDefaults key on first read; cleartext is removed after a successful Keychain write |
| Polestar password | Keychain, account `polestar-password` | Per brand | Until sign-out | Yes | Migrated from a legacy plaintext `polestar_password` UserDefaults key at launch (`Preferences.migrateLegacyPassword()`); the legacy value is removed after the Keychain path succeeds and retained for retry on failure |
| Volvo client secret, VCC API key, refresh token | Keychain, single JSON blob under account `volvo-credentials-bundle` | Per brand | Until sign-out or revoked | Yes | Self-healing: `readVolvoBundle()` falls back to three legacy single-purpose accounts (`volvo-client-secret`, `volvo-vcc-api-key`, `volvo-refresh-token`) and re-saves them into the bundle format on first read |
| Volvo client ID | `UserDefaults` (`volvo_client_id`) | Per brand | Persistent | No (not a secret — public OAuth client identifier) | — |
| Active brand, selected VIN, nicknames | `UserDefaults` | Per brand (VIN/nickname), global (active brand) | Persistent | No | Nicknames migrated from a legacy single-vehicle key; VIN keys are brand-specific (`polestar_vin`/`volvo_vin`) |
| Feature selection | `UserDefaults` (`enabled_features_v2`) | Global | Persistent | No | Migrates from `enabled_features_v1` (auto-enabling several newer features) or an even older `show_vehicle_image` bool |
| Notification toggles, low-battery threshold, electricity price | `UserDefaults` | Global | Persistent | No | — |
| Theme, menu-bar style, distance unit, language | `UserDefaults` | Per VIN (theme) / global (rest) | Persistent | No | Menu-bar style migrates from legacy display-name strings |
| Exact usable-capacity/WLTP references | `UserDefaults` (`vehicle_specification_overrides_v1`) | Per VIN | Until reset | No | User-entered reference data, never provider telemetry |
| Vehicle telemetry snapshot | `UserDefaults` (`cached_vehicle_snapshots_v1`, JSON) | Per VIN | 7 days (self-cleaning on read) | Partially — see below | No versioned migration; a decode failure is treated as "no cache" |
| Charging state-machine baseline | `UserDefaults` (`charging_baselines_v1`, JSON) | Per VIN | 7 days (self-cleaning on read) | No | Same as above |
| Capability observations (`VehicleProbedCapabilities`) | Embedded inside the cached `VehicleState` | Per VIN | 6-hour staleness window, independent of the 7-day store TTL | No | Same as above |
| Update-check result | `UserDefaults` | Global | Persistent, re-checked every 24h | No | — |
| Reverse-geocode cache | In-memory only (`ReverseGeocoder` actor) | Global | Process lifetime | No (never written to disk) | N/A |

For privacy-sensitive data flows, see [`../security/privacy.md`](../security/privacy.md).

- **Account email / refresh tokens / passwords** — so the user doesn't have to sign in on every launch. Kept in Keychain, never newly written to `UserDefaults` or on-disk caches.
- **Feature selection, notification toggles, theme, etc.** — plain user preferences; no reason to protect them beyond normal `UserDefaults` behavior.
- **Vehicle telemetry snapshot** — lets the app show *something* immediately at launch and during vehicle switching, without waiting on a network round trip, and lets it keep showing the last known state if the vehicle is asleep or the network is down.
- **Charging baseline** — the charging state machine (`ChargingTransitionDetector`) needs to remember what state it last saw per VIN so a relaunch doesn't re-fire a "charging started" notification for a session that began before the app was last quit.
- **Capability observations** — so a positively-observed capability (e.g., "this Polestar 3 does support the amp-limit endpoint") survives a relaunch instead of needing to be re-probed from the conservative static default every time.

For Keychain-specific security properties, see [`../security/keychain.md`](../security/keychain.md).

---

## Principles

Persistence in Hisingen follows these principles:

- authentication secrets belong in Keychain;
- structured historical vehicle data belongs in SQLite;
- ordinary preferences belong in `UserDefaults`;
- unnecessary sensitive fields should not be persisted;
- persisted data is scoped by VIN where practical;
- cached data must fail safely when corrupt or incompatible;
- location persistence must be explicit and documented;
- local data must never be confused with a Hisingen-operated cloud service.

"Local" means stored on the user's Mac.

It does not mean the data cannot be copied by macOS backups, filesystem snapshots, exports, or a user with access to the filesystem.

---

## Storage Inventory

| Data | Storage | Scope | Lifetime | Sensitive? |
|---|---|---|---|---|
| Provider authentication/session material | Keychain | Provider/account | Until cleared, replaced, revoked, or sign-out | Yes |
| Custom Volvo Client Secret | Keychain | Volvo configuration | Until replaced/default restored/cleared | Yes |
| Custom Volvo VCC API Key | Keychain | Volvo configuration | Until replaced/default restored/cleared | Yes |
| Volvo Client ID | `UserDefaults` or application configuration | Volvo configuration | Persistent | Usually not secret |
| Selected provider/VIN | `UserDefaults` | Provider/VIN | Persistent | VIN is sensitive |
| Vehicle nicknames | `UserDefaults` | VIN | Persistent | Potentially |
| Feature selection | `UserDefaults` | Application | Persistent | Low |
| Notification settings | `UserDefaults` | Application | Persistent | Low |
| Theme/language/display settings | `UserDefaults` | Application | Persistent | Low |
| Cached vehicle snapshot | SQLite + `UserDefaults` fallback | VIN | 7-day useful TTL | Yes |
| Charging transition baseline | `UserDefaults` | VIN | 7 days | Moderate |
| Charging-session history | SQLite | VIN | Until cleared (kept across sign-out unless opted in) | Yes |
| Charging samples | SQLite | VIN/session | Maintenance-prunable after 90 days | Yes |
| Battery-health milestones | SQLite | VIN | Long-term until cleared (kept across sign-out unless opted in) | Yes |
| Historical telemetry | SQLite | VIN | Maintenance-prunable after 90 days | Yes |
| Remote-command audit history | SQLite | VIN | Until cleared (kept across sign-out unless opted in) | Yes |
| Connectivity samples (wake/signal) | SQLite | VIN | Change-gated; pruned with samples | Moderate |
| Cabin climate samples | SQLite | VIN | Hourly heartbeat; pruned with samples | Low |
| Manual fuel fill-ups | SQLite | VIN | Until cleared (kept across sign-out unless opted in) | No |
| Full JSON backup export | User-chosen file | All vehicles | User-managed | Yes (coordinates only when opted in) |
| Reverse-geocode cache | Memory | Process | Process lifetime | Yes |
| Provider capability/request caches | Memory | Provider/VIN | Short-lived | Low/moderate |
| Vehicle images | Separate image cache/runtime storage | VIN | Implementation-specific | Potentially |

---

## SQLite Database

The local vehicle database is created under the user's Application Support directory:

`~/Library/Application Support/Hisingen/hisingen.sqlite3`

SQLite can create two companion files:

- `hisingen.sqlite3-wal`
- `hisingen.sqlite3-shm`

All three must be treated as potentially containing sensitive application data.

The database is opened and managed by `VehicleDatabase`.

If the database cannot be opened, Hisingen degrades to a closed handle (`SQLiteDatabase.unavailable`): every write is logged and dropped rather than crashing. If the Application Support directory itself is unavailable, `VehicleDatabase` also uses a closed handle — it must **not** fall back to a temporary directory, which macOS purges and which previously made "my history vanished" indistinguishable from an OS housekeeping sweep.

On open, a pre-existing file that fails `PRAGMA quick_check` is renamed aside to `hisingen.sqlite3.corrupt-<timestamp>` (with its `-wal`/`-shm` siblings) and a fresh database is created, so a corrupt file is recoverable by hand rather than silently recreated empty.

Immediately before a schema migration runs (`PRAGMA user_version` is about to increase on a pre-existing database), `VehicleDatabase` writes a one-shot `VACUUM INTO` copy to `hisingen.sqlite3.pre-v<target>.bak`. It is never overwritten once present.

---

## SQLite Schema

The current database contains the following logical tables.

### `vehicle_snapshots`

Stores the latest persisted `VehicleState.cacheableCopy` for each VIN.

Important fields include:

- VIN;
- provider/brand;
- model;
- fetch timestamp;
- provider-reported timestamp; and
- encoded snapshot payload.

The payload is not the complete live `VehicleState`.

See the snapshot privacy boundary below.

### `charging_sessions`

Stores charging-session summaries.

A row can contain:

- session identifier;
- VIN;
- start/end timestamps;
- start/end state of charge;
- calculated energy delivered;
- peak power;
- average power;
- approximate location;
- lifecycle and completion reason;
- energy source, confidence, observation coverage, and summary version;
- the usable-capacity and target references;
- the saved flat/day/night tariff, currency, and estimated cost; and
- creation timestamp.

### `charging_samples`

Stores time-series charging measurements.

A sample can contain:

- session ID;
- VIN;
- timestamp;
- state of charge;
- charging power;
- voltage;
- current.

### `battery_health_history`

Stores long-term battery-health milestones.

A row can contain:

- VIN;
- timestamp;
- odometer;
- state of health;
- degradation;
- effective usable battery capacity; and
- measurement classification.

These are calculated estimates. New rows use `calculated-v2`; rows written by
the older inferred implementation are migrated to `legacy-estimate`. Neither
classification means that the provider or vehicle BMS reported SoH.

### `telemetry_logs`

Stores historical drive/telemetry information.

A row can contain:

- VIN;
- timestamp;
- odometer;
- trip meters;
- average consumption;
- consumption unit (`kwh` / `l`; NULL for rows written before 2026-08 — historically EV-only);
- ambient temperature;
- latitude;
- longitude.

This table is an explicit location-persistence path.

The History dashboard derives journeys from consecutive movement readings and
groups adjacent intervals until a stationary reading or a long sample gap. The
derived trip objects are not a separate persisted provider trip log.

### `remote_commands_log`

Stores local command-audit information.

A row can contain:

- command identifier;
- VIN;
- command name;
- status;
- execution time;
- duration; and
- error description.

### `connectivity_history`

Change-gated connectivity samples (written only when network type, signal bars, or wake
reason changed, or after a one-hour heartbeat). Powers the Info tab's Connectivity & Wake
card: current wake reason, signal sparkline, recent wake-reason counts.

A row can contain: VIN; timestamp; network type; signal bars (0–4); wake reason.

### `cabin_climate_history`

Hourly-gated interior/requested cabin temperatures from digital-twin climate platforms.
Powers the History tab's Cabin Temperature Trend card. Hidden on vehicles that never report
interior temperature.

### `fuel_entries`

Manual fill-ups for hybrid/combustion economics: VIN; date; litres; price per litre; optional
odometer. Included in lifetime cost-per-distance and the Fuel Fill-Ups card. Added
2026-08-22 — see [domain/charging.md](../domain/charging.md#fuel-fill-ups-hybrid--combustion).

---

## `VehicleStateStore`

`VehicleStateStore` coordinates the local last-known vehicle state and historical database.

On save, the current implementation performs several independent operations:

1. persists a reduced snapshot through `VehicleDatabase`;
2. records battery-health milestones when qualifying data is available;
3. records historical telemetry when qualifying data is available;
4. updates charging-session history while charging;
5. stores a `UserDefaults` fallback copy of the reduced vehicle snapshot.

This is why privacy documentation must distinguish between:

- the reduced cached snapshot; and
- separately recorded historical data.

A field being removed from `cacheableCopy` does not automatically mean that the same information is absent from every other persistence path.

---

## Snapshot Loading

`VehicleStateStore.snapshot(for:)` prefers the SQLite snapshot.

If SQLite does not provide a snapshot, the legacy/current `UserDefaults` snapshot fallback is attempted.

Both mechanisms use the reduced `VehicleState.cacheableCopy`.

Snapshots older than seven days are treated as expired.

An expired snapshot is deleted when encountered and is not returned to the UI.

---

## `VehicleState.cacheableCopy`

The persisted vehicle snapshot is intentionally derived from the live state.

It is not appropriate to persist the complete live `VehicleState` blindly.

### Explicitly removed

The current snapshot deliberately removes:

- `registrationNo`;
- `ownerFirstName`;
- `location`;
- exterior `imageData`;
- interior image data; and
- transient unavailable-feature state.

### Retained

The current snapshot retains a much broader set of data than older documentation described.

Depending on availability, it can include:

- VIN;
- model;
- model year;
- battery level;
- range;
- charging state;
- charging measurements;
- vehicle availability;
- odometer;
- service information;
- fluid warnings;
- exterior/lock state;
- health information;
- software information;
- charging schedules;
- climate state and timers;
- trip meters;
- connectivity;
- air quality;
- battery diagnostics;
- weather;
- capability observations;
- charging samples;
- charging sessions embedded in the domain state;
- powertrain;
- fuel state;
- reported battery capacity;
- exterior colour;
- gearbox;
- service information;
- average speed;
- fuel consumption;
- engine state;
- structure/build information;
- vehicle identifiers used by the provider;
- account market;
- upholstery;
- wheels;
- packages;
- steering orientation;
- charging-current limit;
- warranty information;
- timestamps; and
- data warnings.

The previous description that the persisted cache is effectively "battery and charging state only" is no longer accurate.

---

## Adding Fields to `VehicleState`

Every new field added to `VehicleState` requires an explicit persistence decision.

Before adding it to `cacheableCopy`, consider:

- whether it contains personal information;
- whether it contains precise location;
- whether it identifies the vehicle or owner;
- whether stale display of the value is safe;
- whether long-term retention is necessary;
- whether the information is available again from the provider; and
- whether a different historical table is more appropriate.

Do not automatically copy new fields into the persisted snapshot simply to make them survive restart.

---

## Location Persistence

Location has multiple independent paths and must not be described using a single blanket statement.

### Cached snapshot

`VehicleState.cacheableCopy` sets `location` to `nil`.

Therefore the encoded `vehicle_snapshots.payload` does not contain the live `VehicleState.location`.

The `UserDefaults` snapshot fallback likewise uses `cacheableCopy` and does not contain the live location.

### Historical telemetry

`VehicleStateStore.save(_:)` passes:

- `state.location?.latitude`
- `state.location?.longitude`

to `VehicleDatabase.recordTelemetry`.

The SQLite `telemetry_logs` table therefore may contain precise historical coordinates.

### Charging sessions

When charging begins and coordinates are available, `VehicleStateStore` formats them to four decimal places and supplies the resulting value as the charging-session location.

The SQLite `charging_sessions.location_name` field can therefore contain an approximate coordinate pair.

### Reverse geocoding

The `ReverseGeocoder` actor keeps its own address cache in memory only.

It does not write its address cache to SQLite or `UserDefaults`.

### Weather

For Polestar, Vehicle Weather may independently obtain current vehicle coordinates and send them to Open-Meteo.

If Vehicle Location itself is disabled, those internally retrieved weather coordinates are not automatically assigned to `VehicleState.location`, so the historical telemetry persistence path does not receive them merely because weather was requested.

This distinction should be preserved.

---

## Telemetry Sampling

Historical telemetry is intentionally not written on every refresh.

Before adding a new row, the database compares the most recent stored movement-related readings.

A stationary vehicle with unchanged odometer and trip-meter values is not repeatedly recorded during the telemetry heartbeat window.

A new row is recorded when movement-related data changes or when the heartbeat interval requires another observation.

This controls database growth but should not be treated as a privacy guarantee that only one coordinate is retained.

---

## Charging History

`VehicleStateStore` maintains structured charging history in SQLite separately from the reduced
cached snapshot. SQLite is authoritative; legacy `chargingSessions` arrays carried in cached
snapshots are cleared during refresh and are not used to render history.

The `ChargingSessionEngine` is the sole writer of lifecycle transitions. When charging begins:

- an existing active session is reused; or
- a new charging session is created.

If location is available when the session starts, an approximate coordinate string may be attached.

Charging samples form an append-only observation log of battery and electrical measurements.

Paused/scheduled observations keep a session open. A single idle/disconnected observation moves
it to `pending_completion`; a second confirms the stop. Faults interrupt immediately. Stale open
or zero-gain sessions become `abandoned`, and unfinished/abandoned rows are excluded from
completed history. A confirmed stop below the target is classified as interrupted rather than
completed. The last charging sample may supersede a stale stop-snapshot SoC.

Version-2 summaries are materialized from the observation log. Power is integrated only across
gaps of at most 15 minutes and becomes authoritative at 70% duration coverage; otherwise energy
falls back to SoC change × the session's saved usable-capacity reference. The chosen source,
confidence, coverage, completion reason, target, tariff/currency snapshot, and calculated cost
are stored with the header so every consumer reads the same interpretation.

At read time, missing start/end boundary samples are reconstructed from the durable session
header. If an older record contains zero energy but its samples prove an SoC gain, the estimate
is recovered from the current usable-capacity reference. While history recording is enabled,
`VehicleStateStore` also writes that recovered end SoC, energy, and power summary back to the
completed row on the next vehicle refresh. This makes cards, dashboards, aggregate statistics,
and later CSV exports agree; the repair is idempotent and never guesses when samples show no
gain.

Charging-session summaries and samples therefore have different retention rules.

See [`../data-retention.md`](../data-retention.md).

---

## Battery-Health Milestones

Battery-health history is intentionally milestone-based rather than refresh-based.

A new row is written only when the reading is considered sufficiently different from the previous milestone according to the current implementation.

This reduces unnecessary database growth while preserving useful long-term degradation history.

Battery-health history is not subject to the charging/telemetry 90-day pruning operation.

---

## Remote-Command Audit

Every provider command attempt that reaches dispatch creates a local audit record containing
the VIN, normalized command identifier, provider outcome or failure, execution time, and
duration. Attempts cancelled at the local authentication prompt are not provider attempts and
are not logged.

The audit exists for diagnostics and operational history.

Authentication tokens and raw authenticated provider responses must not be stored in this table.

Error text should be reviewed to ensure upstream error messages cannot inadvertently inject sensitive authentication material.

---

## Historical Sample Pruning

`VehicleDatabase.pruneHistoricalSamples(olderThanDays:)` currently removes:

- charging samples older than the cutoff; and
- telemetry rows older than the cutoff.

The default cutoff is 90 days.

The operation then performs SQLite maintenance.

This is an explicit maintenance operation.

Documentation should not imply that a background scheduler guarantees deletion exactly when a row reaches 90 days of age.

The prune operation does not delete:

- charging-session headers;
- battery-health history; or
- remote-command audit records.

---

## Database Clearing

The global database wipe removes all rows from:

- vehicle snapshots;
- charging sessions;
- charging samples;
- battery-health history;
- telemetry logs;
- remote-command audit history.

It then performs SQLite vacuuming.

`VehicleStateStore.clear(vin:eraseHistory:)` always drops the cached snapshot (SQLite `vehicle_snapshots` plus the `UserDefaults` mirror) and the charging-baseline `UserDefaults` key. It invokes the global database wipe above **only** when `eraseHistory` is `true`.

Sign-out and account-change pass `preferences.eraseHistoryOnSignOut` (Settings → Privacy & Data, key `erase_history_on_sign_out`, off by default). With the default, sign-out preserves the SQLite history tables; the deliberate "Erase local vehicle data" action in Settings is the path that wipes them.

---

## Account Changes

`RefreshCoordinator` also clears local persisted vehicle **snapshot** state when it detects a switch to a different configured account.

This prevents cached data belonging to one account from being accidentally presented after a new account is configured. It passes the same `eraseHistoryOnSignOut` flag, so the shared SQLite history store is wiped on an account change only when the user has opted in.

---

## UserDefaults

`UserDefaults` remains appropriate for lightweight application state.

Examples include:

- selected provider;
- selected VIN;
- nicknames;
- feature selection;
- notification configuration;
- UI preferences;
- electricity price;
- cached vehicle snapshot fallback;
- charging transition baselines; and
- non-secret identifiers.

It is not an appropriate storage location for:

- passwords;
- access tokens;
- refresh tokens;
- Client Secrets; or
- VCC API Keys.

---

## Keychain

The macOS Keychain stores sensitive persisted authentication material.

This separation is intentional:

**vehicle history and authentication secrets must not share the same persistence mechanism.**

See [`../security/keychain.md`](../security/keychain.md) for:

- account names;
- accessibility class;
- migration behavior;
- provider-specific credential bundles; and
- deletion behavior.

---

## In-Memory Caches

Several services maintain in-memory caches to reduce unnecessary network requests.

Examples include:

- reverse-geocode results;
- provider capability results;
- provider endpoint backoff state; and
- short-lived request/session state.

These caches disappear when the application process exits unless their result is explicitly copied into a persisted domain object elsewhere.

A developer must not infer persistence solely from the word "cache."

Always check which storage layer owns the data.

---

## Corruption and Compatibility

Persisted cached state must fail safely.

If a cached vehicle snapshot cannot be decoded, Hisingen should treat it as unavailable rather than:

- crashing;
- showing partially decoded garbage; or
- attempting unsafe recovery.

The application should be able to obtain a fresh state from the provider after cache failure.

SQLite schema changes must use explicit, `PRAGMA user_version`-gated migrations in `VehicleDatabase.runMigrations(from:)` — additive only (`ALTER TABLE ADD COLUMN`, `CREATE TABLE/INDEX IF NOT EXISTS`, in-place `UPDATE`). A migration must never `DROP` or recreate a table that can hold user history. Bump `VehicleDatabase.latestSchemaVersion` in lockstep with each new block. `DataRetentionHardeningTests.schemaMigrationPreservesExistingRows` opens a pre-`user_version` database with a row and asserts it survives the upgrade.

Note on `CFBundleIdentifier`: `UserDefaults.standard` is keyed on it, so changing it orphans every stored preference. `PreferencesStore.migrateLegacyDefaults()` runs once at launch to carry values forward from `PreferencesStore.legacyDefaultsDomains`; add any new legacy identifier there. The Keychain service (`io.kheirallah.hisingen`) and the SQLite path are independent of the bundle identifier.

---

## Backups

SQLite, `UserDefaults`, and other application files may be included in:

- Time Machine;
- filesystem snapshots;
- third-party backup products; or
- disk images.

Persistence documentation must not equate:

> deleted from the active Hisingen database

with:

> permanently erased from every possible copy.

Keychain backup and migration semantics are separate and documented in the Keychain documentation.

---

## Sensitive Files

The following files should never be committed to the repository or included in release/debug artifacts:

- real Hisingen SQLite databases;
- SQLite WAL files;
- SQLite SHM files;
- exported production vehicle history;
- authentication dumps;
- raw provider responses containing user information; or
- local preference files containing real VINs/account identifiers.

Test databases must use obviously fake data.

---

## Testing Requirements

Persistence tests should cover at least:

- SQLite schema creation;
- snapshot save/load;
- seven-day snapshot expiry;
- `cacheableCopy` exclusion of current location;
- `cacheableCopy` exclusion of owner name;
- `cacheableCopy` exclusion of registration number;
- historical latitude/longitude persistence;
- charging-session location handling;
- charging-sample retention;
- telemetry retention;
- 90-day pruning;
- battery-health milestone deduplication;
- global wipe;
- sign-out-triggered local state clearing (snapshot always, history only with `erase_history_on_sign_out`);
- schema-migration row preservation and the pre-migration backup; and
- corrupt-database quarantine (`PRAGMA quick_check`).

Any test using VINs, coordinates, account identifiers, or authentication material must use sanitized fixtures.

---

## Documentation Invariant

Persistence changes are not complete until the relevant documentation is updated.

Changes involving storage must review:

- [`../security/privacy.md`](../security/privacy.md)
- [`../data-retention.md`](../data-retention.md)
- [`../../PRIVACY.md`](../../PRIVACY.md)

A pull request must not change how sensitive data is persisted while leaving privacy and retention documentation describing the old behavior.
