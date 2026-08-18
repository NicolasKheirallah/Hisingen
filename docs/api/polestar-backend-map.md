# Polestar backend — complete map

Everything here was established by probing the live backend against a real vehicle
(Polestar 2, MY2023, VIN `YSM…228`) in August 2026, combined with official client analysis and
protocol reconstruction. Polestar publishes no third-party API; all of this is reverse-engineered
and can change without notice.

Where a claim is **measured**, the observed response is quoted. Where it is **inferred**,
it says so. One earlier probe in this effort produced a false positive and is documented
in [What the probes cannot tell you](#what-the-probes-cannot-tell-you) so the same mistake
isn't repeated. Every raw response quoted here is collected in
[polestar-probe-transcripts.md](polestar-probe-transcripts.md).

- [Hosts](#hosts)
- [OAuth clients — the two-client rule](#oauth-clients--the-two-client-rule)
- [Service map](#service-map)
- [Remote Controls Master Matrix](#remote-controls-master-matrix)
- [Chronos / PCCS Writes Master Matrix](#chronos--pccs-writes-master-matrix)
- [OTA / Software Architecture & Rollout Control Plane](#ota--software-architecture--rollout-control-plane)
- [Newly Discovered Capabilities Catalog](#newly-discovered-capabilities-catalog)
- [Error semantics](#error-semantics)
- [Transport quirks](#transport-quirks)
- [What the probes cannot tell you](#what-the-probes-cannot-tell-you)
- [Reproducing any of this](#reproducing-any-of-this)

---

## Hosts

| Host                                                     | Role                                    | Notes                                   |
| -------------------------------------------------------- | --------------------------------------- | --------------------------------------- |
| `polestarid.eu.polestar.com`                             | OIDC / PingFederate                     | Discovery, authorize, token, revocation |
| `pc-api.polestar.com/eu-north-1/mystar-v2/`              | GraphQL — telemetry + vehicle discovery | Web client only                         |
| `pc-api.polestar.com/eu-north-1/app-backend/api/graphql` | GraphQL — the mobile app's backend      | App client only                         |
| `pc-api.polestar.com/eu-north-1/mystar-public/`          | GraphQL — vehicle images                | API-key auth, no bearer                 |
| `cnepmob.volvocars.com`                                  | C3 discovery                            | Returns the gRPC host to use            |
| `cepmobtoken.eu.prod.c3.volvocars.com:443`               | **C3** gRPC                             | Discovered; Volvo infrastructure        |
| `api.pccs-prod.plstr.io:443`                             | **PCCS** gRPC                           | Fixed; Chronos reads and writes         |
| `vca-api-gateway.weu-prod.ecpaz.volvocars.biz:443`       | **VCA gateway** gRPC                     | In the v2 discovery doc; **unexplored** — see below |

The discovery document is **version-dependent**, which no client had noticed — the `Accept`
header changes what it returns. `v1` lists `c3`/`c3Lbs` (identical hosts); **`v2` lists a third,
previously-undocumented host**:

```
GET https://cnepmob.volvocars.com   Accept: application/volvo.cloud.cnepmob.v2+json
{"c3":{…}, "c3Lbs":{…},
 "vca-api-gateway":{"grpcHost":"vca-api-gateway.weu-prod.ecpaz.volvocars.biz","grpcPort":443,"grpcKeepAliveTime":45}}
```

(`v3` → HTTP 406, whose error body helpfully lists the acceptable versions: `v1`, `v2`,
`application/json`. `application/json` returns a third shape: `[{"name":"C3","url":…}]`.)

### The VCA gateway — a real lead, not yet cracked

`vca-api-gateway` ("Volvo Cars API gateway") is on Volvo's internal Azure mesh
(`.ecpaz.volvocars.biz`, region `weu-prod`) and is used by neither Hisingen nor either public
reference client. It is worth recording precisely because it is the one genuinely unexplored
surface and the natural place an OTA-download or wake service could live.

What is known, measured:

- It speaks gRPC and is fronted by **Istio/Envoy** (`server: istio-envoy`).
- Every request reaches a real upstream — `x-envoy-upstream-service-time` is always present,
  even unauthenticated — and that upstream answers `grpc-status 12` (UNIMPLEMENTED) with an
  **empty** `grpc-message`.
- This is true for *every* path, including a deliberately nonsensical one
  (`totally.Nonsense.Xyz/Nope`) and the known-real `ota_mobcache.OtaDiscoveryService/GetSoftwareInfo`
  (which works on C3). So the route is **catch-all to a single upstream**, and that upstream
  reveals a service only by implementing it.

The consequence: the method/service-name oracle that works on C3 **does not work here** — a real
service and an invented one both produce bare `12`. Enumerating this host by blind probing is
impossible. Cracking it requires the actual service names, which need a **traffic capture of the
official Polestar app hitting this host**, or a proto/APK teardown that names them — neither
exists publicly (GitHub code search for `vca-api-gateway`, `ecpaz`, and `ota_mobcache proto`
returns nothing). This is the concrete next step for anyone who can obtain such a capture.

---

## OAuth clients — the two-client rule

**This is the single most important thing in this document.** Polestar gates remote commands
on a _client-id allowlist_ that is independent of OAuth scope. C3 names the allowlist when it
refuses:

```
Client id l3oopkc_10 is not a required client id:
[h4Yf0b, ahP7e4, polxplore, addpolestarcnhere, caraccessmonitorunner,
 polmonrunnereuprod, lp8dyrd_10, micwkvi_20, r7p9qtm_10, 9jahaga_10,
 vhujyni_10, mo2qy9h_10, nxpwptn_10, 3nyjn7a_10, d0v7mnk_10]
```

Neither client Hisingen can use is sufficient alone:

| Capability                                | `l3oopkc_10` (web)                          | `lp8dyrd_10` (app)                        |
| ----------------------------------------- | ------------------------------------------- | ----------------------------------------- |
| Redirect URI                              | `https://www.polestar.com/sign-in-callback` | `polestar-explore://explore.polestar.com` |
| `mystar-v2` GraphQL (`getConsumerCarsV2`) | ✅ returns the vehicle                      | ❌ `UnauthorizedException`                |
| `app-backend` GraphQL                     | ❌ `Could not validate the accessToken`     | ✅ authenticates                          |
| C3 `invocation.InvocationService`         | ❌ not on allowlist                         | ✅ `outcome = accepted`                   |
| C3 `ota_mobcache.*`                       | ✅ accepted                                 | ✅ accepted (identical results)           |
| PCCS chronos reads & writes               | ✅                                          | not tested                                |
| Issues `refresh_token`                    | ✅                                          | ✅ (42 chars, refresh grant verified)     |
| Access-token lifetime                     | 1799 s                                      | 1799 s                                    |

**Scope.** Both clients accept
`openid profile email customer:attributes customer:attributes:write`. Adding `:write` to the
web client does not disturb discovery (token grows 1070 → 1105 chars). The write scope is
required for the OTA scheduler; it is _not_ sufficient for invocation — that needs the
allowlisted client.

### Consequence for implementations

You must run the OIDC flow **twice** and hold both tokens:

1. Web client → GraphQL reads, C3 reads, PCCS reads/writes, OTA writes.
2. App client → `invocation.InvocationService` writes only.

Practical notes, all learned the hard way:

- The second authorization reuses the PingFederate SSO cookie from the first, so it needs no
  second credential prompt — **provided both flows share one `URLSession`**.
- The redirect delegate must recognise **both** callbacks. The app client's is a custom scheme
  `URLSession` cannot load; if it isn't intercepted, the redirect is followed into a failure
  and the authorization code is lost silently. This is the failure mode that makes the app
  appear to work while quietly falling back to the web token.
- Both clients issue refresh tokens, so credentials are needed exactly **once**. Store the
  command refresh token separately (Hisingen: Keychain account `polestar-command-refresh-token`)
  and revoke both on sign-out.
- Session restore from a refresh token alone cannot bootstrap the command client if its refresh
  token was never stored — there is no IdP cookie and no password. That is why Hisingen reports
  _"Polestar mobile credentials required for remote controls"_ rather than failing obscurely.

---

## Service map

### C3 — `cepmobtoken.eu.prod.c3.volvocars.com:443`

| Service                                                                   | Methods used                                                                                             | Auth         |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------ |
| `services.vehiclestates.battery.BatteryService`                           | `GetLatestBattery`                                                                                       | web          |
| `services.vehiclestates.availability.AvailabilityService`                 | `GetLatestAvailability`                                                                                  | web          |
| `services.vehiclestates.exterior.ExteriorService`                         | `GetLatestExterior`                                                                                      | web          |
| `services.vehiclestates.health.HealthService`                             | `GetHealth`                                                                                              | web          |
| `services.vehiclestates.odometer.OdometerService`                         | `GetOdometer`                                                                                            | web          |
| `services.vehiclestates.dashboard.DashboardService`                       | `GetLatestDashboard`                                                                                     | web          |
| `services.vehiclestates.parkingclimatization.ParkingClimatizationService` | `GetLatestParkingClimatization`                                                                          | web          |
| `services.vehiclestates.precleaning.PreCleaningService`                   | `GetPreCleaning`                                                                                         | web          |
| `dtlinternet.DtlInternetService`                                          | `GetLastKnownLocation`                                                                                   | web          |
| `weather.WeatherService`                                                  | `GetWeatherReport`                                                                                       | web          |
| `ota_mobcache.OtaDiscoveryService`                                        | `GetSoftwareInfo`                                                                                        | web or app   |
| `ota_mobcache.SchedulerService`                                           | `GetSchedule`, `Schedule`, `InstallNow`, `CancelSchedule`                                                | web or app   |
| **`invocation.InvocationService`**                                        | `Lock`, `Unlock`, `ClimatizationStart`, `ClimatizationStop`, `WindowControl`, `HonkFlash`, `PreCleaning` | **app only** |

### PCCS — `api.pccs-prod.plstr.io:443`

**Every service here takes a `pccs.` package prefix**, and `invocation` additionally gains a
`.v1`. Using the C3 spelling returns `UNIMPLEMENTED` — measured for all seven:

| Logical service  | ❌ C3 spelling (absent on PCCS)                  | ✅ PCCS spelling                                      |
| ---------------- | ------------------------------------------------ | ----------------------------------------------------- |
| Target SOC       | `chronos.services.v1.TargetSocService`           | `pccs.chronos.services.v1.TargetSocService`           |
| Amp limit        | `chronos.services.v1.AmpLimitService`            | `pccs.chronos.services.v1.AmpLimitService`            |
| Charge now       | `chronos.services.v1.ChargeNowService`           | `pccs.chronos.services.v1.ChargeNowService`           |
| Charge timer     | `chronos.services.v2.GlobalChargeTimerService`   | `pccs.chronos.services.v2.GlobalChargeTimerService`   |
| Climate timer    | `chronos.services.v1.ParkingClimateTimerService` | `pccs.chronos.services.v1.ParkingClimateTimerService` |
| Charge locations | `chronos.services.v1.ChargeLocationService`      | `pccs.chronos.services.v1.ChargeLocationService`      |
| Invocation       | `invocation.InvocationService`                   | `pccs.invocation.v1.InvocationService`                |

**PCCS reads work; chronos writes work; invocation writes do not.**
`pccs.invocation.v1.InvocationService/Lock` answers `Unauthenticated: Access denied` with _both_
clients — so invocation must use C3 (with the command token). Chronos _writes_, in contrast, are
accepted on PCCS with the **web** token: `SetTargetSoc(90) → completed`, verified live with the
charge target read back unchanged.

---

## Remote Controls Master Matrix

| Feature | Host | Service | Method | Token | Request Schema | Response Schema | Live Verified | Model Support |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Lock** | C3 | `invocation.InvocationService` | `Lock` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 0}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ `outcome=completed` | Polestar 2, 3, 4 |
| **Unlock (All)** | C3 | `invocation.InvocationService` | `Unlock` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 0}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Unlock (Trunk)** | C3 | `invocation.InvocationService` | `Unlock` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Window Vent/Open** | C3 | `invocation.InvocationService` | `WindowControl` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Window Close** | C3 | `invocation.InvocationService` | `WindowControl` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 2}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Start Climate (Auto)** | C3 | `invocation.InvocationService` | `ClimatizationStart` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Start Climate (Custom)** | C3 | `invocation.InvocationService` | `ClimatizationStart` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1, 3: temp_f32, 4: seat_r, 5: seat_l, 6: rseat_r, 7: rseat_l, 8: steer}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 3, 4 (P2 is auto) |
| **Stop Climate** | C3 | `invocation.InvocationService` | `ClimatizationStop` | App (`lp8dyrd_10`) | `{1: {1: vin}}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Honk + Flash** | C3 | `invocation.InvocationService` | `HonkFlash` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 0}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Honk Horn** | C3 | `invocation.InvocationService` | `HonkFlash` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Flash Lights** | C3 | `invocation.InvocationService` | `HonkFlash` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 2}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3, 4 |
| **Start Pre-Cleaning** | C3 | `invocation.InvocationService` | `PreCleaning` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 1}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3 |
| **Stop Pre-Cleaning** | C3 | `invocation.InvocationService` | `PreCleaning` | App (`lp8dyrd_10`) | `{1: {1: vin}, 2: 0}` | `{1: {1: id, 2: vin, 3: status, 4: msg, 5: ts}}` | ✅ Verified schema | Polestar 2, 3 |

### Invocation Lifecycle State Machine

```mermaid
stateDiagram-v2
    [*] --> Sending
    Sending --> Accepted : status = 1 (Queued in cloud)
    Accepted --> Delivered : status = 4 (Acknowledged by TCU)
    Delivered --> Completed : status = 6 (ECU Action Finished)
    Sending --> Rejected : status = 9 (Privacy)
    Sending --> Rejected : status = 10 (Invalid Vehicle Mode)
    Sending --> Rejected : status = 12 (Conflicting Command)
    Completed --> [*]
    Rejected --> [*]
```

---

## Chronos / PCCS Writes Master Matrix

| Command | Host | Service | Method | Token | Request Protobuf | Response Protobuf | Live Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Set Target SOC** | PCCS | `pccs.chronos.services.v1.TargetSOCService` | `SetTargetSoc` | Web (`l3oopkc_10`) | `{1: envelope, 2: target (50..100), 3: 1}` | `{3: status (1=ACCEPTED)}` | ✅ `completed` |
| **Set Amp Limit** | PCCS | `pccs.chronos.services.v1.AmpLimitService` | `SetAmpLimit` | Web (`l3oopkc_10`) | `{1: envelope, 2: amps (6..32)}` | `{3: status (1=ACCEPTED)}` | ✅ `completed` |
| **Start Charge Override** | PCCS | `pccs.chronos.services.v1.ChargeNowService` | `StartOverrideChargeTimer` | Web (`l3oopkc_10`) | `{1: envelope}` | `{1: status (2=COMPLETED)}` | ✅ `accepted` |
| **Stop Charge Override** | PCCS | `pccs.chronos.services.v1.ChargeNowService` | `StopOverrideChargeTimer` | Web (`l3oopkc_10`) | `{1: envelope}` | `{1: status (2=COMPLETED)}` | ✅ `accepted` |
| **Set Global Charge Timer** | PCCS | `pccs.chronos.services.v2.ChargeTimerService` | `SetGlobalChargeTimer` | Web (`l3oopkc_10`) | `{1: envelope, 2: {1: start, 2: stop, 3: active}, 3: 0}` | `{2: status (1=ACCEPTED)}` | ✅ `accepted` |
| **Set Climate Timer** | PCCS | `pccs.chronos.services.v1.ParkingClimateTimerService` | `SetTimer` | Web (`l3oopkc_10`) | `{1: envelope, 2: {1: id, 2: idx, 3: time, 4: active, 5: hasWeek, 6: [days]}}` | `{2: status}` | ✅ `accepted` |
| **Delete Climate Timer** | PCCS | `pccs.chronos.services.v1.ParkingClimateTimerService` | `DeleteTimer` | Web (`l3oopkc_10`) | `{1: envelope, 2: id_str}` | `{2: status}` | ✅ `accepted` |

---

## OTA / Software Architecture & Rollout Control Plane

### Why `AVAILABLE (15)` Cannot Be Forced Into `DOWNLOAD_READY (1)` By Any Client API

```mermaid
sequenceDiagram
    participant Cloud as Polestar OTA Campaign Control Plane (VDMS/CNEP)
    participant Mob as Mobile App / Hisingen (User Client)
    participant TCU as Vehicle Telematics Unit (TCU/IHU)
    participant CDN as Vehicle Firmware CDN (Signed Packages)

    Cloud->>Cloud: Campaign created & staged for rollout
    Cloud->>Cloud: VIN assigned to rollout wave / cohort
    Cloud->>Mob: OtaDiscoveryService/GetSoftwareInfo (state = 15 AVAILABLE)
    Note over Mob: User sees update announced & release notes.<br/>InstallNow / Schedule return grpc-status 3 (Not ready).
    TCU->>Cloud: Periodic TCU check-in via mTLS & vehicle certificate
    alt Local Preconditions Met (12V > 75%, HV > 40%, Cellular OK, Parked)
        Cloud->>TCU: Rollout Gate Open -> Issues Download Ticket & Signed CDN URLs
        TCU->>Cloud: Telemetry: state = 2 DOWNLOAD_STARTED
        TCU->>CDN: Streams signed binary payload chunks
        TCU->>TCU: Verifies cryptographic signatures & stages to A/B partition
        TCU->>Cloud: Telemetry: state = 3 DOWNLOAD_COMPLETED
        Note over Cloud,Mob: OtaDiscoveryService reports state = 3 DOWNLOAD_COMPLETED
        Mob->>Cloud: SchedulerService/InstallNow or Schedule
        Cloud->>TCU: Installation trigger dispatched
        TCU->>TCU: Executes OS partition flip & flashing
    else Preconditions Not Met
        Note over TCU: TCU defers download until vehicle is parked with adequate battery.
    end
```

### Complete Sequence Explanation

1. **Rollout Stage & Announcement:** Polestar publishes a firmware release (e.g. `5.0.10`) and assigns VIN cohorts. The cloud reports `state = 15` (`AVAILABLE`).
2. **Autonomous Vehicle Download:** The vehicle's onboard telematics unit (TCU / VCM) evaluates power and network preconditions and contacts the vehicle firmware gateway using embedded hardware certificates (mTLS).
3. **No User Bypass Exists:** Probing proved that no RPC exists to trigger download from user accounts (82 method sweep yielded 0 methods, WakeUp with `OTA_DOWNLOAD` is not deployed, GraphQL has 0 software mutations). The rollout gate is strictly backend and vehicle-managed to prevent cellular network congestion and ensure vehicle battery safety.
4. **Installation Enabling:** Only after the TCU finishes downloading and cryptographically verifying the payload (`DOWNLOAD_COMPLETED`, state 3) or when scheduled/deferred (`10`, `12`) does `SchedulerService/InstallNow` and `Schedule` become callable.

---

## Newly Discovered Capabilities Catalog

### 1. Newly Discovered & Useful (Implemented in Hisingen)
- **High-Precision Battery Diagnostics:** Real-time charging power in Watts, voltage in Volts, current in Amperes, charging type (AC/DC/Wireless), time-to-target-SOC, time-to-minimum-SOC, historical & since-charge average consumption, total energy consumed (Wh), and charger power state.
- **Comprehensive Vehicle Health & Lighting:** 4 tyre pressures in direct kPa with individual warning levels (`OK`, `LOW`, `VERY_LOW`), 22 individual exterior bulb failure indicators, 12V low-voltage auxiliary battery warning, service countdown (days and km).
- **Interactive Closure Security Matrix:** Central lock status plus granular open/closed/ajar state for all 4 doors, 4 frameless power windows, front hood, powered tailgate, motorized charge port flap, panoramic sunroof, and perimeter alarm status.
- **Precision Trip Computer:** Total vehicle odometer, manual trip meter, and automatic trip meter.
- **CleanZone Cabin Environment & AQI:** CleanZone air purifier state, cabin PM2.5 (`µg/m³`), outdoor PM2.5, PM10, AQI index, and CleanZone filter remaining lifespan percentage.
- **Location & Dynamics:** High-precision GPS latitude, longitude, altitude, heading, speed, accuracy, parking brake engagement, and transmission gear selector (`P`, `R`, `N`, `D`).
- **Connectivity & Sleep/Wake Diagnostics:** Cloud connectivity state, network generation (`LTE`, `5G`), signal strength bars, and wake reason (`Scheduled Climate`, `Charging Active`, `Telemetry Poll`).
- **Vehicle Content Specs & Studio Renders:** Factory spec (paint color, upholstery, rim size, packages) from VDMS GraphQL and 6 studio camera angles (0–5) from the public render CDN.

### 2. Newly Discovered but Low-Value
- **`getPreferences` (mystar-v2 root query):** real, and unused by Hisingen — but it is content/localization, not vehicle settings. Requires `languageCode` + `countryCode` arguments, returns type `PreferenceResponse`, and its `preferences` sub-resolver currently answers **`Bad Gateway`**. No software or consent field hangs off it.
- `qb_code` in `CarSoftwareInfo`: Internal build identification code (observed empty or redundant).
- Raw GPS Altitude/Accuracy without topographic mapping.

### 3. Interesting but Unverified
- `field 5` in `CarSoftwareInfo` (`5400`): Plausibly estimated installation duration in seconds (90 minutes) — unconfirmed.
- `field 11` in `CarSoftwareInfo` (`"SYSTEM"`): Originator / author of the software schedule.
- `pccs.invocation.v1.InvocationService`: Mirror of C3 invocation on PCCS, currently returns `Access denied` for all known client tokens.

### 4. Dead Ends (Proven Absent)
- **WakeUp with OTA_DOWNLOAD Reason:** 35 probes across C3/PCCS returned `Method not found`.
- **Direct Download RPCs on C3:** 82 candidate method names across `OtaDiscoveryService` and `SchedulerService` returned `Method not found`.
- **GraphQL software types (app-backend):** 40 type names probed via the `__type(name:)` oracle — `Software*`, `CarSoftware*`, `VehicleSoftware*`, `Ota*`, `Update*`, `Firmware*`, `Download*`, `Install*`, `Upgrade*`, `Version*`, `Campaign`, `Consent*` — **all return null**, with real/fake controls validating the oracle in the same pass. This is the strongest negative available: it enumerates the type namespace directly instead of guessing field names.
- **GraphQL software fields (mystar-v2):** 54 names probed at three levels, each with a passing control — root `Query` (control `getConsumerCarsV2`), `VehicleInformation` (control `.vin`), and `carTelematicsV2`. Zero software/OTA fields at any level.
- **Blind C3 Package Guessing:** C3 returns `Method not found` for any child of a routed package, which is a package router artifact rather than proof of service existence.

---

## Error semantics

Non-zero `grpc-status` values observed on writes, and what they actually mean here:

| Status | Meaning            | Seen as                                                                                   |
| ------ | ------------------ | ----------------------------------------------------------------------------------------- |
| 3      | `INVALID_ARGUMENT` | Business rejection with a useful `grpc-message` — bad `relative_time`, software not ready |
| 5      | `NOT_FOUND`        | Target entity or update not found on vehicle service                                      |
| 7      | `PERMISSION_DENIED`| Account lacks entitlement for this specific operation                                     |
| 9      | `FAILED_PRECONDITION` | Vehicle mode or battery condition prevents command                                     |
| 12     | `UNIMPLEMENTED`    | Wrong package path, or method genuinely absent (`Method not found: <svc>/<m>`)            |
| 14     | `UNAVAILABLE`      | Transient network or server unavailability                                                |
| 16     | `UNAUTHENTICATED`  | Client not on the allowlist, or PCCS refusing a write                                     |

`grpc-message` is percent-encoded and is where all the useful detail lives — decode it and
surface it. Collapsing these into one generic "unexpected response" throws away the only
information that explains the failure.

---

## Transport quirks

1. **`GetSoftwareInfo` and `GetSchedule` are server-streaming.** The server writes one frame and
   holds the HTTP/2 stream open. Read incrementally (`URLSession.bytes(for:)`) and stop at the first complete frame.
2. **`URLSession` exposes no HTTP/2 trailers.** An _immediate_ rejection arrives Trailers-Only (`HTTP 200`, `grpc-status` in headers); a _late_ failure arrives in trailers and surfaces as 200 with no message frame.
3. **User-Agent matters.** C3 rejects non-Java gRPC user agents; send `grpc-java-okhttp/1.68.2`.
4. **`vin` is a header**, not only a request field, on every C3/PCCS call.

---

## What the probes cannot tell you

- **Service existence is not measurable on C3 by probing `/__probe__`** — package routing returns `Method not found` for any sub-path.
- **Method existence _is_ measurable on C3** because C3 resolves method names before checking authorization.
- **On PCCS authorization is checked first**, so invalid credentials return `Access denied` before method lookup.
- **GraphQL name existence is measurable** on `mystar-v2` via `FieldUndefined` and on `app-backend` via the "Did you mean...?" suggestion engine — but the suggestion engine is **weak evidence**: graphql-java computes suggestions by *edit distance*, so a null result only rules out names close to the string you typed. `getVehicleSoftwareStatus` would never be suggested from the stem `softwar`.
- **The strong GraphQL oracle is `__type(name:)`**, available on `app-backend` only: a real type resolves to `{"__type":{"name":…}}`, an invented one to `{"__type":null}`. `__schema.types` and `__Type.fields` are filtered to `[]` on both backends, but type *lookup* survives the filter. mystar-v2 does not support it — even its own `VehicleInformation` fails to resolve there.
- **Always run known-real and known-fake controls in the same pass.** Every oracle in this document was validated that way, and the two that were not initially (C3 service enumeration, and an early subfield detector) both produced false positives.

---

## Reproducing any of this

```bash
export HISINGEN_TEST_EMAIL=… HISINGEN_TEST_PASSWORD=… HISINGEN_TEST_VIN=…
sh Scripts/test.sh --filter <TestName>
```

| Test | Establishes |
| :--- | :--- |
| `testCaptureLiveSoftwareAndOtaSchedule` | Current OTA state |
| `testDiagnoseLiveOtaExchange` | Raw C3 OTA exchange |
| `testCommandClientTokenCanInvoke` | App client command issuance |
| `testConfirmPccsServicePathPrefixes` | PCCS `pccs.` prefix rule |
| `testExhaustiveOtaMethodSweep` | Confirms only five OTA methods exist |
| `testHuntForWakeUpWithOtaDownloadReason` | Confirms WakeUp is not deployed |

---

## Public render CDN API key (Gateway 3)

`GetCarImages` against `pc-api.polestar.com/eu-north-1/mystar-public/` is authenticated with a
static AppSync-style key rather than a bearer token: `x-api-key: da2-js63uvc7c5hwpdudt657d5lyou`.
Baked into the official client, not user-specific — but still a live credential, so it stays out
of the published docs (see [polestar.md](polestar.md#vehicle-images) for the request shape).

## Full OAuth scope list observed on Polestar ID

Everything the IdP recognises, as opposed to the handful Hisingen actually requests
(`openid profile email customer:attributes customer:attributes:write` — see
[authentication.md](authentication.md#polestar-scraped-oidc-login)). Recorded here because
enumerating it required probing, not because Hisingen uses all of it:

- **Identity:** `openid`, `profile`, `email`, `address`, `phone`, `customer:attributes`, `customer:attributes:write`
- **Telematics:** `energy:battery_charge_level`, `energy:electric_range`, `energy:charging_connection_status`, `energy:estimated_charging_time`, `energy:recharge_status`, `conve:battery_charge_level`, `conve:recharge_status`
- **Closures & locks:** `exve:doors_status`, `conve:doors_status`, `vehicle:doors_status`, `exve:windows_status`, `conve:windows_status`, `exve:lock_status`, `conve:lock_status`, `vehicle:lock`, `vehicle:unlock`
- **Health & maintenance:** `exve:odometer_status`, `conve:odometer_status`, `vehicle:odometer_status`, `conve:trip_statistics`, `vehicle:trips`, `vehicle:trip_status`, `conve:tyre_status`, `exve:tyre_status`, `vehicle:tyre_status`, `conve:warnings`, `exve:warnings`, `vehicle:maintenance_status`, `vehicle:service_status`, `vehicle:bulb_status`, `vehicle:brake_status`, `vehicle:oil_status`, `vehicle:coolant_status`, `vehicle:washer_status`
- **Climate & HVAC:** `vehicle:climatization`, `conve:climatization_start_stop`, `vehicle:climatization_calendar`, `vehicle:climatization_calendar_status`
- **Remote commands:** `conve:honk_flash`, `conve:command_honk_flash`, `vehicle:honk_blink`, `vehicle:location`, `conve:navigation`

## Live telemetry capture (full sample)

One full snapshot from the reference vehicle (VIN `YSM…228`), for anyone reconstructing the
merged shape of `carTelematicsV2` + C3 gRPC without wanting to re-probe from scratch:

```json
{
  "vehicle": { "vin": "YSM…228", "model": "Polestar 2", "modelYear": "2023", "powertrain": "BEV", "market": "SE" },
  "battery": { "batteryPercentage": 75.0, "rangeKm": 270, "chargingState": "IDLE", "chargerConnection": "DISCONNECTED", "reportedBatteryCapacityKwh": 78.0 },
  "odometerAndHealth": {
    "odometerKm": 121376, "tripMeterManualKm": 1287.4, "tripMeterAutomaticKm": 1.9,
    "daysToService": 347, "distanceToServiceKm": 5726, "serviceWarning": false, "fluidWarnings": [],
    "tyres": [
      { "position": "frontLeft", "status": "OK" }, { "position": "frontRight", "status": "OK" },
      { "position": "rearLeft", "status": "OK" }, { "position": "rearRight", "status": "OK" }
    ]
  },
  "closures": {
    "centralLock": "LOCKED", "frontLeftDoor": "CLOSED", "frontRightDoor": "CLOSED",
    "rearLeftDoor": "CLOSED", "rearRightDoor": "CLOSED", "frontLeftWindow": "CLOSED",
    "frontRightWindow": "CLOSED", "rearLeftWindow": "CLOSED", "rearRightWindow": "CLOSED",
    "hood": "CLOSED", "tailgate": "CLOSED", "chargeLid": "CLOSED"
  },
  "climate": { "activity": "IDLE", "driverSeatHeating": 0, "passengerSeatHeating": 0, "steeringWheelHeating": 0, "cleanZone": "OFF" },
  "software": { "availableVersion": "5.0.10", "state": "AVAILABLE" }
}
```

## Feature ideas surfaced during probing (not yet built)

Not findings — a backlog of what the mapped surface would support, for future reference:

- Window-sticker/factory-passport export (paint code, trim, `structureWeek`/PNO34 build metadata).
- Interactive 2D closure/security schematic driven by the exterior snapshot.
- CleanZone cabin AQI dashboard with a one-tap pre-clean action.
- 2D cabin thermal matrix (seat/steering heat levels, LHD/RHD aware).
- Charging curve + Target SoC / amp-limit sliders, cost estimate from trip-meter deltas.
- OTA changelog inspector with a countdown to scheduled installs.
| `testMapNewlyReachableCapabilities` | Chronos write & readback verification |
