# Persistence

Three independent storage layers, none of them a database. See [security/keychain.md](../security/keychain.md) for the Keychain layer's security properties specifically.

## Inventory

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
| Vehicle telemetry snapshot | `UserDefaults` (`cached_vehicle_snapshots_v1`, JSON) | Per VIN | 7 days (self-cleaning on read) | Partially — see below | No versioned migration; a decode failure is treated as "no cache" |
| Charging state-machine baseline | `UserDefaults` (`charging_baselines_v1`, JSON) | Per VIN | 7 days (self-cleaning on read) | No | Same as above |
| Capability observations (`VehicleProbedCapabilities`) | Embedded inside the cached `VehicleState` | Per VIN | 6-hour staleness window, independent of the 7-day store TTL | No | Same as above |
| Update-check result | `UserDefaults` | Global | Persistent, re-checked every 24h | No | — |
| Reverse-geocode cache | In-memory only (`ReverseGeocoder` actor) | Global | Process lifetime | No (never written to disk) | N/A |

## Why each item is stored

- **Account email / refresh tokens / passwords** — so the user doesn't have to sign in on every launch. Kept in Keychain, never newly written to `UserDefaults` or on-disk caches.
- **Feature selection, notification toggles, theme, etc.** — plain user preferences; no reason to protect them beyond normal `UserDefaults` behavior.
- **Vehicle telemetry snapshot** — lets the app show *something* immediately at launch and during vehicle switching, without waiting on a network round trip, and lets it keep showing the last known state if the vehicle is asleep or the network is down.
- **Charging baseline** — the charging state machine (`ChargingTransitionDetector`) needs to remember what state it last saw per VIN so a relaunch doesn't re-fire a "charging started" notification for a session that began before the app was last quit.
- **Capability observations** — so a positively-observed capability (e.g., "this Polestar 3 does support the amp-limit endpoint") survives a relaunch instead of needing to be re-probed from the conservative static default every time.

## Cache design: `VehicleStateStore`

**Purpose:** last-known-good telemetry and charging baseline, per VIN, safe to persist.

**Key:** VIN string (uppercased where relevant), two top-level `UserDefaults` keys hold a `[VIN: JSON]` dictionary each.

**Scope:** per VIN — switching vehicles or brands never leaks one vehicle's cached state into another's.

**TTL:** 7 days, enforced on *read*, not by a background sweep — `snapshot(for:)`/`baseline(for:)` check the stored `fetchedAt`/`sampledAt` against `Date()` and silently drop (and remove) anything older, returning `nil`. A vehicle that hasn't been polled in over a week shows the normal "no cached data" cold-start UI rather than a week-old snapshot.

**Schema/versioning:** the `_v1` suffix on both key names is the entire versioning scheme — there is no migration path from a `_v1` schema to a hypothetical `_v2`. If a future change to `VehicleState`'s `Codable` shape isn't backward-compatible, `try? decoder.decode(...)` simply fails and the store returns `nil` for that VIN, which the app treats identically to "never cached" — a cold start, not a crash. See [technical-debt.md](technical-debt.md) for whether this is adequate going forward.

**Corruption handling:** any JSON decode failure (`try?`) degrades to "no cache" — never a crash, never a partial/garbage state shown to the user.

**Privacy scrubbing before persistence:** `VehicleState.cacheableCopy` — the version actually written to disk — is built by calling `VehicleState`'s initializer with only a specific subset of fields passed explicitly (VIN, battery/charging/range, availability, model name/year, powertrain/fuel, capability observations, charging samples/sessions, `fetchedAt`/`vehicleReportedAt`/`dataWarnings`). Every field *not* in that explicit list — including `registrationNo`, `ownerFirstName`, `odometerKm`, service/fluid warnings, `weather`, `imageData`, and also `exteriorStatus`, `healthDetails`, `softwareInfo`, schedules, `climateStatus`, trip meters, `connectivity`, `airQuality`, `batteryDiagnostics`, and `location` — silently falls back to that initializer's default (`nil`/empty), so none of it reaches disk. The on-disk cache is closer to "battery and charging state only" than a documented exclusion list would suggest; adding a new field to `VehicleState` does not cache it automatically — it has to be explicitly threaded through `cacheableCopy`. See [security/privacy.md](../security/privacy.md).

**What happens loading an older Hisingen version's cache:** because the storage is a `[VIN: JSON]`-shaped `UserDefaults` dictionary rather than a single monolithic blob, an old cache from a prior version simply decodes per-VIN — if the shape is compatible it loads, if not that one VIN's entry fails silently as above. There's no explicit cross-version migration test for this in the current test suite (see [testing/strategy.md](../testing/strategy.md) for coverage gaps).

## Cache design: capability cache (per-provider, not `VehicleStateStore`)

Both `PolestarAPI` and `VolvoAPI` keep their own **in-memory-only** (not persisted directly — only the *result* embedded in `VehicleProbedCapabilities` on the returned `VehicleState` gets persisted, via `VehicleStateStore`) short-lived caches to avoid re-probing an endpoint on every single refresh:

- **Polestar:** `capabilityCache` — 10 minutes for climate/exterior/air-quality, 60 minutes for everything else; plus a separate negative-result `capabilityBackoff` table (6h for `incompatibleAPI`, 1h for `invalidResponse`, 5min otherwise).
- **Volvo:** `capabilityCache` for the energy-capabilities endpoint (1 hour), plus a per-endpoint `endpointBackoff` (flat 5 minutes) for any other optional field that fails.

These are documented in full in [architecture/capabilities.md](capabilities.md) since they're inseparable from the capability-discovery model, not a generic caching concern.
