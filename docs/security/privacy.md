# Privacy Architecture

This document describes Hisingen's privacy-relevant data flows and storage behavior from an implementation perspective.

For the user-facing privacy policy, see [`../../PRIVACY.md`](../../PRIVACY.md).

For retention periods and deletion behavior, see [`../data-retention.md`](../data-retention.md).

For the persistence architecture, see [`../architecture/persistence.md`](../architecture/persistence.md).

## Design Principle

Hisingen is local-first.

There is no Hisingen-operated backend receiving vehicle telemetry, credentials, location, remote commands, or usage analytics.

Most data processing happens inside the macOS application.

External communication is limited to the vehicle provider and explicitly used third-party services required by enabled features.

---

## Data Flow Summary

| Destination | Data that may be sent | Purpose | Required? |
|---|---|---|---|
| Polestar-operated services | Authentication material, bearer tokens, VIN, requested vehicle data and commands | Polestar integration | Required for Polestar use |
| Volvo Cars services | OAuth material, bearer tokens, VCC API configuration where applicable, VIN, requested vehicle data and commands | Volvo integration | Required for Volvo use |
| Apple `CLGeocoder` | Latitude and longitude | Reverse-geocode vehicle location | Only when address resolution is used |
| Open-Meteo | Latitude and longitude | Weather at the vehicle's location | Only when Vehicle Weather is enabled and Open-Meteo is used |
| GitHub Releases | Application/version-related HTTP request metadata | Update checking | Only when update checking is enabled |
| GitHub Pages OAuth callback | Volvo OAuth authorization response and state as part of browser redirect | Return Volvo OAuth result to the desktop app | Required for the normal Volvo OAuth flow |
| Hisingen-operated server | Nothing | No Hisingen backend exists | N/A |

Third-party infrastructure may independently record ordinary request metadata according to its own policies.

---

## Authentication Data

### Polestar

Hisingen communicates directly with Polestar-operated identity and vehicle services.

Authentication information required to establish or restore the user's Polestar session is handled locally by Hisingen and the provider.

Sensitive persisted authentication material is stored using the macOS Keychain rather than the vehicle-history database or ordinary telemetry caches.

### Volvo

Official Hisingen releases support a built-in Volvo Developer application configuration.

Normal users do not need to create their own Volvo Developer Portal application.

Advanced users may optionally configure a custom application containing values such as:

- Client ID;
- Client Secret; and
- VCC API Key.

Custom sensitive credentials are stored using Hisingen's credential-storage mechanisms.

The user's Volvo ID authentication takes place with Volvo in the system browser. Hisingen does not directly request or persist the user's Volvo ID password.

Developer application credentials and user account credentials are separate security concepts.

---

## Keychain Boundary

Sensitive authentication material that must survive application restarts belongs in the macOS Keychain.

This includes provider session material and sensitive custom Volvo developer configuration where applicable.

Authentication material must not be persisted in:

- SQLite telemetry tables;
- charging history;
- vehicle snapshots;
- exported vehicle CSV files;
- ordinary diagnostic logs; or
- documentation.

See [`keychain.md`](keychain.md) for detailed Keychain behavior.

---

## VIN

VIN is the primary vehicle identifier used throughout Hisingen.

It may be:

- sent to the vehicle's manufacturer;
- stored in SQLite vehicle-history tables;
- stored in cached vehicle snapshots;
- stored in charging history;
- stored in battery-health history;
- stored in telemetry history;
- stored in remote-command audit history;
- used as part of local application state; and
- used in local notification identifiers.

Hisingen does not need to send VIN to Apple or Open-Meteo for geocoding or weather requests.

VIN should be treated as sensitive vehicle-identifying information in:

- logs;
- screenshots;
- issue reports;
- test fixtures; and
- exported data.

---

## Vehicle Location

Vehicle location is one of the most privacy-sensitive data types Hisingen processes.

It is important to distinguish between four different forms of location handling:

