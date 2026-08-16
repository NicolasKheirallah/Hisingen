# Polestar API

Polestar publishes no supported third-party vehicle-cloud API. Everything in this document describes interfaces reconstructed by observing the official client's behavior — see [overview.md#api-confidence](overview.md#api-confidence) for a per-item confidence rating. None of it is an official guarantee, and it can change without notice.

Source: `Services/API/PolestarAPI.swift`, `PolestarGRPC.swift`, `PolestarGRPCCapabilities.swift`, `PolestarGRPCRemote.swift`, `GraphQLModels.swift`, `PolestarServiceError.swift`.

## Two protocols, four hosts

Polestar 2 and later share connectivity infrastructure with Volvo (both are Geely-group brands), which is why Polestar's backend topology looks the way it does:

- **GraphQL** (`pc-api.polestar.com`) supplies coarse telemetry and vehicle discovery.
- **Hand-rolled gRPC-over-HTTP/2** against two further backends — **C3** (`cnepmob.volvocars.com` for discovery, then a discovered host) and **PCCS/Chronos** (`api.pccs-prod.plstr.io:443`, fixed) — supplies everything else: exterior/lock state, tyre pressures, detailed warnings, software/OTA, schedules, climate, connectivity, air quality, precise location, weather, amp limit, target SOC, and remote command dispatch.

There is no `SwiftProtobuf` dependency and no `.proto` schema file anywhere in the repo. `PolestarGRPC.swift`'s `enum Protobuf` implements varint/zigzag encoding, wire-type parsing, and the 5-byte gRPC HTTP/2 frame envelope (1-byte compression flag + 4-byte big-endian length) entirely by hand, sending `Content-Type: application/grpc` and a `User-Agent: grpc-java-okhttp/1.68.2` string that deliberately mimics the official Android app's networking stack.

## Authentication

