# Data Retention

This document describes how long Hisingen keeps locally stored information and what removes it.

For the user-facing privacy policy, see [`../PRIVACY.md`](../PRIVACY.md).

For privacy-sensitive data flows, see [`security/privacy.md`](security/privacy.md).

For the underlying storage architecture, see [`architecture/persistence.md`](architecture/persistence.md).

## Scope

Hisingen does not operate a backend containing users' vehicle histories.

The retention periods in this document apply to information stored locally by the Hisingen application on the user's Mac.

External providers such as Polestar, Volvo Cars, Apple, Open-Meteo, and GitHub have their own independent retention policies.

---

## Storage Locations

Hisingen currently uses four local storage categories:

1. macOS Keychain for sensitive authentication material.
2. `UserDefaults` for preferences and selected application state.
3. SQLite for vehicle history and historical telemetry.
4. In-memory caches for short-lived application state.

The primary SQLite database is stored at:

`~/Library/Application Support/Hisingen/hisingen.sqlite3`

SQLite may also create:

- `hisingen.sqlite3-wal`
- `hisingen.sqlite3-shm`

These files should all be treated as parts of the same local database.

---

## Retention Summary

| Data | Storage | Current retention |
|---|---|---|
| Provider authentication credentials/tokens | macOS Keychain | Until sign-out, replacement, revocation, or explicit removal |
| Custom Volvo sensitive developer credentials | macOS Keychain | Until replaced, default configuration is restored, or credentials are cleared |
| Non-secret configuration and preferences | `UserDefaults` | Until changed, reset, or application data is removed |
| Cached vehicle snapshot | SQLite + `UserDefaults` fallback | Maximum useful age of 7 days; expired snapshot is removed when read |
| Charging transition baseline | `UserDefaults` | 7 days; expired baseline is removed when read |
| Charging-session header | SQLite | Retained until local history is explicitly cleared (kept across sign-out unless "Erase local history on sign out" is enabled) |
| Charging samples | SQLite | Can be pruned after the selected 30, 90, 180, or 365-day period through maintenance |
| Historical telemetry | SQLite | Can be pruned after the selected 30, 90, 180, or 365-day period through maintenance |
| Precise coordinates in historical telemetry/charging sessions | SQLite | Disabled by default; only written after explicit user opt-in, then follows the parent history retention |
| Battery-health milestones | SQLite | Long-term; retained until local history is cleared |
| Remote-command audit records | SQLite | Retained until local history is cleared |
| Reverse-geocode cache | Memory | Process lifetime |
| Temporary provider capability/request caches | Memory | Short-lived, provider-specific |
| Exported CSV files | User-selected filesystem location | Controlled by the user after export |

---

## Cached Vehicle Snapshots

Hisingen stores a reduced `VehicleState` snapshot for each VIN.

The snapshot is written to:

- SQLite `vehicle_snapshots`; and
- the `cached_vehicle_snapshots_v1` `UserDefaults` fallback.

The SQLite snapshot is preferred when loading.

A snapshot older than seven days is considered expired.

Expiration is enforced when the snapshot is read.

Hisingen does not need a background deletion timer for snapshot expiration: when an expired snapshot is encountered, it is removed and not returned to the application.

The cached snapshot excludes the live vehicle-location object, owner first name, registration number, and vehicle image data.

Live parking location can therefore be displayed without persisting it. The separate “Store
precise location history” preference is off by default and controls only coordinate fields in
historical telemetry and charging-session location labels.
Turning the preference off also clears previously stored coordinate columns and charging-session
location labels for the selected vehicle.

It can still contain other vehicle information such as VIN, odometer, charging information, diagnostics, exterior state, software state, climate information, weather, and vehicle configuration.

---

## Charging Transition Baselines

Charging transition baselines are stored in `UserDefaults`.

They exist so Hisingen can distinguish a genuine charging-state transition from a state that was already active before the application restarted.

Baselines older than seven days are considered expired and removed when read.

---

## Charging Sessions

Charging-session headers are stored in SQLite.

A charging session may contain:

- session ID;
- VIN;
- start time;
- end time;
- starting battery percentage;
- ending battery percentage;
- calculated energy delivered;
- peak charging power;
- average charging power;
- approximate location; and
- lifecycle/completion status and calculation provenance;
- observation coverage and usable-capacity reference;
- the day/night tariff and currency snapshot used for estimated cost; and
- record creation time.

Active, paused, and pending-completion headers are internal and do not appear in completed
history. Stale or zero-gain observations are marked abandoned for diagnosis and likewise stay
hidden. Charging-session headers are not removed by the 90-day sample-pruning operation.

They remain until vehicle history is explicitly cleared. Sign-out keeps them unless "Erase local history on sign out" is enabled.