1. the live `VehicleState.location` field;
2. cached vehicle snapshots;
3. historical telemetry and charging records;
4. third-party processing for geocoding and weather.

These have different persistence behavior.

### Live vehicle location

When Vehicle Location is enabled and supported, Hisingen may request the latest reported vehicle position from the relevant provider.

A `VehicleLocation` can contain:

- latitude;
- longitude;
- heading;
- speed where available; and
- timestamp.

For Volvo, the Location API request is enabled by the Vehicle Location feature.

For Polestar, the Vehicle Location feature similarly controls whether location is exposed as part of the returned `VehicleState`.

### Vehicle Weather can also obtain location

Vehicle Weather is a separate feature.

The Polestar weather implementation may internally request the vehicle's current location and use those coordinates to obtain weather information even if the separate Vehicle Location display feature is disabled.

This means:

**Disabling Vehicle Location does not necessarily prevent location from being retrieved while Vehicle Weather remains enabled.**

If a user does not want vehicle coordinates sent to Open-Meteo, Vehicle Weather must also be disabled.

The coordinates used internally for a weather lookup are not automatically assigned to `VehicleState.location` when the Vehicle Location feature itself is disabled.

---

## Location and Cached Vehicle Snapshots

`VehicleState.cacheableCopy` deliberately sets:

`location: nil`

before the snapshot is persisted.

Therefore the cached `VehicleState` payload stored in:

- SQLite `vehicle_snapshots`; and
- the `cached_vehicle_snapshots_v1` `UserDefaults` fallback

does not contain the current `VehicleState.location`.

This protection is real but must not be described as:

> Location never reaches disk.

That statement is false because other persistence paths separately store location information.

---

## Location and Historical Telemetry

`VehicleStateStore.save(_:)` records historical telemetry in SQLite when sufficient telemetry is available.

The `telemetry_logs` table contains:

- VIN;
- timestamp;
- odometer;
- manual trip meter;
- automatic trip meter;
- average consumption;
- ambient temperature;
- latitude;
- longitude.

When the current `VehicleState` contains location, its latitude and longitude are passed to the historical telemetry recorder.

The telemetry recorder avoids writing identical stationary readings on every refresh, but historical coordinates can still remain in SQLite.

The distinction is therefore:

> Current location is excluded from cached vehicle snapshots, but location may be persisted separately as historical telemetry.

---

## Location and Charging History

When a new charging session begins, Hisingen may derive a charging-location string from the current vehicle coordinates.

When both latitude and longitude are available, the current implementation formats the value to four decimal places before storing it with the charging-session header.

A charging-session record can therefore contain an approximate location such as:

`57.7089°, 11.9746°`

This location remains part of the charging-session record even after individual charging samples are pruned.

The value is local to the user's SQLite database unless explicitly exported, copied, backed up, or shared.

---

## Saved Charging Schedules

Provider charging schedules and saved charging locations are separate from Hisingen's locally recorded charging-session history.

Hisingen should avoid persisting provider-specific charging-location metadata that is not required by the application's domain model.

Do not confuse:

- a provider-defined saved charging location or schedule; with
- Hisingen's locally recorded approximate location for a historical charging session.

They represent different data flows.

---

## Reverse Geocoding

Hisingen uses Apple's `CLGeocoder` when it needs to turn coordinates into a human-readable place or address.

The Hisingen-side reverse-geocoding cache is an in-memory dictionary.

It is not persisted by `ReverseGeocoder`.

The cache exists only for the lifetime of the running process.

Coordinates processed through `CLGeocoder` are still handled by Apple infrastructure according to Apple's own privacy practices.

A process-local cache must not be described as meaning that Apple does not receive the coordinates.

---

## Open-Meteo

For Polestar Vehicle Weather, Hisingen first attempts to obtain current vehicle coordinates.

When valid coordinates are available, Hisingen can call Open-Meteo using latitude and longitude in the request URL.

