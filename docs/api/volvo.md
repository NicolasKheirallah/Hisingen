# Volvo API

Unlike Polestar, this is built on Volvo's **official, documented** Connected Vehicle API v2, Energy API v2, and Location API v1 — accessed through the Volvo Developer Portal, which requires each user to register their own free application (Client ID, Client Secret, VCC API Key). Volvo On Call, the legacy consumer API, was shut down by Volvo in 2025 and is not used here at all.

Source: `Services/API/VolvoAPI.swift`, `VolvoModels.swift`, `VolvoServiceError.swift`.

> **See also: `docs/api/volvo-backend-map.md`** — internal-only, not published in this repository.
> Holds real captured payload samples and the full Volvo ID scope/grant-type catalog (broader
> than what Hisingen actually requests); everything Hisingen implements is covered here instead.

## Host and gateway

Everything goes through one host, `api.volvocars.com`, behind Volvo's API gateway (`vcc-api-key` header) plus an OAuth2 Bearer token from `volvoid.eu.volvocars.com`. There is no undocumented/internal endpoint in use — every call in `VolvoAPI.swift` targets a product family (`connected-vehicle`, `energy`, `location`) that Volvo documents and gates behind a Developer Portal subscription.

## Authentication

See [authentication.md](authentication.md#volvo-oauth2-pkce-with-a-redirect-uri-bridge) for the full flow, including why a GitHub Pages bridge page is involved. The normal sign-in requests `openid` plus the Connected Vehicle and Energy read scopes. Volvo's approval-gated `conve:lock`, `conve:unlock`, `conve:engine_start_stop`, `conve:honk_flash`, and `location:read` scopes are requested only after the user enables **Approved Volvo permissions** in Settings and signs in again.

## Vehicle discovery

`GET /connected-vehicle/v2/vehicles` returns only a VIN list (`[{"vin": "..."}]`). For each VIN, Hisingen separately calls vehicle details (below) to build a display title (`"<model> · <model year>"`), falling back to the bare VIN if that call fails.

## Supported endpoints

| Category | Endpoint | Data | Hisingen field(s) |
|---|---|---|---|
| Vehicle identity | `GET /connected-vehicle/v2/vehicles/{vin}` | Model, model year, colour (flat `externalColour` string or `externalColours` array), gearbox, battery capacity (kWh), fuel type, exterior/interior image URLs | `modelName`, `modelYear`, `externalColour`, `gearbox`, `powertrain` (see below), image |
| Energy state | `GET /energy/v2/vehicles/{vin}/state` | Battery SOC, range, charging status/type, charger connection/power state, current limit, power in watts, target SOC, time to target | `batteryPercentage`, `rangeKm`, `chargingState`, `chargingType`, `chargingPowerWatts`, etc. |
| Energy capabilities | `GET /energy/v2/vehicles/{vin}/capabilities` | Per-field hardware support flags | Feeds `.chargeTarget`/`.chargingCurrentLimit` capability probes — see [architecture/capabilities.md](../architecture/capabilities.md) |
| Doors | `GET /connected-vehicle/v2/vehicles/{vin}/doors` | Central lock, door/hood/tailgate/charge-lid state | `exteriorStatus` |
| Windows | `GET /connected-vehicle/v2/vehicles/{vin}/windows` | Window/sunroof state | `exteriorStatus` |
| Tyres | `GET /connected-vehicle/v2/vehicles/{vin}/tyres` | Per-wheel warning enum (no numeric pressure); `NO_SENSOR` / `SYSTEM_FAULT` map to a distinct `.sensorFault` state | `healthDetails.tyres` (warning only, `kilopascals` always `nil`) |
| Diagnostics | `GET /connected-vehicle/v2/vehicles/{vin}/diagnostics` | Service warning, fluid warnings, days/distance to service | `daysToService`, `distanceToServiceKm`, `fluidWarnings` |
| Engine diagnostics | `GET /connected-vehicle/v2/vehicles/{vin}/engine` | Coolant and oil warning enums (not measured levels) | `healthDetails.warnings` / `reportedWarnings` |
| Brakes | `GET /connected-vehicle/v2/vehicles/{vin}/brakes` | Brake fluid warning (live: this is the *only* field returned; `frontBrakePadStatus` / `rearBrakePadStatus` / `parkingBrakeStatus` are decoded defensively but were absent) | Merged into `healthDetails` |
| Bulb/light warnings | `GET /connected-vehicle/v2/vehicles/{vin}/warnings` | 16+ individual light sensors | Synthesized into a single `.exteriorLight` warning if any are active |
| Odometer | `GET /connected-vehicle/v2/vehicles/{vin}/odometer` | Total mileage | `odometerKm` |
| Statistics | `GET /connected-vehicle/v2/vehicles/{vin}/statistics` | Trip meters, avg consumption (lifetime / since-charge / automatic-trip) / speed, distance-to-empty | `tripMeterManualKm`, `tripMeterAutomaticKm`, `averageSpeedKmH`, `fuelRangeKm`, `batteryDiagnostics.averageConsumption*` |
| Location | `GET /location/v1/vehicles/{vin}/location` | GeoJSON coordinates, optional altitude, and heading | `location` (requires subscribing to the Location API product and enabling approved permissions) |
| Engine status | `GET /connected-vehicle/v2/vehicles/{vin}/engine-status` | Running state | Minor |
| Command accessibility | `GET /connected-vehicle/v2/vehicles/{vin}/command-accessibility` | Whether commands are currently deliverable and why not (`NO_INTERNET`, `POWER_SAVING_MODE`, `CAR_IN_USE`) | `availability`, including the provider reason |
| Command list | `GET /connected-vehicle/v2/vehicles/{vin}/commands` | Exact commands exposed for this VIN | Runtime probes for locks, reduced guard, climate, honk/flash, and engine start |
| Climate commands | `POST .../commands/climatization-start|stop` | Command result only; no live activity, cabin temperature or setpoint resource | Remote commands only; `climateStatus` remains unavailable |
| Remote commands | `POST /connected-vehicle/v2/vehicles/{vin}/commands/{action}` | — | See below |

The fuel endpoint is fetched for combustion and hybrid vehicles. The command list is fetched
when any remote feature is enabled so controls are based on exact VIN support rather than a
model-wide guess.

A live sweep against a production vehicle (2026-08) confirmed the list above is the complete
available surface: `/environment`, `/climatization-status`, `/status`, `/battery`, `/position`,
`/software`, `/ota` and every other guessed path 404; Energy API v1 (`/energy/v1/...`) and the
Extended Vehicle API return HTTP 410 Gone; and `/location/v1` returns 403 because this
application is not entitled to the Location API product (requesting `location:read` also makes
the whole authorization fail `invalid_scope`).

## Model identification and powertrain

`VolvoPowertrain.classify(fuelType:)` reads the vehicle-details `fuelType` string: contains `"ELECTRIC"` and not `"PETROL"`/`"DIESEL"` → `.bev`; both electric and fuel present → `.phev` (or `.mildHybrid` if the string contains `"MHEV"` or `"HYBRID"` without `"PLUG"`); fuel only → `.ice`; neither → `.unknown`.

Model name → `VehicleModelFamily` is substring matching in `VehicleCapabilities.swift`'s `volvoModel(from:)` — order-sensitive (`"xc40"` is checked before the generic `"c40"` substring so an `XC40` isn't misidentified as a `C40`, confirmed by `VolvoModelIdentificationTests`).

