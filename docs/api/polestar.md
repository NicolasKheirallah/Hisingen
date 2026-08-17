# Polestar API

Polestar publishes no supported third-party vehicle-cloud API. Everything in this document describes interfaces reconstructed by observing the official client's behavior and live probing against a real Polestar 2 (MY2023) — see [overview.md#api-confidence](overview.md#api-confidence) for a per-item confidence rating. None of it is an official guarantee, and it can change without notice.

Source: `Services/API/PolestarAPI.swift`, `PolestarGRPC.swift`, `PolestarGRPCCapabilities.swift`, `PolestarGRPCRemote.swift`, `GraphQLModels.swift`, `PolestarServiceError.swift`.

> **See also: `docs/api/polestar-backend-map.md`** (with raw transcripts in
> `docs/api/polestar-probe-transcripts.md`) — internal-only, not published in this repository.
> Between them they hold the complete host/service/method/field map,
> the two-client allowlist rule, the master remote controls matrix, Chronos writes, the full `SoftwareState` enum,
> the OTA rollout control plane analysis, error semantics, transport quirks, and newly discovered capabilities.

---

## Two protocols, four hosts

Polestar 2 and later share connectivity infrastructure with Volvo (both are Geely-group brands), which is why Polestar's backend topology looks the way it does:

- **GraphQL** (`pc-api.polestar.com`) supplies coarse telemetry and vehicle discovery.
- **Hand-rolled gRPC-over-HTTP/2** against two further backends:
  - **C3** (`cnepmob.volvocars.com` for discovery, then `cepmobtoken.eu.prod.c3.volvocars.com:443`) — supplies exterior/lock state, tyre pressures, detailed health warnings, software/OTA discovery/scheduling, climate status, connectivity, air quality (CleanZone), precise location, weather, and remote command invocation.
  - **PCCS/Chronos** (`api.pccs-prod.plstr.io:443`, fixed) — supplies charging target SOC, amp/current limit, global and saved-location charging timers, departure timers, climate timers, and schedule overrides.

There is no `SwiftProtobuf` dependency and no `.proto` schema file anywhere in the repo. `PolestarGRPC.swift`'s `enum Protobuf` implements varint/zigzag encoding, wire-type parsing, and the 5-byte gRPC HTTP/2 frame envelope (1-byte compression flag + 4-byte big-endian length) entirely by hand, sending `Content-Type: application/grpc` and a `User-Agent: grpc-java-okhttp/1.68.2` string that deliberately mimics the official Android app's networking stack.

---

## Authentication