The request does not intentionally contain:

- VIN;
- manufacturer password;
- OAuth access token;
- refresh token;
- Volvo Client Secret; or
- VCC API Key.

Open-Meteo receives the coordinates and ordinary HTTP request metadata.

If the Open-Meteo lookup fails, the provider-specific weather path may be attempted where supported.

---

## GitHub Pages OAuth Callback

The normal Volvo OAuth flow uses the static callback:

`https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html`

The browser receives the authorization result from Volvo and visits the callback page.

The callback then hands control back to the Hisingen application through its registered local URL scheme.

The callback page is not:

- an authentication database;
- a token exchange service;
- a Hisingen account service;
- a vehicle-data backend; or
- a remote-command relay.

However, the browser request itself passes through GitHub-hosted infrastructure.

Documentation must therefore avoid saying that no authentication-related information ever passes through a third party.

The more accurate statement is:

> Hisingen does not operate a backend that receives the OAuth response; the Volvo browser callback passes through a static GitHub Pages bridge before returning to the local application.

---

## Vehicle Snapshot Persistence

`VehicleState.cacheableCopy` is the form stored as the last-known vehicle snapshot.

It deliberately excludes:

- registration number;
- owner first name;
- current location;
- exterior vehicle image data;
- interior vehicle image data; and
- the transient unavailable-feature list.

It currently retains substantially more than battery state.

Depending on what was available in the original state, the cached copy can contain:

- VIN;
- model and model year;
- battery level;
- range;
- charging state;
- charging measurements;
- vehicle availability;
- odometer;
- service information;
- fluid warnings;
- exterior and lock state;
- vehicle-health details;
- software information;
- charging schedules;
- climate status and timers;
- trip meters;
- connectivity information;
- air-quality information;
- battery diagnostics;
- weather;
- capability observations;
- charging samples and domain charging sessions;
- powertrain;
- fuel state;
- selected vehicle-configuration information;
- warranty information;
- timestamps; and
- data warnings.

Any documentation claiming the cached snapshot is only "battery and charging data" is outdated.

Adding a new field to `VehicleState` does not automatically determine whether it is safe to persist.

Every new privacy-sensitive field must be reviewed before being added to `cacheableCopy`.

---

## Owner Name and Registration Number

`VehicleState.cacheableCopy` explicitly removes:

- `ownerFirstName`; and
- `registrationNo`.

These values may be available in the live in-memory vehicle state and displayed to the user when enabled, but they are not included in the persisted cached vehicle snapshot.

They must not be reintroduced into persistence without an explicit privacy review.

---

## Vehicle Images

Exterior and interior vehicle image bytes are not included in `VehicleState.cacheableCopy`.

Image caching has its own lifecycle and should be documented separately if persistent image caching is introduced or changed.

Screenshots included in the public repository must be manually reviewed for:

- VIN;
- registration number;
- account information;
- exact location;
- addresses;
- QR codes;
- developer credentials; and
- other identifying information.

Image metadata should also be treated as potentially sensitive.

---

## SQLite Vehicle Database

Hisingen uses a local SQLite database at:

`~/Library/Application Support/Hisingen/hisingen.sqlite3`

SQLite may also use:

- `hisingen.sqlite3-wal`
- `hisingen.sqlite3-shm`

The current database contains tables for:

- vehicle snapshots;
- charging sessions;
- charging samples;
- battery-health history;
- historical telemetry; and
- remote-command audit information.

The database contains VINs.

Depending on enabled features and available telemetry, it may also contain precise or approximate vehicle location information.

The database must therefore be treated as sensitive local application data.

It must not be:

- bundled into application releases;
- uploaded as a diagnostic artifact by default;
- committed to Git;
- attached to public issues; or
- copied into CI artifacts.

---

## UserDefaults

Hisingen uses `UserDefaults` for ordinary preferences and several local state caches.

Examples include:

