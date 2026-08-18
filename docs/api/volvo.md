# Volvo API

Unlike Polestar, this is built on Volvo's **official, documented** Connected Vehicle API v2, Energy API v2, and Location API v1 — accessed through the Volvo Developer Portal, which requires each user to register their own free application (Client ID, Client Secret, VCC API Key). Volvo On Call, the legacy consumer API, was shut down by Volvo in 2025 and is not used here at all.

Source: `Services/API/VolvoAPI.swift`, `VolvoModels.swift`, `VolvoServiceError.swift`.

> **See also: `docs/api/volvo-backend-map.md`** — internal-only, not published in this repository.
> Holds real captured payload samples and the full Volvo ID scope/grant-type catalog (broader
> than what Hisingen actually requests); everything Hisingen implements is covered here instead.

## Host and gateway

Everything goes through one host, `api.volvocars.com`, behind Volvo's API gateway (`vcc-api-key` header) plus an OAuth2 Bearer token from `volvoid.eu.volvocars.com`. There is no undocumented/internal endpoint in use — every call in `VolvoAPI.swift` targets a product family (`connected-vehicle`, `energy`, `location`) that Volvo documents and gates behind a Developer Portal subscription.

## Authentication

See [authentication.md](authentication.md#volvo-oauth2-pkce-with-a-redirect-uri-bridge) for the full flow, including why a GitHub Pages bridge page is involved. Scopes requested: `openid` + 18 `conve:*`/`energy:*` read scopes. Note the unused `restrictedScopes` gap — see 

## Vehicle discovery

`GET /connected-vehicle/v2/vehicles` returns only a VIN list (`[{"vin": "..."}]`). For each VIN, Hisingen separately calls vehicle details (below) to build a display title (`"<model> · <model year>"`), falling back to the bare VIN if that call fails.

## Supported endpoints

| Category | Endpoint | Data | Hisingen field(s) |
|---|---|---|---|
| Vehicle identity | `GET /connected-vehicle/v2/vehicles/{vin}` | Model, model year, colour, gearbox, battery capacity (kWh), fuel type, exterior/interior image URLs | `modelName`, `modelYear`, `externalColour`, `gearbox`, `powertrain` (see below), image |
| Energy state | `GET /energy/v2/vehicles/{vin}/state` | Battery SOC, range, charging status, current, power, target SOC | `batteryPercentage`, `rangeKm`, `chargingState`, `chargingPowerWatts`, etc. |
| Energy capabilities | `GET /energy/v2/vehicles/{vin}/capabilities` | Per-field hardware support flags | Feeds `.chargeTarget`/`.chargingCurrentLimit` capability probes — see [architecture/capabilities.md](../architecture/capabilities.md) |
| Doors | `GET /connected-vehicle/v2/vehicles/{vin}/doors` | Central lock, door/hood/tailgate/charge-lid state | `exteriorStatus` |
| Windows | `GET /connected-vehicle/v2/vehicles/{vin}/windows` | Window/sunroof state | `exteriorStatus` |
| Tyres | `GET /connected-vehicle/v2/vehicles/{vin}/tyres` | Per-wheel warning enum (no numeric pressure) | `healthDetails.tyres` (warning only, `kilopascals` always `nil`) |
| Diagnostics | `GET /connected-vehicle/v2/vehicles/{vin}/diagnostics` | Service warning, fluid warnings, days/distance to service | `daysToService`, `distanceToServiceKm`, `fluidWarnings` |
| Brakes | `GET /connected-vehicle/v2/vehicles/{vin}/brakes` | Brake fluid warning | Merged into `healthDetails` |
| Bulb/light warnings | `GET /connected-vehicle/v2/vehicles/{vin}/warnings` | 16+ individual light sensors | Synthesized into a single `.exteriorLight` warning if any are active |
| Odometer | `GET /connected-vehicle/v2/vehicles/{vin}/odometer` | Total mileage | `odometerKm` |
| Statistics | `GET /connected-vehicle/v2/vehicles/{vin}/statistics` | Trip meters, avg consumption/speed, distance-to-empty | `tripMeterManualKm`, `tripMeterAutomaticKm`, `averageSpeedKmH`, `fuelRangeKm` |
| Location | `GET /location/v1/vehicles/{vin}/location` | GeoJSON coordinates + heading | `location` (requires subscribing to the Location API product separately) |
| Engine status | `GET /connected-vehicle/v2/vehicles/{vin}/engine-status` | Running state | Minor |
| Command accessibility | `GET /connected-vehicle/v2/vehicles/{vin}/command-accessibility` | Whether commands are currently deliverable | `availability` — the **only** source of Volvo's online/offline state; there's no `.unavailable` mapping, only `.available`/`.unknown` |
| Climatization status | `GET /connected-vehicle/v2/vehicles/{vin}/climatization-status` | Activity, interior/target temperature, timer | `climateStatus` |
| Remote commands | `POST /connected-vehicle/v2/vehicles/{vin}/commands/{action}` | — | See below |

**Fetched by no code path despite having a fixture/DTO:** `VolvoFuelDTO` (dead — only exercised by a decode test) and `VolvoCommandDTO`/`VolvoCommandsListDTO`.

## Model identification and powertrain

`VolvoPowertrain.classify(fuelType:)` reads the vehicle-details `fuelType` string: contains `"ELECTRIC"` and not `"PETROL"`/`"DIESEL"` → `.bev`; both electric and fuel present → `.phev` (or `.mildHybrid` if the string contains `"MHEV"` or `"HYBRID"` without `"PLUG"`); fuel only → `.ice`; neither → `.unknown`.

Model name → `VehicleModelFamily` is substring matching in `VehicleCapabilities.swift`'s `volvoModel(from:)` — order-sensitive (`"xc40"` is checked before the generic `"c40"` substring so an `XC40` isn't misidentified as a `C40`, confirmed by `VolvoModelIdentificationTests`).

