# Privacy Policy

_Last updated: 2026-08-19_

Hisingen is a native macOS application for viewing information from, and where supported controlling, compatible Polestar and Volvo vehicles.

Hisingen is an independent open-source project maintained by Nicolas Kheirallah. It is not affiliated with, endorsed by, sponsored by, or maintained by Polestar or Volvo Cars.

Hisingen is designed around a local-first model:

**Vehicle data is processed by the Hisingen application running on your Mac. Hisingen does not operate a backend that collects your vehicle data, credentials, location, or application usage.**

This policy explains what Hisingen accesses, what it stores locally, and when information may be sent to third-party services.

---

## 1. No Hisingen Backend

Hisingen does not operate:

- a vehicle-data server;
- an account service;
- a remote-command relay;
- an analytics platform;
- an advertising platform;
- a crash-reporting service that receives your vehicle data; or
- a cloud database containing Hisingen users' vehicles.

The Hisingen maintainer does not automatically receive your:

- VIN;
- vehicle telemetry;
- vehicle location;
- charging history;
- diagnostics;
- account credentials;
- authentication tokens;
- remote-command history; or
- application usage information.

You may choose to provide information manually when opening an issue, submitting a security report, sharing diagnostics, or otherwise contacting the maintainer.

Always sanitize sensitive information before sharing it.

---

## 2. Manufacturer Services

Hisingen communicates with services operated by the manufacturer associated with the vehicle you connect.

### Polestar

For Polestar vehicles, Hisingen communicates with Polestar-operated identity and vehicle services.

Depending on the features enabled, this may involve:

- account authentication;
- authentication tokens;
- VIN;
- vehicle telemetry;
- charging information;
- vehicle status;
- vehicle location;
- software information;
- diagnostics; and
- supported remote commands.

Some Polestar functionality used by Hisingen is based on undocumented interfaces observed from first-party behavior. These interfaces may change without notice.

### Volvo Cars

For Volvo vehicles, Hisingen communicates with Volvo Cars identity and API services.

Depending on the features enabled, this may involve:

- OAuth authorization information;
- access and refresh tokens;
- VIN;
- vehicle telemetry;
- charging information;
- diagnostics;
- vehicle location; and
- supported remote commands.

Official Hisingen releases include a default Volvo Developer application configuration so normal users do not need to create their own Volvo Developer Portal application.

Advanced users may optionally configure their own Volvo Developer application.

A custom configuration may include:

- Client ID;
- Client Secret; and
- VCC API Key.

Custom developer credentials are used locally by Hisingen when communicating with Volvo Cars and are not sent to a Hisingen-operated backend.

---

## 3. Authentication and Credentials

Hisingen handles authentication separately for each provider.

Sensitive authentication material that must persist between launches is stored using the macOS Keychain.

Depending on provider and configuration, this may include:

- refresh tokens;
- account authentication material;
- custom Volvo Client Secrets;
- custom Volvo VCC API Keys; and
- other provider credentials required to restore a session.

Non-secret identifiers and ordinary application preferences may be stored using macOS `UserDefaults`.

Hisingen does not use its local SQLite vehicle-history database to store account passwords, OAuth access tokens, refresh tokens, Client Secrets, or VCC API Keys.

Volvo account authentication is performed through Volvo Cars in the system browser. Hisingen does not directly ask the user for or store their Volvo ID password.

---

## 4. Local Vehicle Data

Hisingen stores some vehicle information locally to provide features such as:

- immediate display of the last known vehicle state;
- charging history;
- charging statistics;
- battery-health history;
- historical telemetry;
- capability information;
- remote-command audit information; and
- application diagnostics.

The primary local vehicle database is stored under the signed-in macOS user's Application Support directory:

`~/Library/Application Support/Hisingen/hisingen.sqlite3`

SQLite may also create companion files such as:

- `hisingen.sqlite3-wal`
- `hisingen.sqlite3-shm`

These files remain on the user's Mac unless copied by the user, another application, a backup system, or someone with access to the macOS account or filesystem.

Hisingen does not automatically upload this database to the maintainer.

---

## 5. Vehicle Snapshots

Hisingen stores a reduced copy of the most recently fetched vehicle state so the application can show useful information before the next network refresh or when the vehicle is temporarily unavailable.

The cached vehicle snapshot deliberately excludes several particularly sensitive or unnecessary fields, including:

- current vehicle location;
- owner first name;
- registration number;
- exterior vehicle image data; and
- interior vehicle image data.

However, the snapshot is not limited to battery information.

Depending on what was available during the refresh, it may include information such as:

- VIN;
- model and model year;
- battery and charging state;
- range;
- odometer;
- service information;
- vehicle warnings;
- exterior and lock state;
- software information;
- climate information;
- charging schedules;
- trip information;
- connectivity information;
- air-quality information;
- battery diagnostics;
- weather;
- powertrain and fuel information;
- vehicle configuration information; and
- capability observations.

Cached snapshots expire after seven days when accessed.

---

## 6. Vehicle Location