See [authentication.md](authentication.md#polestar-scraped-oidc-login) for the full login sequence. Summary: OIDC discovery against `polestarid.eu.polestar.com`, PKCE, a scraped PingFederate login form submission, redirect interception via a custom `URLSessionTaskDelegate`, and a token exchange. Only the refresh token is persisted.

## Account and vehicle discovery

Two GraphQL queries are merged, because Polestar has (at least) two vehicle-discovery mechanisms in production simultaneously:

- **`GetVDMSCars`** (against the app-backend host, `X-PolestarId-Authorization` header instead of standard `Authorization`, `apollo-kotlin` client-library headers mimicking the Android app) — treated as primary.
- **`GetConsumerCarsV2`** (legacy, against the main GraphQL host) — used to fill gaps in VDMS results, and as the sole source for `pno34`/`structureWeek` (needed for vehicle images — VDMS never returns them).

If both return nothing, a manually-entered VIN (validated: 17 characters, uppercase, no `I`/`O`/`Q`) produces a synthetic single-car list — the guest/secondary-account path.

## Core telemetry (GraphQL)

`CarTelematicsV2($vins: [String!]!)` is built dynamically by `telematicsQuery(features:)` — it conditionally includes `odometer{...}` and `health{...}` sub-selections only when those features are enabled, so a user with vehicle-health disabled doesn't even request that data. Supplies: battery percentage, range, charging status, time-to-full, odometer summary, and fluid-warning summary.

## Charging

- **Battery %, range, charging status/time-to-full** — GraphQL `carTelematicsV2.battery`.
- **Charging power, current, voltage, connection type** — gRPC `BatteryService/GetLatestBattery` (C3), fields not available via GraphQL at all.
- Whichever source has the newer `reportedAt` timestamp wins for the fields both provide.
- **Target SOC** — gRPC `TargetSocService/GetTargetSoc` (PCCS), independently cached for 15 minutes (`targetCache`, separate from the general capability cache).
- **Amp limit** — gRPC `AmpLimitService/GetAmpLimit`/`SetAmpLimit` (PCCS).
- **Charging schedules** (global + saved-location + departure) — `GlobalChargeTimerService`, `ChargeLocationService` (PCCS). If *both* fail, the failure is only re-thrown when at least one is an infrastructure-level error (auth/network/server/rate-limit); otherwise it silently returns an empty schedule list rather than failing the whole refresh.

See [domain/charging.md](../domain/charging.md).

## Climate

gRPC `ParkingClimatizationService/GetLatestParkingClimatization` (C3), parsed by `PolestarGRPC.parseClimate` — which handles two distinct response schema variants (an older "legacy" shape and a newer "Digital Twin" shape, distinguished by whether the first protobuf field is a nested message). Climate timers come from `ParkingClimateTimerService` (PCCS).

## Openings, locks, alarm

gRPC `ExteriorService/GetLatestExterior` (C3), `PolestarGRPC.parseExterior` — same dual-schema handling as climate. Results are merged with the previously cached snapshot (`ExteriorSnapshot.merging(previous:)`) to fill gaps when a partial response omits fields.

## Warnings, tyres, service

gRPC `HealthService/GetHealth` (C3), `PolestarGRPC.parseHealth` — positional protobuf fields (documented only by inline comments like `case 26:` for power state) decode per-tyre pressures (fields 39–42) and warnings (fields 9–12), exterior light warnings (fields 14–35), and the low-voltage-battery warning (field 38). Tyre-pressure-values capability is only recorded as supported if at least one numeric pressure value is actually present — a response with only warning flags doesn't count. Fluid warnings (`brake fluid`, `engine coolant`, `oil`, `washer fluid`) come from the GraphQL `health` field instead, string-enum-decoded and treated as "warning" unless the value contains `NO_WARNING`/`UNSPECIFIED`.

## Software / OTA

gRPC `OtaDiscoveryService/GetSoftwareInfo` and `SchedulerService` (`GetSchedule`/`Schedule`/`InstallNow`/`CancelSchedule`), both C3.

`GetSoftwareInfo` takes `{1 vin, 2 locale}` and answers `{1 CarSoftwareInfo}`, decoded by `PolestarGRPC.parseSoftware`:

| Field | Meaning |
| --- | --- |
| `1` | `software_id` — the handle every OTA write is addressed to |
| `2` | `description {1 name, 2 short_desc, 3 long_desc}` |
| `3` | `qb_code` (unused) |
| `4` | `state` → `SoftwareUpdateState` via `PolestarGRPC.softwareState` |
| `6` | `new_sw_version` |
| `8` | `schedule_info {2 scheduled_at}` |
| `10` | `state_timestamp` |

**`new_sw_version` is not simply "the installed version".** Its meaning depends on `state`: while an update is pending it names the *target* version and the running version is not reported at all; only in the settled states (`0 UNKNOWN`, `9 INSTALLATION_COMPLETED`, `14 INSTALLATION_UNKNOWN`) does it describe what is on the car. `parseSoftware` therefore populates exactly one of `installedVersion`/`latestAvailableVersion`, and `VehicleState.mergingLastKnown` carries the last settled reading forward so the UI can still show "installed → available" mid-rollout. Nothing is substituted when the field is absent — the version stays nil rather than being filled with a plausible-looking constant.

The three writes all answer with `{1 Scheduler}` = `{1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by}`, where `status` is `0 UNKNOWN, 1 IDLE, 2 SCHEDULED, 3 INSTALL`. `GetSchedule` is a second source of `software_id`, which is what keeps "cancel a scheduled installation" reachable when `GetSoftwareInfo` has nothing to report.

### Verified against a live Polestar 2

- **`state = 15`** is real and means *available*. It is outside the 0–14 range of the enum this was modelled on, and arrives with a populated description and no `schedule_info`.
- **`relative_time` on `Schedule` is in MINUTES, bounded 2…10080** (7 days). The backend rejects anything else with `grpc-status 3: relativeTime should be between 2 to 10080!`. Sending seconds — as this client used to — put every request out of range.
- **"Available" does not mean installable.** With the update in state 15, both `Schedule` and `InstallNow` answer `grpc-status 3: The software with software id <id> is not ready to be scheduled!`. The car downloads the payload on its own schedule; only after that does the scheduler accept a request. `PolestarGRPC.installableStates` therefore excludes `.available`.
- **Errors arrive as Trailers-Only**, i.e. `HTTP 200` with `grpc-status`/`grpc-message` in the *initial* headers and `Content-Length: 0`. Those are readable. A status delivered in genuine HTTP/2 trailers is not — `URLSession` exposes no trailer API — which is why `lastMessage` treats "200 with no frame" as a refusal rather than a malformed response.
- **`GetSoftwareInfo` and `GetSchedule` are server-streaming**: the server writes one frame and holds the stream open. They must be read incrementally (`firstMessage`); `URLSession.data(for:)` simply times out.

## Connectivity, trip meters, odometer

`OdometerService/GetOdometer` is the primary source (C3); if it fails, `DashboardService/GetLatestDashboard` is used as a fallback for odometer/trip data and legacy connectivity fields — the primary odometer call is wrapped in an empty `catch {}` before falling back, suggesting it's known to be unreliable on some vehicles.

## Location and weather

`DtlInternetService/GetLastKnownLocation` (C3) supplies coordinates. For weather, Hisingen prefers the third-party, unauthenticated **Open-Meteo** API over Polestar's own `WeatherService/GetWeatherReport` (C3) — it geolocates first, calls Open-Meteo, and only falls back to the Polestar gRPC weather service if Open-Meteo fails or coordinates are unavailable.

## Vehicle images

A separate, unauthenticated-by-bearer-token GraphQL call: `GetCarImages($pno34, $structureWeek, $modelYear, $locale)` against the *public* API host, authenticated by an `x-api-key` header instead of a bearer token, locale hardcoded to `en-GB`. Only runs when `pno34`/`structureWeek` are known (legacy-query-only fields — VDMS never returns them, see above).

**Exterior studio renders only — no interior/cabin image exists in this API surface.** The query returns two parallel arrays, each holding the *same* set of camera angles in two rendering styles:

```graphql
getCarImages(pno34: $pno34, structureWeek: $structureWeek, modelYear: $modelYear, locale: $locale) {
  transparent { url angle }   # PNG, background removed
  opaque { url angle }        # JPG, studio backdrop included
}
```

- **`transparent` vs `opaque`** — same camera angle, two file formats/treatments. `PolestarAPI.swift`'s `fetchCarImage()` prefers the `transparent` array and only falls back to `opaque` if it's empty (`let pool = transparent.isEmpty ? opaque : transparent` — the app never mixes the two, and never exposes the opaque/backdrop style at all when a transparent one exists).
- **`angle` is a plain `Int`, not a named enum in the schema** — Polestar's API gives no semantic label, just a position index. A real captured response (from the independent [pypolestar](https://github.com/pypolestar/pypolestar) project's test fixtures, Polestar 3) shows **six angles, `0`–`5`**, e.g.:
  ```
  https://car-images.polestar.com/359/2024/summary-transparent/EA/72300/001190/R80000/_/19/_/XPLUSS/_/1/_/default/0.png
  ...
  https://car-images.polestar.com/359/2024/summary-transparent/EA/72300/001190/R80000/_/19/_/XPLUSS/_/1/_/default/5.png
  ```
  `Preferences.swift`'s `CarRenderAngle` only defines **four** named cases (`frontThreeQuarter=0`, `rearThreeQuarter=1`, `sideProfile=2`, `overhead=3`) — angles `4` and `5` have no UI-facing name and can't be selected in Settings' angle picker. Since nobody has visually confirmed what camera position `4`/`5` actually show, no name is guessed here rather than inventing an unverified label.