## Vehicle images

Both fields live inside the single vehicle-details response (`GET /connected-vehicle/v2/vehicles/{vin}` → `images: { exteriorImageUrl, interiorImageUrl }`), unlike Polestar which needs a second, separately-authenticated call. There is no angle/camera-position variant of either — each is exactly one fixed studio photo.

- **`exteriorImageUrl`** — one exterior render. Fetched by `VolvoAPI.fetchCarImage(vin:imageUrlString:)`, cached bare-VIN-keyed (`CarImageCache.shared.save(bytes, for: vin)`, no angle). Since there's only ever one URL, Settings' angle picker (`CarRenderAngle`, Polestar-only concept) has nothing to switch between for Volvo — the UI hides that picker for this brand rather than showing four buttons that would all display the same photo.
- **`interiorImageUrl`** — one cabin render, fetched by the analogous `fetchInteriorImage(vin:imageUrlString:)`, cached under a separate `"<VIN>_interior"` key so it doesn't collide with the exterior entry.
- **Volvo's own documentation disagrees with itself on the interior field's key name.** The Connected Vehicle API v2 [endpoint reference page](https://developer.volvocars.com/apis/connected-vehicle/v2/endpoints/vehicle/) shows a real (non-placeholder) example response using `"interiorImageUrl"` — an actual `cas.volvocars.com/image/vbsnext-v4/interior/...` CDN URL, clearly copied from a genuine API response. But the same API version's [OpenAPI/Specification page](https://developer.volvocars.com/apis/connected-vehicle/v2/specification/) defines the `Images` schema with `"internalImageUrl"` instead — both pages captured the same day (archived 2025-12-17), so this isn't a stale-vs-current version mismatch, just an inconsistency in Volvo's own docs. `VolvoModels.swift`'s `Images` struct decodes both key names defensively (custom `init(from:)`, preferring `interiorImageUrl` and falling back to `internalImageUrl`) rather than betting on either being the one Volvo's backend actually ships — following the same defensive-decoding philosophy already used elsewhere for Volvo (see below).

## Capabilities

The one explicit backend-provided capability signal in either provider: `GET /energy/v2/vehicles/{vin}/capabilities`, cached 1 hour, feeding `.chargeTarget` and `.chargingCurrentLimit` with a definite `.supported`/`.unavailable` (Volvo's static default table is otherwise conservative — `.backendDependent` for most capabilities beyond locks/honk-flash/exterior/climate-start-stop/service-warnings). See [architecture/capabilities.md](../architecture/capabilities.md) and [domain/capability-matrix.md](../domain/capability-matrix.md).

## Remote commands

`VolvoAPI.dispatchCommand` implements **6 of `RemoteCommand`'s ~20 cases**:

| `RemoteCommand` case | Volvo command name |
|---|---|
| `.lock` | `lock` |
| `.unlock` | `unlock` |
| `.startClimate` | `climatization-start` |
| `.stopClimate` | `climatization-stop` |
| `.honkAndFlash` | `honk-flash` |
| `.flashLights` | `flash` |

Everything else (`unlockTrunk`, window control, charge-target/amp-limit, schedules, pre-cleaning, OTA) throws `RemoteCommandError.unsupported` — there's no Volvo implementation yet regardless of what the capability profile reports. `POST /connected-vehicle/v2/vehicles/{vin}/commands/{action}` is sent with an empty JSON body (`"{}"`) — parameters like requested climate temperature or seat heating from a `RemoteCommand.startClimate` payload are **not sent**, since Volvo's command endpoint here doesn't take a body.

Response parsing reads `invokeStatus` (`"COMPLETED"`/`"DELIVERED"` → `.completed`, else `.accepted`) from a raw, untyped JSON dictionary rather than a `Decodable` DTO — see 

Concurrency: single-in-flight-per-VIN via `remoteCommandsInFlight`, same pattern as the refresh path.


## Defensive decoding

Volvo's response envelope is inconsistent across endpoints/versions in practice: some return `{"data": {...}}`, others return the object at the root; some fields are wrapped (`{"value": ..., "timestamp"/"updatedAt": ...}`), others are bare scalars. `VolvoEnvelope<Payload>` and `VolvoField<Value>` both defensively decode either shape — validated against `volvo-vehicle-details-partial.json` (a bare-root fixture) and a dedicated "wrapped vs. bare scalar" decode test. This is not something Volvo's documentation guarantees; it's an empirical accommodation.

## Relevant tests

`Tests/HisingenTests/Unit/VolvoDecodingTests.swift` (26 tests, the largest Volvo test file), `VolvoModelIdentificationTests.swift`, `VolvoKeychainIsolationTests.swift`; live (credential-gated, opt-in) coverage in `Tests/HisingenTests/Integration/LiveVolvoIntegrationTests.swift`'s `LiveVolvoReadOnlyIntegrationTests`, run on demand via `live-integration.yml` — see [operations/ci.md](../operations/ci.md).
