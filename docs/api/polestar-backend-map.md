# Polestar backend — complete map

Everything here was established by probing the live backend against a real vehicle
(Polestar 2, MY2023, VIN `YSM…228`) in August 2026, not inferred from documentation.
Polestar publishes no third-party API; all of this is reverse-engineered and can change
without notice.

Where a claim is **measured**, the observed response is quoted. Where it is **inferred**,
it says so. One earlier probe in this effort produced a false positive and is documented
in [What the probes cannot tell you](#what-the-probes-cannot-tell-you) so the same mistake
isn't repeated. Every raw response quoted here is collected in
[polestar-probe-transcripts.md](polestar-probe-transcripts.md).

- [Hosts](#hosts)
- [OAuth clients — the two-client rule](#oauth-clients--the-two-client-rule)
- [Service map](#service-map)
- [OTA / software](#ota--software)
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
| `api.pccs-prod.plstr.io:443`                             | **PCCS** gRPC                           | Fixed; reads only in practice           |

C3 discovery returns exactly one endpoint — `c3` and `c3Lbs` both point at the same host:

```json
{"c3":{"url":"https://cepmobtoken.eu.prod.c3.volvocars.com","grpcHost":"cepmobtoken.eu.prod.c3.volvocars.com","grpcPort":443,"grpcKeepAliveTime":45},
 "c3Lbs":{ …identical… }}
```

There is no second environment to fall back to.

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
| PCCS chronos reads                        | ✅                                          | not tested                                |
| Issues `refresh_token`                    | ✅                                          | ✅ (42 chars, refresh grant verified)     |
| Access-token lifetime                     | 1799 s                                      | 1799 s                                    |

**Scope.** Both clients accept
`openid profile email customer:attributes customer:attributes:write`. Adding `:write` to the
web client does not disturb discovery (token grows 1070 → 1105 chars). The write scope is
required for the OTA scheduler; it is _not_ sufficient for invocation — that needs the
allowlisted client.

### Consequence for implementations

You must run the OIDC flow **twice** and hold both tokens:

1. Web client → GraphQL reads, C3/PCCS reads, OTA writes.
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
charge target read back unchanged. So the token split is per-family:

| Command family                                                                | Host | Token                  |
| ----------------------------------------------------------------------------- | ---- | ---------------------- |
| `invocation.*` (lock, climate, windows, honk, pre-clean)                      | C3   | command (`lp8dyrd_10`) |
| `chronos.*` writes (target SOC, amp limit, charge-now, charge/climate timers) | PCCS | web (`l3oopkc_10`)     |
| `ota_mobcache.*`                                                              | C3   | either                 |

### GraphQL

`mystar-v2` root is `Query`; introspection is stripped (`__Schema.types`, `__Type.fields` are
`FieldUndefined`; only `__typename` resolves). A mutation root exists. Probed by name: no
`getSoftwareInfo`, `getSoftwareStatus`, `getOtaStatus`, `startSoftwareDownload`,
`downloadSoftware`, `installSoftware`, `acceptSoftwareUpdate` — all `FieldUndefined`, against a
`getConsumerCarsV2` control that succeeds.

`app-backend` root is `PolestarGraphQlQuery`, mutation root `PolestarGraphQlMutation`.
Introspection is _neutered rather than blocked_ — it answers `{"__schema":{"queryType":{"fields":[]}}}`
and `mutationType: null`, and `__type(…){fields{name}}` likewise returns `[]`. But **the
validator's suggestion engine still sees the real names**, which makes it the best oracle
available on this backend:

```
car   → Did you mean 'cars'?                    (type CarsQueries)
vdm   → Did you mean 'vdms'?                    (type VdmsGraphQlQueries)
getVehiclesInformatio → Did you mean 'getVehiclesInformation'?
```

Running every software stem through that oracle at the root and inside both `vdms` and `cars`
(`softwar`, `software`, `getSoftware`, `ota`, `getOta`, `updat`, `update`, `getUpdate`,
`downloa`, `download`, `firmwar`, `instal`, `upgrad`, `versio`) produced **no suggestions**.

Required app-backend headers:

```
X-PolestarId-Authorization: Bearer <app-client access_token>
X-Polestar-Force-Update-Version: 5.5.0      # omit → HTTP 428
X-Polestar-Locale: SE
User-Agent: PolestarApp/5.5.0b1102 Android/14
```

Without the version header the host answers **HTTP 428** regardless of token. The token must be
`Bearer`-prefixed; a raw token gives _"An accessToken was not provided"_. `id_token` works as
well as `access_token`.

---

## OTA / software

### `GetSoftwareInfo`

Request `{1 vin, 2 locale}` — locale is mandatory (`Language can not be empty`).
Response `{1 CarSoftwareInfo}`:

| Field | Name              | Notes                                                                                    |
| ----- | ----------------- | ---------------------------------------------------------------------------------------- |
| 1     | `software_id`     | UUID; every OTA write is addressed to it                                                 |
| 2     | `description`     | `{1 name, 2 short_desc, 3 long_desc}`; long_desc is HTML-ish `<textblock>`               |
| 3     | `qb_code`         | observed empty                                                                           |
| 4     | `state`           | see enum below                                                                           |
| 5     | _(unidentified)_  | observed `{1: 5400}`; plausibly install duration in seconds (90 min) — **not confirmed** |
| 6     | `new_sw_version`  | meaning depends on `state`, see below                                                    |
| 8     | `schedule_info`   | `{2 scheduled_at}`; absent when nothing is scheduled                                     |
| 10    | `state_timestamp` |                                                                                          |
| 11    | _(unidentified)_  | observed `"SYSTEM"`; plausibly `set_by`/originator — **not confirmed**                   |

### `SoftwareState`

| Value  | Name                                                                   | Installable?               |
| ------ | ---------------------------------------------------------------------- | -------------------------- |
| 0      | `UNKNOWN`                                                              | no — settled               |
| 1      | `DOWNLOAD_READY`                                                       | no                         |
| 2      | `DOWNLOAD_STARTED`                                                     | no                         |
| 3      | `DOWNLOAD_COMPLETED`                                                   | **yes**                    |
| 4      | `DOWNLOAD_FAILED`                                                      | no                         |
| 5      | `INSTALLATION_INITIATED`                                               | no                         |
| 6      | `INSTALLATION_STARTED`                                                 | no                         |
| 7      | `INSTALLATION_ABORTED`                                                 | no                         |
| 8      | `INSTALLATION_FAILED`                                                  | no                         |
| 9      | `INSTALLATION_COMPLETED`                                               | no — settled               |
| 10     | `INSTALLATION_DEFERRED`                                                | **yes**                    |
| 11     | `INSTALLATION_FAILED_CRITICAL`                                         | no                         |
| 12     | `INSTALLATION_SCHEDULED`                                               | **yes** (also cancellable) |
| 13     | `INSTALLATION_SCHEDULE_TRIGGERED`                                      | no                         |
| 14     | `INSTALLATION_UNKNOWN`                                                 | no — settled               |
| **15** | **not in the published enum** — observed meaning _available/announced_ | **no**                     |

**`new_sw_version` is not "the installed version".** While an update is pending it names the
_target_; the running version is not reported at all. Only in the settled states (0, 9, 14) does
it describe what is on the car. Populate exactly one of installed/available and carry the last
settled reading forward across refreshes, or the installed version vanishes for the whole
rollout.

**"Available" ≠ installable.** With `state = 15`, both `Schedule` and `InstallNow` answer:

```
grpc-status 3: The software with software id <uuid> is not ready to be scheduled!
```

Identical with the web token and the allowlisted app token — so this is a business rule about
the software's state, not an authorization decision.

### Scheduler writes

| Method           | Request                                   | Notes                                                    |
| ---------------- | ----------------------------------------- | -------------------------------------------------------- |
| `Schedule`       | `{1 vin, 2 relative_time, 3 software_id}` | **`relative_time` is MINUTES, bounded 2…10080 (7 days)** |
| `InstallNow`     | `{1 vin, 2 software_id}`                  |                                                          |
| `CancelSchedule` | `{1 vin, 2 software_id}`                  |                                                          |

All three answer `{1 Scheduler}` = `{1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by}`,
`status` ∈ `0 UNKNOWN, 1 IDLE, 2 SCHEDULED, 3 INSTALL`.

The minutes unit is measured, not assumed — sending seconds yields:

```
grpc-status 3: relativeTime should be between 2 to 10080!
```

`GetSchedule` with nothing scheduled returns `{1: {1: 1, 2: -2}}` — status `IDLE`,
`relative_time` = −2.

## Error semantics

Non-zero `grpc-status` values observed on writes, and what they actually mean here:

| Status | Meaning            | Seen as                                                                                   |
| ------ | ------------------ | ----------------------------------------------------------------------------------------- |
| 3      | `INVALID_ARGUMENT` | Business rejection with a useful `grpc-message` — bad `relative_time`, software not ready |
| 12     | `UNIMPLEMENTED`    | Wrong package path, or method genuinely absent (`Method not found: <svc>/<m>`)            |
| 14     | `UNAVAILABLE`      | Transient                                                                                 |
| 16     | `UNAUTHENTICATED`  | Client not on the allowlist, or PCCS refusing a write                                     |

`grpc-message` is percent-encoded and is where all the useful detail lives — decode it and
surface it. Collapsing these into one generic "unexpected response" throws away the only
information that explains the failure.

---

## Transport quirks

These are the ones that cost real debugging time:

1. **`GetSoftwareInfo` and `GetSchedule` are server-streaming.** The server writes one frame and
   holds the HTTP/2 stream open. `URLSession.data(for:)` waits for `END_STREAM` and simply times
   out after 60 s. Read incrementally (`URLSession.bytes(for:)`) and stop at the first complete
   frame.
2. **`URLSession` exposes no HTTP/2 trailers.** gRPC delivers the status of an already-started
   response there. An _immediate_ rejection arrives Trailers-Only — `HTTP 200`,
   `Content-Length: 0`, and `grpc-status`/`grpc-message` in the **initial headers**, which are
   readable. A _late_ failure is invisible: it surfaces as 200 with no message frame. Treat
   "200 with no frame" as a refusal, not as a malformed response.
3. **User-Agent matters.** C3 rejects non-Java gRPC user agents; send
   `grpc-java-okhttp/1.68.2`.
4. **`vin` is a header**, not only a request field, on every C3/PCCS call.

---

## What the probes cannot tell you

Recording this because one probe in this effort produced a confident false positive.

**Service existence is not measurable on C3.** Probing `/<service>/__probe__` and treating
`Method not found` as "service exists" is invalid — C3 answers that for any path under a routed
package. `services.vehiclestates.ota.OtaService`, an invented name, scored the same as a real
one. The probe detects **package routing** (`ota_mobcache.*` and `services.vehiclestates.*` are
routed; `ota.*` and `software.*` are not), nothing finer.

**Method existence _is_ measurable**, on C3 only: a real method answers with a business error or
a payload, an absent one answers `Method not found: <service>/<method>`. This holds because C3
resolves the method before checking authorization.

**On PCCS neither is measurable** — authorization is checked first, so everything answers
`Access denied` regardless of whether it exists.

**GraphQL name existence is measurable on both hosts** via `FieldUndefined`, and on app-backend
the "Did you mean…?" suggestions additionally reveal real names you did not guess. Always run a
known-good control (`getConsumerCarsV2`, `vdms`) in the same pass to prove the oracle is live.

---

## Reproducing any of this

The live suite is gated on credentials and skipped by default; CI additionally runs
`--skip Live`.

```bash
export HISINGEN_TEST_EMAIL=…  HISINGEN_TEST_PASSWORD=…  HISINGEN_TEST_VIN=…   # VIN optional
sh Scripts/test.sh --filter <TestName>
```

| Test                                        | Establishes                                                                                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `testCaptureLiveSoftwareAndOtaSchedule`     | Current OTA state — the one to re-run while waiting for a rollout                                                                                       |
| `testDiagnoseLiveOtaExchange`               | Raw C3 OTA exchange; `HISINGEN_TEST_OTA_SCHEDULE=1` adds a reversible schedule/cancel round-trip, `HISINGEN_TEST_OTA_INSTALL=1` attempts a real install |
| `testDiagnoseOidcClientAndVehicleDiscovery` | Which OAuth client can read vehicles                                                                                                                    |
| `testCommandClientTokenCanInvoke`           | That the app client can issue commands                                                                                                                  |
| `testCommandClientRefreshTokenAvailability` | That one sign-in suffices                                                                                                                               |
| `testConfirmPccsServicePathPrefixes`        | The `pccs.` prefix rule, all seven services                                                                                                             |
| `testExhaustiveOtaMethodSweep`              | That only five OTA methods exist                                                                                                                        |
| `testHuntForWakeUpWithOtaDownloadReason`    | That `WakeUp`/`OTA_DOWNLOAD` is not deployed                                                                                                            |
| `testAppBackendWithAppClientToken`          | App-backend auth + schema probing                                                                                                                       |
| `testAppBackendSchemaIntrospection`         | Suggestion-oracle enumeration                                                                                                                           |

`testDiagnoseLiveOtaExchange` and `testCommandClientTokenCanInvoke` dispatch real commands to a
real vehicle. Everything else is read-only.