- **The data layer already fetches and caches all six**, even though only four are selectable: `fetchCarImage()` downloads whichever angle is requested (falling back `requestedAngle → 0 → 1 → pool.first` if the exact match is missing), then kicks off background `Task.detached` fetches for *every other angle present in the pool* — `for other in pool { ... CarImageCache.shared.save(otherBytes, for: vin, angle: otherAngle) }` (no filtering by whether that angle has a UI name). So a Polestar user's disk cache silently accumulates angle-`4`/`5` images that the Settings picker can never surface.
- Selection preference order when the exact requested angle isn't in the pool: exact match → angle `0` → angle `1` → array's first element.
- Cached per VIN *and* angle (`CarImageCache.shared.save(bytes, for: vin, angle: angle)`), so switching angles after the first fetch is instant (disk-cache hit, no network).

## Schedules

Global charge timer, per-location charge schedules (with precise coordinates and location aliases explicitly discarded before reaching the domain model — see [security/privacy.md](../security/privacy.md)), and climate timers — all PCCS/Chronos gRPC calls, all merged into `VehicleState.chargingSchedules`/`climateTimers`.

## Capability probing

See [architecture/capabilities.md](../architecture/capabilities.md) for the general model. Polestar-specific numbers: positive results cached 10 minutes (climate/exterior/air-quality) or 60 minutes (everything else); negative results back off 5 minutes (transient), 1 hour (`invalidResponse`), or 6 hours (`incompatibleAPI`) before being retried. Only successful probes are ever recorded — there's no explicit "unsupported" signal from a failed probe, only the conservative static per-model table can assert that.