### Charging location retention

When location history is explicitly enabled and location data is available when
a session starts, Hisingen may store coordinates rounded to four decimal places
as the charging-session location.

This value should be treated as sensitive location information.

Pruning individual charging samples does not remove the charging-session header or its stored location.

---

## Charging Samples

Charging samples are stored separately from charging-session headers.

A sample may contain:

- session ID;
- VIN;
- timestamp;
- battery percentage;
- charging power;
- voltage; and
- current.

Charging samples do not themselves contain latitude or longitude columns.

The associated charging-session header may contain an approximate charging location.

### Configurable sample pruning

Settings → Privacy & Data lets the user choose a 30, 90, 180, or 365 day cutoff for
high-volume charging samples. The default is 90 days.

The current implementation performs this pruning when the maintenance action is invoked.

It is not an automatic guarantee that every sample disappears exactly 90 days after creation.

Documentation should therefore say:

> Charging samples can be pruned after the configured retention period through maintenance.

rather than:

> Charging samples are automatically deleted after 90 days.

---

## Historical Telemetry

Historical telemetry is stored in the SQLite `telemetry_logs` table.

A row may contain:

- VIN;
- timestamp;
- odometer;
- manual trip meter;
- automatic trip meter;
- average consumption;
- ambient temperature;
- latitude; and
- longitude.

Hisingen does not intentionally write a new telemetry row on every stationary refresh.

The telemetry recorder skips repeated stationary readings during its heartbeat
window and records when meaningful movement or the configured heartbeat
condition warrants another row. It retains one unchanged reading immediately
after movement as a parked boundary, allowing short adjacent journeys to be
separated without retaining every parked poll.

The History dashboard derives grouped journeys from these rows at read time;
those derived trips do not add another database table or retention category.

### Location

Only when “Store precise location history” is explicitly enabled may coordinates
from `VehicleState.location` be written to historical telemetry. It is off by
default, and disabling it clears stored telemetry coordinates and charging
location labels for the selected VIN.

This means precise vehicle coordinates can exist in the local SQLite database even though the cached `VehicleState` snapshot itself strips the location field.

### Configurable sample pruning

Historical telemetry uses the same maintenance pruning path as charging samples.

The selectable cutoff is 30, 90, 180, or 365 days; the default is 90 days.

As with charging samples, this occurs when the maintenance operation is invoked rather than through a guaranteed automatic deletion exactly at 90 days.

---

## Battery-Health History

Battery-health milestones are stored in SQLite.

A milestone can contain:

- VIN;
- timestamp;
- odometer;
- state of health;
- degradation;
- effective usable capacity; and
- measurement classification.

State of Health is calculated locally from the available charging, range,
consumption, age, mileage, and configured vehicle-reference signals. It is not a
provider value or a BMS measurement. New rows are classified `calculated-v2`;
older inferred rows are retained as `legacy-estimate` for trend continuity.

Hisingen avoids writing a duplicate row for every vehicle refresh.

A new milestone is recorded only when the implementation determines that the reading carries sufficiently new information, such as elapsed time, mileage change, or meaningful SoH change.

Battery-health milestones are intended for long-term trend history.

They are not removed by the 90-day charging/telemetry pruning operation.

They remain until local vehicle history is cleared.

---

## Remote-Command Audit History

Hisingen stores remote-command audit records in SQLite.

A record can contain:

- identifier;
- VIN;
- command name;
- status;
- execution time;
- duration; and
- an error description.

These records are not part of the 90-day historical-sample pruning operation.

They remain until the local database is cleared.

---

## Reverse-Geocode Cache

The reverse geocoder maintains a process-local cache of coordinate-to-address results.

This cache exists only in memory.

Hisingen does not persist the `ReverseGeocoder` cache to SQLite or `UserDefaults`.

The cache disappears when the application process exits.

This does not affect any independent processing or retention performed by Apple's geocoding infrastructure.

---

## Vehicle Weather

Weather results may become part of the vehicle state and can therefore be included in locally persisted vehicle snapshots or telemetry-related information.

For Polestar, enabling Vehicle Weather can cause Hisingen to retrieve vehicle coordinates and send them to Open-Meteo even when the separate Vehicle Location display feature is disabled.

The internally obtained location used for the weather request is not automatically persisted as `VehicleState.location` when Vehicle Location itself is disabled.

---

## User Preferences

Ordinary preferences stored in `UserDefaults` do not have a time-based expiration unless specifically documented.

These may include:

- selected provider;
- selected VIN;
- nicknames;
- enabled features;
- notification settings;
- display preferences;
- electricity price;
- update-check state; and
- non-secret developer configuration.

Preferences generally remain until changed, reset, or the application's stored preferences are removed.

---

## Authentication Material