See [authentication.md](authentication.md#polestar-scraped-oidc-login) for the full login sequence. Summary: OIDC discovery against `polestarid.eu.polestar.com`, PKCE, a scraped PingFederate login form submission, redirect interception via a custom `URLSessionTaskDelegate`, and a token exchange. Only the refresh token is persisted in Keychain.

---

## Account and vehicle discovery

Two GraphQL queries are supported:

- **`GetVDMSCars`** (against the app-backend host, `X-PolestarId-Authorization` header instead of standard `Authorization`, `apollo-kotlin` client-library headers mimicking the Android app) — primary on mobile.
- **`GetConsumerCarsV2`** (against the main GraphQL host `mystar-v2`) — used to fill gaps in VDMS results, and as the sole source for `pno34`/`structureWeek` (needed for vehicle images — VDMS never returns them).

If both return nothing, a manually-entered VIN (validated: 17 characters, uppercase, no `I`/`O`/`Q`) produces a synthetic single-car list — the guest/secondary-account path.

---

## Core telemetry (GraphQL)

`CarTelematicsV2($vins: [String!]!)` is built dynamically by `telematicsQuery(features:)` — it conditionally includes `odometer{...}` and `health{...}` sub-selections only when those features are enabled, so a user with vehicle-health disabled doesn't even request that data. Supplies: battery percentage, range, charging status, time-to-full, odometer summary, and fluid-warning summary.

---

## Charging

- **Battery %, range, charging status/time-to-full** — GraphQL `carTelematicsV2.battery`.
- **Charging power (W), current (A), voltage (V), connection type (AC/DC)** — gRPC `BatteryService/GetLatestBattery` (C3), fields not available via GraphQL.
- Whichever source has the newer `reportedAt` timestamp wins for the fields both provide.
- **Target SOC** — gRPC `TargetSocService/GetTargetSoc` and `SetTargetSoc` (PCCS), verified live (`SetTargetSoc(90) → completed`).
- **Amp limit** — gRPC `AmpLimitService/GetAmpLimit` and `SetAmpLimit` (PCCS, 1–64A).
- **Charging schedules** (global + saved-location + departure) — `GlobalChargeTimerService`, `ChargeLocationService` (PCCS).
- **Charge Now override** — `ChargeNowService/StartOverrideChargeTimer` and `StopOverrideChargeTimer` (PCCS).

See [domain/charging.md](../domain/charging.md).

---

## Climate

gRPC `ParkingClimatizationService/GetLatestParkingClimatization` (C3), parsed by `PolestarGRPC.parseClimate` — which handles two distinct response schema variants (legacy and Digital Twin). Climate timers are managed via `ParkingClimateTimerService` (PCCS).

For remote start:
- **Polestar 2:** Vehicle manages climate setpoint automatically to comfort temperature based on in-car settings.
- **Polestar 3 & 4:** Full temperature setpoint (16–30°C in 0.5° increments) and zoned front/rear seat heating + steering wheel heating controls are supported.

---

## Openings, locks, alarm

gRPC `ExteriorService/GetLatestExterior` (C3), `PolestarGRPC.parseExterior` — captures central lock state, individual door statuses (front left, front right, rear left, rear right), frameless windows, hood, tailgate, charge lid flap, panoramic sunroof, and perimeter alarm status. Results are merged with the previously cached snapshot (`ExteriorSnapshot.merging(previous:)`) to fill gaps when a partial response omits fields.

---

## Warnings, tyres, service

gRPC `HealthService/GetHealth` (C3), `PolestarGRPC.parseHealth` — decodes individual tyre pressures in kPa (fields 39–42) and warnings (fields 9–12), 22 exterior light/bulb warning indicators (fields 14–35), and the 12V low-voltage battery warning (field 38). Fluid warnings (`brake fluid`, `engine coolant`, `oil`, `washer fluid`) come from GraphQL `health`.

---

## Software / OTA Architecture

gRPC `OtaDiscoveryService/GetSoftwareInfo` and `SchedulerService` (`GetSchedule`/`Schedule`/`InstallNow`/`CancelSchedule`), both on C3.

`GetSoftwareInfo` takes `{1 vin, 2 locale}` and answers `{1 CarSoftwareInfo}`:

| Field | Meaning |
| :--- | :--- |
| `1` | `software_id` — UUID handle for OTA operations |
| `2` | `description {1 name, 2 short_desc, 3 long_desc}` |
| `3` | `qb_code` (internal build code) |
| `4` | `state` → `SoftwareUpdateState` via `PolestarGRPC.softwareState` |
| `5` | `5400` (estimated installation duration in seconds = 90 min) |
| `6` | `new_sw_version` (target version when available, installed version when settled) |
| `8` | `schedule_info {2 scheduled_at}` |
| `10` | `state_timestamp` |
| `11` | `"SYSTEM"` (originator tag) |

### Why `AVAILABLE (15)` Cannot Be Forced Into `DOWNLOAD_READY` By Client APIs

1. **Rollout Cohorts:** When Polestar publishes a firmware update, it is announced to VIN cohorts in state `15` (`AVAILABLE`). The release notes and version are shown in the UI.
2. **Autonomous Vehicle Pull:** The vehicle's onboard Telematics Control Unit (TCU/VCM) checks in with the OTA gateway using machine credentials (mTLS hardware certificate) when local preconditions are satisfied (12V battery >75%, HV battery >40%, cellular reception, vehicle parked).
3. **No User Bypass:** Exhaustive probing proved that no user-dispatchable RPC exists to force immediate payload downloading. WakeUp with `OTA_DOWNLOAD` is not deployed, and all 82 potential candidate methods on C3 returned `Method not found`.
4. **Installation Gating:** Once the TCU downloads and cryptographically verifies the binary payload onto its secondary A/B partition (`DOWNLOAD_COMPLETED`, state 3), the cloud enables `SchedulerService/InstallNow` and `Schedule`.

---

## Connectivity, trip meters, odometer

`OdometerService/GetOdometer` (C3) supplies total odometer, manual trip meter, and automatic trip meter. `DashboardService/GetLatestDashboard` provides fallback telemetry and cellular connectivity diagnostics (LTE/5G, signal bars, wake reasons).

---

## Location and weather

`DtlInternetService/GetLastKnownLocation` (C3) supplies high-precision coordinates, altitude, heading, speed, parking brake engagement, and gear selector position. For weather, Hisingen uses the privacy-respecting **Open-Meteo** API, falling back to Polestar's `WeatherService/GetWeatherReport` if coordinates are unavailable.

---

## Vehicle images

A public GraphQL endpoint `GetCarImages($pno34, $structureWeek, $modelYear, $locale)` authenticated via `x-api-key`. Returns transparent PNGs across 6 camera angles (0–5). Hisingen downloads and caches all angles per VIN.

---

## Remote commands

Dispatched via `invocation.InvocationService/<Method>` on C3 using the mobile-app OAuth token (`lp8dyrd_10`):
- `Lock`: `{1: {1: vin}, 2: 0}`
- `Unlock`: `{1: {1: vin}, 2: 0}` (all doors) vs `{1: {1: vin}, 2: 1}` (trunk only)
- `WindowControl`: `{1: {1: vin}, 2: 1}` (open/vent) vs `{1: {1: vin}, 2: 2}` (close)
- `HonkFlash`: `{1: {1: vin}, 2: 0}` (honk+flash), `1` (honk only), `2` (flash only)
- `PreCleaning`: `{1: {1: vin}, 2: 1}` (start) vs `{1: {1: vin}, 2: 0}` (stop)
- `ClimatizationStart`: `{1: {1: vin}, 2: 1, ...}` (automatic comfort on P2, custom temp & seat/steering heat on P3/P4)
- `ClimatizationStop`: `{1: {1: vin}}`

Invocation responses return a lifecycle status: `1` (Accepted), `4` (Delivered), `6` (Completed), `9` (Privacy Rejection), `10` (Vehicle Mode Rejection), `12` (Conflicting Command).

---

## Error handling & Transport Quirks

- `GetSoftwareInfo` and `GetSchedule` are server-streaming HTTP/2 responses: read incrementally via `URLSession.bytes(for:)`.
- `URLSession` hides HTTP/2 trailers: immediate rejections arrive Trailers-Only (HTTP 200 with `grpc-status` in initial headers and `Content-Length: 0`).
- Always send `User-Agent: grpc-java-okhttp/1.68.2` and `vin: <VIN>` header on all C3/PCCS gRPC requests.