Vehicle location is sensitive information.

Hisingen may obtain location information from the relevant manufacturer when a feature requires it.

This can include:

- latitude;
- longitude;
- heading;
- timestamp; and
- information derived from those coordinates.

### Vehicle Location feature

When the Vehicle Location feature is enabled, Hisingen may retrieve the vehicle's latest reported position and display it in the application.

The current `VehicleState.location` value is deliberately excluded from Hisingen's cached vehicle snapshot.

This does **not** mean that coordinates are never written to disk.

When a vehicle state containing location data is processed, Hisingen's historical telemetry system may store latitude and longitude in the local SQLite database.

This historical telemetry remains local to the Mac unless the user exports, copies, backs up, or otherwise shares it.

### Charging history

If Hisingen has a vehicle location when a charging session begins, the charging-session record may store the location as coordinates rounded to four decimal places.

This is stored locally as part of the charging-session history.

### Reverse geocoding

Hisingen may use Apple's `CLGeocoder` to convert coordinates into a human-readable address or place.

Hisingen's own reverse-geocoding cache is kept in memory and is discarded when the application exits.

Apple may process the coordinates as part of providing the geocoding service, subject to Apple's own privacy practices.

---

## 7. Vehicle Weather

Vehicle Weather is an optional feature.

For Polestar vehicles, Hisingen may obtain the vehicle's location as part of retrieving weather information even when the separate Vehicle Location display feature is disabled.

When suitable coordinates are available, Hisingen may send:

- latitude; and
- longitude

to Open-Meteo to obtain current weather at the vehicle's location.

The Open-Meteo request does not need to contain:

- VIN;
- Polestar account credentials;
- Volvo account credentials;
- access tokens;
- refresh tokens; or
- developer API credentials.

If you do not want vehicle coordinates sent to Open-Meteo, leave Vehicle Weather disabled.

Weather information returned to Hisingen may itself be stored as part of locally cached or historical vehicle information.

---

## 8. Apple Services

When Hisingen uses Apple's reverse-geocoding functionality, vehicle coordinates may be processed through Apple's Core Location services.

Hisingen does not send manufacturer account passwords, authentication tokens, or developer API credentials to Apple for reverse geocoding.

Apple operates independently from Hisingen and processes information according to its own terms and privacy practices.

---

## 9. Open-Meteo

Hisingen may use Open-Meteo for optional vehicle-weather functionality.

The request may contain the vehicle's coordinates because those coordinates are necessary to determine weather at the vehicle's location.

Hisingen does not send the user's VIN, manufacturer password, authentication token, or Volvo developer credentials to Open-Meteo for this purpose.

Open-Meteo operates independently from Hisingen.

---

## 10. GitHub

Hisingen may communicate with GitHub for limited application functions.

### Update checks

When update checking is enabled, Hisingen may contact GitHub Releases to determine whether a newer version is available.

Vehicle telemetry, VINs, account credentials, authentication tokens, and vehicle coordinates are not required for this update check.

### Volvo OAuth callback

The normal Volvo OAuth flow may use Hisingen's static GitHub Pages callback:

`https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html`

Volvo redirects the OAuth authorization result to that HTTPS page, which then hands the result back to Hisingen through the application's registered `hisingen://` URL scheme.

The callback page is not a Hisingen account backend, token service, vehicle-data service, or remote-command relay.

Because the browser request passes through GitHub-hosted infrastructure, GitHub necessarily handles the HTTP request involved in that callback according to GitHub's own infrastructure and privacy practices.

---

## 11. Charging History

Hisingen can store charging-session information locally.

Depending on available telemetry, this can include:

- VIN;
- start time;
- end time;
- starting state of charge;
- ending state of charge;
- estimated energy delivered;
- peak charging power;
- average charging power;
- charging samples;
- voltage;
- current; and
- an approximate charging location when available.

Charging energy and cost information displayed by Hisingen may be calculated estimates rather than certified electricity-meter measurements.

---

## 12. Historical Telemetry

Hisingen can maintain local historical telemetry.

Depending on what the vehicle reports and which features are enabled, a telemetry record may include:

- VIN;
- timestamp;
- odometer;
- trip-meter values;
- average consumption;
- ambient temperature;
- latitude; and
- longitude.

Hisingen avoids recording a new telemetry row on every refresh when the vehicle has not moved.

Historical telemetry remains local to the user's Mac.

---

## 13. Battery Health History

Hisingen may retain battery-health milestones locally to provide long-term degradation history.

These records may contain:

- VIN;
- timestamp;
- odometer;
- state-of-health value;
- degradation value; and
- effective usable battery capacity.

Some battery-health values may be calculated or interpreted by Hisingen rather than directly reported as authoritative manufacturer measurements.

The UI and documentation should distinguish derived values from provider-reported values where appropriate.

---

## 14. Remote-Command History

Hisingen may maintain a local audit record of remote-command activity.

A record may contain:

- VIN;
- command type;
- execution time;
- outcome or status;
- duration; and
- an error description when applicable.