- active provider;
- selected VIN;
- vehicle nicknames;
- enabled features;
- notification preferences;
- electricity price;
- UI preferences;
- cached vehicle snapshots;
- charging baselines; and
- non-secret developer identifiers.

`UserDefaults` must not be used for passwords, refresh tokens, Client Secrets, VCC API Keys, or other sensitive authentication material.

VIN and cached vehicle information stored through `UserDefaults` should still be considered local sensitive data even though they are not authentication secrets.

---

## Data Deletion

Current sign-out behavior calls the global vehicle-state clear path.

That clears:

- the SQLite vehicle-history database;
- cached vehicle snapshots; and
- charging-state baselines

before the provider-specific sign-out operation completes.

Provider authentication cleanup is then handled by the provider integration.

This is materially different from saying:

> Sign-out leaves the historical database intact.

That statement is not true for the current implementation.

See [`../data-retention.md`](../data-retention.md) for detailed retention and deletion semantics.

---

## Backups and Copies

"Local only" does not mean "exists in exactly one place."

Local Hisingen data can be copied by:

- Time Machine;
- filesystem snapshots;
- other backup software;
- disk cloning;
- user-created exports;
- diagnostic bundles; or
- manual file copies.

Hisingen cannot delete copies that have already been created outside its application storage.

---

## Logging

Logs must not intentionally contain:

- account passwords;
- access tokens;
- refresh tokens;
- OAuth authorization codes;
- Client Secrets;
- VCC API Keys;
- authentication cookies; or
- complete authenticated API responses.

VINs, locations, account identifiers, registration numbers, and user-facing error messages should be treated as privacy-sensitive when logging.

Use privacy-aware OSLog interpolation where applicable.

---

## Diagnostics and Issue Reports

Public issue templates and troubleshooting documentation should instruct users to sanitize:

- VIN;
- registration number;
- email address;
- owner information;
- vehicle coordinates;
- home address;
- OAuth codes;
- tokens;
- custom developer credentials; and
- raw provider responses.

Security-sensitive information should be reported privately according to [`../../SECURITY.md`](../../SECURITY.md).

---

## Privacy Invariants

Changes should preserve the following invariants:

1. Account authentication secrets are not stored in the vehicle-history database.
2. Production credentials are not committed to the repository.
3. No Hisingen-operated backend receives user vehicle telemetry.
4. Current `VehicleState.location` is not included in the cached snapshot.
5. Historical location storage is documented wherever telemetry or charging history stores it.
6. Third-party coordinate processing is opt-in through the relevant feature.
7. Vehicle Weather is treated as location-sensitive even if Vehicle Location display is disabled.
8. New `VehicleState` fields receive a persistence/privacy review before being added to `cacheableCopy`.
9. Public logs, fixtures, screenshots, and documentation use sanitized data.
10. Data-retention documentation is updated when storage behavior changes.

---

## Review Checklist for New Features

Any feature that introduces a new vehicle field should answer:

- Is the field fetched from the provider?
- Is it displayed only in memory?
- Is it included in `VehicleState.cacheableCopy`?
- Is it written to SQLite separately?
- Is it written to `UserDefaults`?
- Is it stored in Keychain?
- Is it sent to a third party?
- Is it exported?
- Does it contain location or personal information?
- How long is it retained?
- What deletes it?
- Can it appear in logs or diagnostics?
- Does the root privacy policy need to change?

If any answer changes Hisingen's privacy model, update the relevant documentation in the same pull request.

---

## Source-of-Truth Documents

The privacy documentation has intentionally separate responsibilities:

- [`../../PRIVACY.md`](../../PRIVACY.md) — user-facing privacy policy.
- [`privacy.md`](privacy.md) — technical data-flow and privacy boundaries.
- [`../data-retention.md`](../data-retention.md) — retention and deletion.
- [`../architecture/persistence.md`](../architecture/persistence.md) — storage implementation.

These documents must not contradict each other.