Sensitive persisted authentication material is stored separately from the vehicle-history database.

Depending on provider and configuration, this may include:

- refresh tokens;
- provider session material;
- custom Volvo Client Secret;
- custom Volvo VCC API Key; and
- other sensitive authentication values.

These values are retained until they are:

- replaced;
- cleared;
- invalidated;
- revoked by the provider; or
- removed during sign-out as applicable.

Authentication secrets must not be placed in SQLite vehicle-history tables.

---

## Sign-Out

Sign-out keeps local vehicle history by default.

The flow calls Hisingen's global state-store clear operation before completing
provider-specific sign-out. That operation always removes:

- SQLite vehicle snapshots (they hold live-ish fields such as parking location and owner name);
- cached vehicle snapshots stored in `UserDefaults`; and
- charging transition baselines stored in `UserDefaults`.

It removes the durable SQLite history tables — charging sessions and samples,
battery-health milestones, telemetry, air quality, connectivity, cabin climate,
manual fuel fill-ups, remote-command audit — **only** when the user has enabled
**Settings → Privacy & Data → "Erase local history on sign out"** (off by default,
`erase_history_on_sign_out`). The default keeps that history so a re-signed local
build, an accidentally dismissed Keychain prompt, or a stray sign-out does not
discard months of data. The deliberate way to remove it is the separately
confirmed "Erase local vehicle data" action in the same pane.

Provider-specific sign-out then handles the associated authentication state.

---

## Account Changes

When Hisingen detects that the configured account has changed, the refresh coordinator clears the shared local vehicle **snapshot** state before starting a session for the new account, so stale live data from one account is never shown as another's.

Durable SQLite history is retained across an account change unless "Erase local history on sign out" is enabled, in which case the account-change path erases it too.

---

## Manual Maintenance

The application can expose maintenance operations for local vehicle history.

The historical-sample pruning operation removes:

- charging samples older than the configured cutoff; and
- telemetry rows older than the configured cutoff.

The default cutoff is 90 days.

After pruning, the database performs SQLite maintenance to reclaim space where possible.

Pruning samples does not remove:

- charging-session headers;
- battery-health milestones; or
- remote-command audit history.

A full clear is required to remove those categories.

Settings exposes that full clear as a separately confirmed destructive action. It awaits
the SQLite transaction before reporting success. When a vehicle is selected, only that
VIN is cleared; otherwise the action explicitly says that all local vehicle data is erased.

---

## Exported Data

When the user exports Hisingen history to CSV or another file, that exported copy is outside Hisingen's internal retention lifecycle.

Deleting Hisingen's SQLite database does not delete copies the user previously exported.

Exports may contain sensitive values such as:

- VIN;
- timestamps;
- charging history;
- battery-health information; and
- charging location.

Settings archives are different from history exports. They contain presentation, feature,
update, tariff, and notification preferences only. Account identifiers, VINs, nicknames,
tokens, passwords, client secrets, API keys, and SQLite history are excluded.

Users are responsible for storing and deleting exported files.

---

## Backups

Local application data may be copied by:

- Time Machine;
- APFS snapshots;
- third-party backup software;
- disk cloning; or
- other system-level backup mechanisms.

Hisingen clearing its active local database cannot guarantee deletion of data already present in backups.

---

## Database Sensitivity

The SQLite database should be treated as sensitive because it can contain:

- VIN;
- vehicle state;
- charging history;
- battery-health history;
- remote-command history;
- historical coordinates; and
- approximate charging locations.

The following files must not be committed, attached to public bug reports, or included in release artifacts:

- `hisingen.sqlite3`
- `hisingen.sqlite3-wal`
- `hisingen.sqlite3-shm`

Diagnostic tooling should not automatically attach these files.

---

## Development Requirements

Changes to persistence must update this document when they modify:

- a retention period;
- a database table;
- a persisted field;
- location persistence;
- sign-out deletion;
- maintenance behavior;
- CSV export behavior; or
- credential storage.

Tests should verify privacy-sensitive retention behavior where practical.

At minimum, persistence tests should cover:

- seven-day snapshot expiry;
- seven-day baseline expiry;
- telemetry pruning;
- charging-sample pruning;
- full database wipe;
- location removal from `cacheableCopy`;
- historical coordinate persistence when expected;
- history retention across sign-out with `erase_history_on_sign_out` off, and erasure when on; and
- schema-migration row preservation for a pre-`user_version` database.

---

## Related Documentation

- [`../PRIVACY.md`](../PRIVACY.md) — user-facing privacy policy
- [`security/privacy.md`](security/privacy.md) — privacy-sensitive data flows
- [`architecture/persistence.md`](architecture/persistence.md) — storage architecture
- [`security/keychain.md`](security/keychain.md) — credential storage