This information is stored locally for diagnostics and auditing.

Hisingen does not operate a server that collects remote-command history.

---

## 15. Data Retention

Current retention behavior is documented in detail in:

[`docs/data-retention.md`](docs/data-retention.md)

In summary:

- cached vehicle snapshots expire after seven days;
- charging-state baselines expire after seven days;
- historical charging samples and telemetry can be pruned using Hisingen's maintenance functionality, with a 90-day cutoff by default;
- charging-session summaries may remain after individual charging samples are pruned;
- battery-health milestones are retained for long-term history;
- remote-command audit information remains until local data is cleared; and
- signing out currently clears Hisingen's local vehicle database and cached vehicle state in addition to ending the provider session.

Retention behavior may change as Hisingen evolves. The technical retention document should be updated whenever persistence behavior changes.

---

## 16. Signing Out and Clearing Data

Signing out performs more than simply removing an authentication token.

In the current implementation, signing out clears:

- locally cached vehicle snapshots;
- charging-state baselines;
- Hisingen's local vehicle-history database; and
- provider authentication state handled by the applicable provider integration.

Application preferences that are not part of vehicle history may remain.

Clearing local application data does not necessarily remove copies that already exist in:

- Time Machine;
- other backup systems;
- filesystem snapshots;
- exported CSV files;
- diagnostic files previously created by the user; or
- copies manually shared elsewhere.

---

## 17. macOS Backups

Local Hisingen data may be included in normal macOS or third-party backups depending on the user's configuration.

This can include the SQLite database, `UserDefaults`, exported files, and other local application data.

Users should protect backups containing Hisingen information according to the sensitivity of their vehicle data.

---

## 18. Logs and Diagnostics

Hisingen uses local logging for application diagnostics.

The application should not intentionally log:

- passwords;
- access tokens;
- refresh tokens;
- OAuth authorization codes;
- Client Secrets;
- VCC API Keys; or
- complete authentication responses.

Logs and diagnostic exports can still contain contextual information.

Review diagnostic information before sharing it.

Do not publish raw authenticated API responses in GitHub issues.

---

## 19. Notifications

Hisingen may create local macOS notifications for vehicle events.

Depending on enabled features, notifications can reveal information such as:

- charging status;
- battery level;
- lock state;
- vehicle warnings; or
- software-update information.

Notification visibility is controlled by macOS.

Users who do not want this information visible on the lock screen should configure macOS notification privacy settings appropriately.

---

## 20. Analytics and Advertising

Hisingen does not include Hisingen-operated:

- usage analytics;
- advertising tracking;
- marketing pixels;
- behavioral profiling; or
- vehicle telemetry collection.

Hisingen does not sell user data.

Third-party services contacted by Hisingen may maintain normal infrastructure logs according to their own policies.

---

## 21. Information You Should Not Share Publicly

Do not post the following in public GitHub issues, discussions, screenshots, or logs:

- account passwords;
- access tokens;
- refresh tokens;
- OAuth authorization codes;
- Volvo Client Secrets;
- Volvo VCC API Keys;
- complete VINs;
- registration numbers;
- personal email addresses;
- precise vehicle coordinates;
- home addresses;
- authentication cookies; or
- raw authenticated API responses.

Use sanitized or obviously fake values instead.

Security-sensitive reports should follow the process in [SECURITY.md](SECURITY.md).

---

## 22. Open Source

Hisingen's source code is publicly available.

Users and contributors can inspect how the application:

- communicates with vehicle providers;
- stores credentials;
- stores vehicle information;
- handles location;
- communicates with optional external services; and
- performs remote commands.

The public source repository does not contain users' runtime vehicle databases or account data.

Production Volvo developer configuration used by official releases is supplied during the trusted release build and is not committed to the repository.

---

## 23. Third-Party Privacy

Hisingen depends on services operated by other organizations, including:

- Polestar;
- Volvo Cars;
- Apple;
- Open-Meteo; and
- GitHub.

Hisingen does not control their infrastructure, logs, retention, or privacy practices.

Use of those services is also subject to their respective policies and terms.

---

## 24. Changes to This Policy

This policy may change when Hisingen's features, storage model, integrations, or external-service usage change.

Material privacy changes should update:

- this policy;
- `docs/security/privacy.md`;
- `docs/data-retention.md`; and
- `docs/architecture/persistence.md`

in the same change whenever applicable.

---

## 25. Contact

Hisingen is maintained by **Nicolas Kheirallah**.

For ordinary non-sensitive issues, use the Hisingen GitHub repository.

For security or privacy vulnerabilities, follow the private reporting instructions in:

[SECURITY.md](SECURITY.md)

Do not include credentials, authentication tokens, complete VINs, precise vehicle locations, or other sensitive information in public reports.

---

## Technical Documentation

For implementation-level details, see:

- [`docs/security/privacy.md`](docs/security/privacy.md)
- [`docs/data-retention.md`](docs/data-retention.md)
- [`docs/architecture/persistence.md`](docs/architecture/persistence.md)