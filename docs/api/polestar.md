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

gRPC `OtaDiscoveryService/GetSoftwareInfo` and `SchedulerService` (`GetSchedule`/`Schedule`/`InstallNow`/`CancelSchedule`), both C3. `PolestarGRPC.parseSoftware` maps a numeric protobuf field to `SoftwareUpdateState` (`available`, `downloading`, `downloaded`, `installing`, `completed`, `failed`, `deferred`, `scheduled`).

## Connectivity, trip meters, odometer

`OdometerService/GetOdometer` is the primary source (C3); if it fails, `DashboardService/GetLatestDashboard` is used as a fallback for odometer/trip data and legacy connectivity fields — the primary odometer call is wrapped in an empty `catch {}` before falling back, suggesting it's known to be unreliable on some vehicles.

## Location and weather

`DtlInternetService/GetLastKnownLocation` (C3) supplies coordinates. For weather, Hisingen prefers the third-party, unauthenticated **Open-Meteo** API over Polestar's own `WeatherService/GetWeatherReport` (C3) — it geolocates first, calls Open-Meteo, and only falls back to the Polestar gRPC weather service if Open-Meteo fails or coordinates are unavailable.

## Vehicle images

A separate, unauthenticated-by-bearer-token GraphQL call: `GetCarImages($pno34, $structureWeek, $modelYear, $locale)` against the *public* API host, authenticated by an `x-api-key` header instead of a bearer token, locale hardcoded to `en-GB`. Prefers a transparent render over an opaque one, and `angle == 0` over other angles. Only runs when `pno34`/`structureWeek` are known (legacy-query-only fields), and only once per session (`carImageData` cache).

## Schedules

Global charge timer, per-location charge schedules (with precise coordinates and location aliases explicitly discarded before reaching the domain model — see [security/privacy.md](../security/privacy.md)), and climate timers — all PCCS/Chronos gRPC calls, all merged into `VehicleState.chargingSchedules`/`climateTimers`.

## Capability probing

See [architecture/capabilities.md](../architecture/capabilities.md) for the general model. Polestar-specific numbers: positive results cached 10 minutes (climate/exterior/air-quality) or 60 minutes (everything else); negative results back off 5 minutes (transient), 1 hour (`invalidResponse`), or 6 hours (`incompatibleAPI`) before being retried. Only successful probes are ever recorded — there's no explicit "unsupported" signal from a failed probe, only the conservative static per-model table can assert that.

## Remote commands

Dispatched through `invocation.InvocationService/<Method>` (generic write RPC — `ClimatizationStart/Stop`, `PreCleaning`, `Lock`, `Unlock`, `WindowControl`, `HonkFlash`), plus dedicated `chronos.services.*` RPCs for charging/schedule/OTA writes. Every request is hand-built protobuf with validated bounds (e.g. charge target 40–100%, amp limit 1–64A, temperature 16–30°C in 0.5° steps) rejected client-side before any network call.

**Gated behind `HISINGEN_EXPERIMENTAL_REMOTE`.** `Package.swift` only defines this compile flag when the `HISINGEN_EXPERIMENTAL_REMOTE=1` environment variable is set at build time — never set in CI or release builds. Without it, `PolestarAPI.executeRemoteCommand` always throws `RemoteCommandError.unsupported` before touching the network, discarding the command. Even with the flag set for local experimentation, the real backend is expected to reject write calls from an unpaired client: gRPC status `16` (`UNAUTHENTICATED`) on a write RPC maps to the explicit message *"Polestar cloud backend requires official mobile app pairing for remote commands."* This is the concrete, code-level evidence behind Hisingen's "remote controls are unavailable" stance for Polestar — see [architecture/technical-debt.md](../architecture/technical-debt.md) and [security/threat-model.md](../security/threat-model.md).

Outcome parsing reads a numeric status field from the response: `1`→accepted, `4`→delivered, `6`→completed; `9`/`10`/`12` map to specific rejection reasons (privacy setting, vehicle mode, conflicting command); anything else surfaces the raw message field.

## Error handling

See [errors-and-rate-limits.md](errors-and-rate-limits.md). Polestar-specific: `Retry-After` is parsed from both raw-seconds and HTTP-date formats; a 401/403 on any gRPC call short-circuits directly to `.authenticationRequired` before even inspecting the `grpc-status` header; streaming responses that time out mid-stream are treated as complete rather than failed if at least one frame was already received (an empirical workaround for the backend not always closing the HTTP/2 stream cleanly).

## Relevant tests

`Tests/HisingenTests/Unit/GraphQLDecodingTests.swift`, `VehicleCapabilityParsingTests.swift`, `RequestConstructionTests.swift`, `ResumePathTests.swift`, `RemoteCommandTests.swift`, `VehicleCrossModelTests.swift`; live (credential-gated, opt-in) coverage in `Tests/HisingenTests/Integration/LivePolestarIntegrationTests.swift`.