## Remote commands

Dispatched through `invocation.InvocationService/<Method>` (generic write RPC — `ClimatizationStart/Stop`, `PreCleaning`, `Lock`, `Unlock`, `WindowControl`, `HonkFlash`), plus dedicated `chronos.services.*` RPCs for charging/schedule/OTA writes. Every request is hand-built protobuf with validated bounds (e.g. charge target 40–100%, amp limit 1–64A, temperature 16–30°C in 0.5° steps) rejected client-side before any network call.

**Client and scope.** Hisingen signs in as the polestar.com **web** OIDC client (`l3oopkc_10`, redirect `https://www.polestar.com/sign-in-callback`) and requests `openid profile email customer:attributes customer:attributes:write`.

The mobile-app client (`lp8dyrd_10`, `polestar-explore://explore.polestar.com`) was tried and **does not work for this app**: it authenticates and returns a token, but `pc-api.polestar.com/eu-north-1/mystar-v2` rejects that token with `UnauthorizedException`, so `getConsumerCarsV2` returns nothing and vehicle discovery fails outright. Verified live against a real account — the web client returns the vehicle, the app client returns 401. The web client accepts `customer:attributes:write` on request without disturbing discovery, so it is the only combination that gives both.

`GetVDMSCars` on the app-backend host answers **HTTP 428** for both clients (a force-update-version precondition), so `getConsumerCarsV2` is currently the only working discovery query.

### Two OAuth clients are required

Remote commands are gated on a **client-id allowlist**, which is separate from OAuth scope. C3 states the rule when it refuses:

```
Client id l3oopkc_10 is not a required client id:
[h4Yf0b, ahP7e4, polxplore, addpolestarcnhere, caraccessmonitorunner,
 polmonrunnereuprod, lp8dyrd_10, micwkvi_20, r7p9qtm_10, 9jahaga_10,
 vhujyni_10, mo2qy9h_10, nxpwptn_10, 3nyjn7a_10, d0v7mnk_10]
```

Neither client is sufficient alone:

| | `l3oopkc_10` (web) | `lp8dyrd_10` (app) |
| --- | --- | --- |
| `getConsumerCarsV2` (vehicle discovery) | ✅ | ❌ `UnauthorizedException` |
| C3 `invocation.InvocationService` | ❌ not on allowlist | ✅ accepted |

So `PolestarAPI` signs in twice and holds a token from each, using the command token only for invocation-backed commands. The command sign-in is best-effort — if it fails, reads and OTA still work and only those commands become unavailable. Both callbacks must be recognised by `OAuthRedirectDelegate`, since the app client's is a custom scheme `URLSession` cannot load.

**Invocation lives on C3, not PCCS.** `pccs.invocation.v1.InvocationService` exists but answers every write with `Unauthenticated: Access denied` regardless of client. Verified live: `Lock` via C3 with the command token returns `outcome = completed`.

PCCS is still correct for chronos *reads* (`GetTargetSoc` returns real data); chronos *writes* are unverified.

Dispatch is compiled into every build ([ADR-0009](../adr/0009-remote-commands-compiled-into-all-builds.md) removed the former `HISINGEN_EXPERIMENTAL_REMOTE` flag).

Outcome parsing reads a numeric status field from the response: `1`→accepted, `4`→delivered, `6`→completed; `9`/`10`/`12` map to specific rejection reasons (privacy setting, vehicle mode, conflicting command); anything else surfaces the raw message field.

## Error handling

See [errors-and-rate-limits.md](errors-and-rate-limits.md). Polestar-specific: `Retry-After` is parsed from both raw-seconds and HTTP-date formats; a 401/403 on any gRPC call short-circuits directly to `.authenticationRequired` before even inspecting the `grpc-status` header; streaming responses that time out mid-stream are treated as complete rather than failed if at least one frame was already received (an empirical workaround for the backend not always closing the HTTP/2 stream cleanly).

## Relevant tests

`Tests/HisingenTests/Unit/GraphQLDecodingTests.swift`, `VehicleCapabilityParsingTests.swift`, `RequestConstructionTests.swift`, `ResumePathTests.swift`, `RemoteCommandTests.swift`, `VehicleCrossModelTests.swift`; live (credential-gated, opt-in) coverage in `Tests/HisingenTests/Integration/LivePolestarIntegrationTests.swift`.
