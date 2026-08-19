# Persistence Architecture

Hisingen uses several local persistence mechanisms with different security, lifetime, and performance characteristics.

The current architecture consists of:

1. macOS Keychain for sensitive authentication material.
2. `UserDefaults` for preferences and lightweight application state.
3. SQLite for structured vehicle history and historical telemetry.
4. In-memory caches for short-lived runtime data.

For privacy-sensitive data flows, see [`../security/privacy.md`](../security/privacy.md).

For retention and deletion behavior, see [`../data-retention.md`](../data-retention.md).

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
| Charging-session history | SQLite | VIN | Until clear/sign-out | Yes |
| Charging samples | SQLite | VIN/session | Maintenance-prunable after 90 days | Yes |
| Battery-health milestones | SQLite | VIN | Long-term until clear/sign-out | Yes |
| Historical telemetry | SQLite | VIN | Maintenance-prunable after 90 days | Yes |
| Remote-command audit history | SQLite | VIN | Until clear/sign-out | Yes |
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

If the database cannot be opened, Hisingen should degrade safely rather than crashing the application.

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
- approximate location; and
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

### `telemetry_logs`

Stores historical drive/telemetry information.

A row can contain:

- VIN;
- timestamp;
- odometer;
- trip meters;
- average consumption;
- ambient temperature;
- latitude;
- longitude.

This table is an explicit location-persistence path.

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

`VehicleStateStore` maintains structured charging history separately from the reduced cached snapshot.

When charging begins:

- an existing active session is reused; or
- a new charging session is created.

If location is available when the session starts, an approximate coordinate string may be attached.

Charging samples then record battery and electrical measurements.

When charging stops, the active session is finalized with calculated values.

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

Remote command execution can create a local audit record.

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

`VehicleStateStore.clear()` with no VIN invokes this global database wipe and removes the persisted snapshot and charging-baseline `UserDefaults` keys.

Current sign-out behavior uses this global clear path.

Therefore sign-out currently removes local vehicle-history data rather than preserving the SQLite database contents.

---

## Account Changes

`RefreshCoordinator` also clears local persisted vehicle state when it detects a switch to a different configured account.

This prevents cached or historical data belonging to one account from being accidentally presented after a new account is configured.

Because the database is shared by the application, this clear operation affects the shared local vehicle-history store.

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

SQLite schema changes should use explicit migrations rather than assuming all existing installations start with an empty database.

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
- sign-out-triggered local state clearing; and
- corrupt snapshot handling.

Any test using VINs, coordinates, account identifiers, or authentication material must use sanitized fixtures.

---

## Documentation Invariant

Persistence changes are not complete until the relevant documentation is updated.

Changes involving storage must review:

- [`../security/privacy.md`](../security/privacy.md)
- [`../data-retention.md`](../data-retention.md)
- [`../../PRIVACY.md`](../../PRIVACY.md)

A pull request must not change how sensitive data is persisted while leaving privacy and retention documentation describing the old behavior.