## Vehicle images

Both fields live inside the single vehicle-details response (`GET /connected-vehicle/v2/vehicles/{vin}` → `images: { exteriorImageUrl, interiorImageUrl }`), unlike Polestar which needs a second, separately-authenticated call. There is no angle/camera-position variant of either — each is exactly one fixed studio photo.

- **`exteriorImageUrl`** — one exterior render. Fetched by `VolvoAPI.fetchCarImage(vin:imageUrlString:)`, cached bare-VIN-keyed (`CarImageCache.shared.save(bytes, for: vin)`, no angle). Since there's only ever one URL, Settings' angle picker (`CarRenderAngle`, Polestar-only concept) has nothing to switch between for Volvo — the UI hides that picker for this brand rather than showing four buttons that would all display the same photo.
- **`interiorImageUrl`** — one cabin render, fetched by the analogous `fetchInteriorImage(vin:imageUrlString:)`, cached under a separate `"<VIN>_interior"` key so it doesn't collide with the exterior entry.
- **Volvo's own documentation disagrees with itself on the interior field's key name.** The Connected Vehicle API v2 [endpoint reference page](https://developer.volvocars.com/apis/connected-vehicle/v2/endpoints/vehicle/) shows a real (non-placeholder) example response using `"interiorImageUrl"` — an actual `cas.volvocars.com/image/vbsnext-v4/interior/...` CDN URL, clearly copied from a genuine API response. But the same API version's [OpenAPI/Specification page](https://developer.volvocars.com/apis/connected-vehicle/v2/specification/) defines the `Images` schema with `"internalImageUrl"` instead — both pages captured the same day (archived 2025-12-17), so this isn't a stale-vs-current version mismatch, just an inconsistency in Volvo's own docs. `VolvoModels.swift`'s `Images` struct decodes both key names defensively (custom `init(from:)`, preferring `interiorImageUrl` and falling back to `internalImageUrl`) rather than betting on either being the one Volvo's backend actually ships — following the same defensive-decoding philosophy already used elsewhere for Volvo (see below).

## Capabilities

`GET /energy/v2/vehicles/{vin}/capabilities` returns a nested `getEnergyState` capability whose
children describe individual energy fields. Hisingen decodes that documented nested shape (and
the older flat shape defensively), caches it for one hour, and feeds charge-target and
charging-current-limit probes. The Connected Vehicle command list supplies the equivalent
per-VIN probes for remote controls. See [architecture/capabilities.md](../architecture/capabilities.md) and [domain/capability-matrix.md](../domain/capability-matrix.md).

## Remote commands

`VolvoAPI.dispatchCommand` implements the public Connected Vehicle v2 command cases below:

| `RemoteCommand` case | Volvo command name |
|---|---|
| `.lock` | `lock` |
| `.lockReducedGuard` | `lock-reduced-guard` |
| `.unlock` | `unlock` |
| `.startClimate` | `climatization-start` |
| `.stopClimate` | `climatization-stop` |
| `.honkAndFlash` | `honk-flash` |
| `.flashLights` | `flash` |
| `.honkHorn` | `honk` |
| `.startEngine(runtimeMinutes:)` | `engine-start` (body contains a clamped 1–15 minute runtime) |
| `.stopEngine` | `engine-stop` |

Everything else (`unlockTrunk`, window control, charge-target/amp-limit, schedules, pre-cleaning, OTA) throws `RemoteCommandError.unsupported`. Commands without documented parameters send an empty JSON body; engine start sends only `runtimeMinutes`. Climate temperature and seat-heating values are not sent because Volvo's public climatization endpoint accepts no such body.

The `/commands` list labels honk+flash `HONK_AND_FLASH`, but its `href` — the real invocation
path, verified live — is `honk-flash`, which is what `dispatchCommand` POSTs. `VolvoCommandDTO.normalizedName`
derives capability probes from the `href` segment for the same reason.

Response parsing uses `VolvoCommandResponseDTO`. Every documented `invokeStatus` failure value
(`REJECTED`, `TIMEOUT`, `CONNECTION_FAILURE`, `VEHICLE_IN_SLEEP`, `CAR_ERROR`,
`NOT_ALLOWED_PRIVACY_ENABLED`, `NOT_ALLOWED_WRONG_USAGE_MODE`, plus the older
`UNLOCK_TIME_FRAME_PASSED` / `UNABLE_TO_LOCK_DOOR_OPEN`) maps to a specific user-facing
message via `failureReason`; `VEHICLE_IN_SLEEP` is phrased as retryable and `UNKNOWN` is *not*
a failure. Accepted/delivered/completed outcomes are preserved, and Volvo's staged unlock
response (`readyToUnlock` plus `readyToUnlockUntil`) is handled without falsely changing the
visible lock state. Successful and failed provider attempts are written to the local command
audit with duration. Connected Vehicle API v2 commands are synchronous; Hisingen does not call
the removed legacy sent-command status endpoints.

Command POSTs are throttled locally (`throttleCommandDispatch`, one per 6 s) to stay inside
Volvo's documented 10-requests-per-minute limit on the invocation endpoints.

Concurrency: single-in-flight-per-VIN via `remoteCommandsInFlight`, same pattern as the refresh path.


## Defensive decoding

Volvo's response envelope is inconsistent across endpoints/versions in practice: some return `{"data": {...}}`, others return the object at the root; some fields are wrapped (`{"value": ..., "timestamp"/"updatedAt": ...}`), others are bare scalars. `VolvoEnvelope<Payload>` and `VolvoField<Value>` both defensively decode either shape — validated against `volvo-vehicle-details-partial.json` (a bare-root fixture) and a dedicated "wrapped vs. bare scalar" decode test. This is not something Volvo's documentation guarantees; it's an empirical accommodation.

## Relevant tests

`Tests/HisingenTests/Unit/VolvoDecodingTests.swift` (the largest Volvo test file), `VolvoModelIdentificationTests.swift`, `VolvoKeychainIsolationTests.swift`; live (credential-gated, opt-in) coverage in `Tests/HisingenTests/Integration/LiveVolvoIntegrationTests.swift`'s `LiveVolvoReadOnlyIntegrationTests`, run on demand via `live-integration.yml` — see [operations/ci.md](../operations/ci.md).
