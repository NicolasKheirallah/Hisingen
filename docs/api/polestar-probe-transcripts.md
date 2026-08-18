# Polestar backend — raw probe transcripts

The verbatim responses behind every claim in [polestar-backend-map.md](polestar-backend-map.md).
Captured live against a real Polestar 2 (MY2023, VIN `YSM…228`, market SE) in August 2026.
VINs and long tokens are redacted; nothing else is edited.

Each section names the test that produced it (`sh Scripts/test.sh --filter <name>`), so any of
this can be re-run.

- [1. OAuth client vs. vehicle discovery](#1-oauth-client-vs-vehicle-discovery)
- [2. Command-client token](#2-command-client-token)
- [3. Invocation — C3 vs PCCS](#3-invocation--c3-vs-pccs)
- [4. Invocation service/method probe](#4-invocation-servicemethod-probe)
- [5. OTA read — GetSoftwareInfo / GetSchedule](#5-ota-read--getsoftwareinfo--getschedule)
- [6. OTA writes — Schedule / InstallNow / CancelSchedule](#6-ota-writes--schedule--installnow--cancelschedule)
- [7. PCCS service path prefixes](#7-pccs-service-path-prefixes)
- [8. Exhaustive OTA method sweep](#8-exhaustive-ota-method-sweep)
- [9. WakeUp / OTA_DOWNLOAD hunt](#9-wakeup--ota_download-hunt)
- [10. Download-interface hunt](#10-download-interface-hunt)
- [11. mystar-v2 GraphQL name oracle](#11-mystar-v2-graphql-name-oracle)
- [12. app-backend auth + schema](#12-app-backend-auth--schema)
- [13. app-backend subfield oracle + wake-then-recheck](#13-app-backend-subfield-oracle--wake-then-recheck)
- [14. The one false positive](#14-the-one-false-positive)
- [15. Chronos writes verification — SetTargetSoc(90)](#15-chronos-writes-verification--settargetsoc90)

---

## 1. OAuth client vs. vehicle discovery

`testDiagnoseOidcClientAndVehicleDiscovery` — both clients authenticate; only the web client can
list vehicles.

```
════════ OIDC CLIENT: mobile app (lp8dyrd_10) ════════
  authorize page: HTTP 200
  login POST: HTTP 302
  token exchange: HTTP 200
  ✅ token acquired (1105 chars)
  • getConsumerCarsV2: HTTP 401 → {"errors":[{"errorType":"UnauthorizedException",
                                    "message":"You are not authorized to make this call."}]}
  • GetVDMSCars (app-backend): HTTP 428 →

════════ OIDC CLIENT: web (l3oopkc_10) ════════
  authorize page: HTTP 200
  login POST: HTTP 302
  token exchange: HTTP 200
  ✅ token acquired (1070 chars)
  • getConsumerCarsV2: HTTP 200 → {"data":{"getConsumerCarsV2":[
        {"vin":"YSM…228","modelName":"Polestar 2","modelYear":"2023"}]}}
  • GetVDMSCars (app-backend): HTTP 428 →
```

Adding `customer:attributes:write` to the web client grows its token 1070 → 1105 chars and does
not break discovery (`testDiagnoseOidcClientAndVehicleDiscovery`, second run).

---

## 2. Command-client token

`testCommandClientRefreshTokenAvailability` — `lp8dyrd_10` issues a working refresh token, so one
sign-in suffices forever.

```
🎫 COMMAND-CLIENT TOKEN RESPONSE
  access_token: <1105 chars>
  expires_in: 1799
  id_token: <1230 chars>
  refresh_token: <42 chars>
  token_type: Bearer
  → refresh_token issued: YES — one sign-in suffices
  → refresh grant: HTTP 200 ✅ works
```

---

## 3. Invocation — C3 vs PCCS

`testInvocationOnC3WithRealEnvelope` — with the **web** token, C3 leaks the allowlist and PCCS
denies. This is the transcript that revealed the allowlist.

```
🔁 INVOCATION: C3 vs PCCS, real envelope

── C3   invocation.InvocationService/Lock
  HTTP 200  grpc-status=16
  grpc-message: Client id l3oopkc_10 is not a required client id:
    [h4Yf0b, ahP7e4, polxplore, addpolestarcnhere, caraccessmonitorunner,
     polmonrunnereuprod, lp8dyrd_10, micwkvi_20, r7p9qtm_10, 9jahaga_10,
     vhujyni_10, mo2qy9h_10, nxpwptn_10, 3nyjn7a_10, d0v7mnk_10]

── PCCS pccs.invocation.v1.InvocationService/Lock
  HTTP 200  grpc-status=16
  grpc-message: Status(StatusCode="Unauthenticated", Detail="Access denied.")
```

`testCommandClientTokenCanInvoke` — same call with the **app** token: accepted.

```
🔑 COMMAND-CLIENT TOKEN (lp8dyrd_10) — Lock

── C3   invocation.InvocationService/Lock
  HTTP 200  grpc-status=none
  frame: 0a420a2461633265663162642d663266352d343461312d613033302d62363134636336393639
         6261121159534d…3818012888df85d28034
  ⭐️ ACCEPTED → outcome=accepted message=—

── PCCS pccs.invocation.v1.InvocationService/Lock
  HTTP 200  grpc-status=16
  grpc-message: Status(StatusCode="Unauthenticated", Detail="Access denied.")
```

The accepted frame decodes as `{1: {1: "ac2ef1bd-…" (command uuid), 2: "YSM…228" (vin),
3: 1 (ACCEPTED), 5: <timestamp>}}`.

`testLiveInvocationWritePathAndOtaReadiness` — end-to-end through `PolestarAPI` with the dual-token
wiring: `outcome=completed`.

```
🔐 INVOCATION WRITE PATH
  charge target read back: 90
  lock state before:       true
  ✅ Lock ACCEPTED → outcome=completed message=—
```

---

## 4. Invocation service/method probe

`testProbeInvocationServiceForSoftwareActions` — note the **three distinct** refusal messages,
which is what tells the hosts apart.

```
🧰 InvocationService PROBE

── C3   invocation.InvocationService
  Lock                     PRESENT (grpc-status 2)   ↳ Application error processing RPC
  SoftwareUpdate           absent                     ↳ Method not found: invocation.InvocationService/SoftwareUpdate
  SoftwareDownload         absent                     ↳ Method not found: …/SoftwareDownload
  OtaDownload  DownloadSoftware  StartSoftwareDownload  UpdateSoftware
  InstallSoftware  AcceptSoftwareUpdate  → all "Method not found"

── PCCS invocation.InvocationService          (unprefixed — wrong package)
  Lock … AcceptSoftwareUpdate → all "Service is unimplemented."

── PCCS pccs.invocation.v1.InvocationService  (correct package)
  Lock                     PRESENT (grpc-status 2)   ↳ Exception was thrown by handler.
  SoftwareUpdate …         absent                     ↳ Method is unimplemented.
```

Three refusal strings, three meanings:

| String | Host / cause |
| --- | --- |
| `Method not found: <svc>/<m>` | C3 — the method truly does not exist (usable oracle) |
| `Service is unimplemented.` | PCCS — wrong package name (`invocation.*` should be `pccs.invocation.v1.*`) |
| `Method is unimplemented.` | PCCS — correct service, method absent |
| `Exception was thrown by handler.` | PCCS — method **exists**, but our bare `{1:vin}` probe body was malformed |

So `pccs.invocation.v1.InvocationService` *does* resolve methods (contra a first impression that
PCCS checks auth before everything). Its `Lock` exists — but with a real envelope and a real token
it still answers `Access denied` (section 3). Invocation writes therefore go to C3.

---

## 5. OTA read — GetSoftwareInfo / GetSchedule

`testDiagnoseLiveOtaExchange`. `GetSoftwareInfo` returns one frame (server-streaming; see
[transport quirks](polestar-backend-map.md#transport-quirks)):

```
── GetSoftwareInfo
  HTTP 200   Server: vcc   Content-Type: application/grpc   grpc-encoding: identity
  frames: 1
  raw: 0ab1020a2461393532353433372d313864332d346561632d626630392d3166373566303834626565
       6112e7010a0f536f66747761726520757064617465120f536f667477617265207570646174651ac2
       013c74657874626c6f636b3e41206e657720736f667477617265207570646174652069732061766169
       6c61626c6520636f6e7461696e696e6720696d70726f7665642066756e6374696f6e616c6974792e20
       436c69636b2052656164206d6f726520746f20726561642061626f75742069742e20506c6561736520
       636f6e7461637420506f6c6573746172206966… 3c2f74657874626c6f636b3e1a00200f2a0308982a
       3206352e302e3130520608a2f99bd0065a0653595354454d
```

Decoded (`parseSoftware`):

| Field | Value |
| --- | --- |
| 1 `software_id` | `a9525437-18d3-4eac-bf09-1f75f084beea` |
| 2 `description.name` | `Software update` |
| 2 `description.long_desc` | `<textblock>A new software update is available containing improved functionality. Click Read more to read about it. Please contact Polestar if you have any questions about the update.</textblock>` |
| 4 `state` | **15** (available) |
| 5 (unidentified) | `5400` — plausibly install-duration seconds (90 min); **unconfirmed** |
| 6 `new_sw_version` | `5.0.10` |
| 10 `state_timestamp` | present |
| 11 (unidentified) | `SYSTEM` — plausibly originator; **unconfirmed** |

`GetSchedule` with nothing scheduled:

```
── GetSchedule
  frames: 1
  raw: 0a0d080110feffffffffffffffff01
```

Decodes as `{1: {1: 1 (IDLE), 2: -2 (relative_time)}}`.

---

## 6. OTA writes — Schedule / InstallNow / CancelSchedule

`testDiagnoseLiveOtaExchange` with `HISINGEN_TEST_OTA_SCHEDULE=1`. First attempt sent
`relative_time` in **seconds** (`720 * 60`):

```
── Schedule (+12h, seconds)
  HTTP 200  grpc-status: 3  Content-Length: 0
  grpc-message: relativeTime should be between 2 to 10080!
```

That is 10080 **minutes** = 7 days. Retried with `relative_time = 720` (minutes):

```
── Schedule (+720 min)
  HTTP 200  grpc-status: 3
  grpc-message: The software with software id a9525437-…-1f75f084beea is not ready to be scheduled!

── CancelSchedule
  grpc-message: The software with software id a9525437-…-1f75f084beea is not ready to be scheduled!

── GetSchedule (after)
  raw: 0a0d080110feffffffffffffffff01     (unchanged — still IDLE, nothing scheduled)
```

`InstallNow` (with `HISINGEN_TEST_OTA_INSTALL=1`) — **the real trigger, pulled twice**, once with
each client token. Identical:

```
── InstallNow (web token)
  HTTP 200  grpc-status: 3  Content-Length: 0
  grpc-message: The software with software id a9525437-…-1f75f084beea is not ready to be scheduled!

── InstallNow (command token, lp8dyrd_10)
  HTTP 200  grpc-status: 3
  grpc-message: The software with software id a9525437-…-1f75f084beea is not ready to be scheduled!
```

The two tokens producing byte-identical rejections is what proves the gate is the software's
**state**, not authorization.

---

## 7. PCCS service path prefixes

`testConfirmPccsServicePathPrefixes` — every service needs the `pccs.` prefix; the C3 spelling is
`UNIMPLEMENTED` on PCCS.

```
🧭 PCCS SERVICE PATH CONFIRMATION
  TargetSoc/GetTargetSoc                        current=absent   pccs-prefixed=PRESENT(2)
  AmpLimit/GetAmpLimit                          current=absent   pccs-prefixed=PRESENT(2)
  ChargeNow/StartOverrideChargeTimer            current=absent   pccs-prefixed=PRESENT(2)
  GlobalChargeTimer/GetGlobalChargeTimerStream  current=absent   pccs-prefixed=PRESENT(2)
  ParkingClimateTimer/GetTimers                 current=absent   pccs-prefixed=PRESENT(2)
  ChargeLocation/GetChargeLocations             current=absent   pccs-prefixed=PRESENT(2)
```

`absent` = `grpc-status 12`; `PRESENT(2)` = the method resolved and rejected the bare probe body.
After the fix a live refresh reads `Charge Target: 90%`, previously unavailable.

---

## 8. Exhaustive OTA method sweep

`testExhaustiveOtaMethodSweep` — 82 method names × the two real OTA services, on C3.

```
🔬 EXHAUSTIVE OTA METHOD SWEEP (82 names × 2 services)
  0 method(s) exist beyond the five already known
```

Names tried (each answered `Method not found`): Download, DownloadNow, StartDownload,
TriggerDownload, InitiateDownload, RequestDownload, BeginDownload, Fetch, Pull, Install,
InstallLater, Update, UpdateNow, Upgrade, Accept, AcceptUpdate, Approve, ApproveUpdate, Consent,
GiveConsent, SetConsent, Confirm, ConfirmUpdate, OptIn, Defer, Postpone, Snooze, Dismiss, Decline,
Reject, Acknowledge, Ack, MarkAsRead, SetRead, Read, Wake, WakeUp, Notify, Poll, Sync, Refresh,
Check, CheckForUpdates, Prepare, Activate, Commit, Apply, Push, Enable, Allow, Permit, Start,
Trigger, Execute, Perform, Retry, Resume, Continue, Proceed, GetSoftwareStatus, GetSoftwareState,
GetDownloadStatus, GetCampaign(s), GetConsent, SetSoftwareState, SetDownloadConsent,
SetUpdateConsent, SetPreference, SetAutoUpdate, UpdateConsent, RequestSoftware, FetchSoftware,
SyncSoftware, RefreshSoftwareInfo, PrepareInstallation, PrepareSoftware, ActivateSoftware,
StartSoftwareDownload, DownloadSoftware, InstallSoftware, ScheduleDownload.

---

## 9. WakeUp / OTA_DOWNLOAD hunt

`testHuntForWakeUpWithOtaDownloadReason` — an independent client models
`WakeUpRequest{1: reason}` with `reason=1 (OTA_DOWNLOAD)`. It is not deployed. 35 C3 probes, every
one `absent`:

```
⏰ WAKEUP HUNT (reason = 1, OTA_DOWNLOAD)
  C3   invocation.InvocationService/WakeUp          → absent
  C3   invocation.InvocationService/Wakeup          → absent
  C3   invocation.InvocationService/WakeUpVehicle   → absent
  C3   ota_mobcache.OtaDiscoveryService/WakeUp      → absent
  C3   ota_mobcache.SchedulerService/WakeUp         → absent
  C3   dtlinternet.DtlInternetService/WakeUp        → absent
  … + Wake, WakeVehicle, WakeUpCar, RequestWakeUp, TriggerDownload, InitiateDownload,
      RequestDownload, StartDownload, SoftwareDownload, OtaDownload, CheckForUpdates,
      SetConsent, GiveConsent, ConfirmUpdate, PrepareInstallation, RefreshSoftwareInfo,
      PrepareSoftware, ActivateSoftware, SetUpdateConsent  → all absent

  PCCS pccs.invocation.v1.InvocationService/WakeUp  → Access denied  (inconclusive: PCCS)
```

The only non-`absent` line is on PCCS, whose auth denial makes it useless as an existence oracle.

---

## 10. Download-interface hunt

`testHuntForSoftwareDownloadInterface`.

```
🕵️  DOWNLOAD-INTERFACE HUNT

── [1] C3 discovery document
{"c3":{"url":"https://cepmobtoken.eu.prod.c3.volvocars.com","grpcHost":"cepmobtoken.eu.prod.c3.volvocars.com","grpcPort":443,"grpcKeepAliveTime":45},
 "c3Lbs":{"url":"…identical…"}}

── [2] gRPC server reflection
  /grpc.reflection.v1.ServerReflection/ServerReflectionInfo       → grpc-status 12
  /grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo  → grpc-status 12

── [3] mystar-v2 GraphQL introspection
  HTTP 200
  {"data":null,"errors":[{"message":"Validation error of type FieldUndefined:
     Field 'mutationType' in type '__Schema' is undefined @ '__schema/mutationType'"}, …]}

── [4] app-backend force-update-version precondition
  version 5.5.0  → HTTP 200 {"errors":[{"message":"Could not validate the accessToken", …}]}
  version 6.0.0  → HTTP 200 { …same… }
  version 7.0.0  → HTTP 200 { …same… }
  version 99.0.0 → HTTP 200 { …same… }
```

(The app-backend "Could not validate the accessToken" here is because this probe used the *web*
token. With the app token it returns `data`; see section 12.)

---

## 11. mystar-v2 GraphQL name oracle

`testProbeMystarSchemaForSoftwareOperations` — introspection is stripped, but `FieldUndefined`
vs. success is a name oracle. Control `getConsumerCarsV2` succeeds; every software name is absent.

```
🧬 mystar-v2 SCHEMA NAME ORACLE
── does a mutation root exist?
  ⭐️ SUCCEEDED → {"data":{"__typename":"Mutation"}}

── query fields (getConsumerCarsV2 is the known-good control)
  getConsumerCarsV2   ⭐️ SUCCEEDED → {"data":{"getConsumerCarsV2":[{"__typename":"VehicleInformation"}]}}
  getCarImages        absent
  getSoftwareInfo  getSoftwareStatus  getSoftwareUpdate  getOtaStatus
  getVehicleSoftware  softwareUpdate  otaStatus  → all absent

── mutation fields
  startSoftwareDownload  downloadSoftware  startOtaDownload  installSoftware
  installSoftwareUpdate  scheduleSoftwareInstallation  acceptSoftwareUpdate
  updateSoftware  requestSoftwareDownload  → all absent
```

---

## 12. app-backend auth + schema

`testAppBackendWithAppClientToken` — the app-client token opens the app-backend (which the web
token never could). Introspection is neutered, but the "Did you mean" oracle works.

```
📱 APP-BACKEND WITH APP-CLIENT TOKEN (id_token present)
  PolestarId: Bearer access     → HTTP 200 {"data":{"vdms":{"getVehiclesInformation":[]}}}
  PolestarId: raw access        → HTTP 200 {"errors":[{"message":"An accessToken was not provided", …}]}
  PolestarId: Bearer id_token   → HTTP 200 {"data":{"vdms":{"getVehiclesInformation":[]}}}
  PolestarId: raw id_token      → HTTP 200 {"errors":[{"message":"An accessToken was not provided", …}]}
  Authorization: Bearer id_token→ HTTP 200 {"errors":[{"message":"An accessToken was not provided", …}]}

  ✅ authenticated — probing schema
  near-miss on vdms ⭐️ → "Cannot query field 'getVehiclesInformatio' on type 'VdmsGraphQlQueries'. Did you mean 'getVehiclesInformation'?"
  root software     → "Cannot query field 'software' on type 'PolestarGraphQlQuery'."
  root ota          → "Cannot query field 'ota' on type 'PolestarGraphQlQuery'."
  root softwareUpdate → "Cannot query field 'softwareUpdate' on type 'PolestarGraphQlQuery'."
  mutation root     → {"data":{"__typename":"PolestarGraphQlMutation"}}
  mutation startSoftwareDownload → "Cannot query field 'startSoftwareDownload' on type 'PolestarGraphQlMutation'."
  mutation downloadSoftware      → "Cannot query field 'downloadSoftware' on type 'PolestarGraphQlMutation'."
  mutation acceptSoftwareUpdate  → "Cannot query field 'acceptSoftwareUpdate' on type 'PolestarGraphQlMutation'."
```

`testAppBackendSchemaIntrospection` — introspection returns empty rather than erroring, but the
suggestion oracle still sees real names (`vdm`→`vdms`, `car`→`cars`), and none for software:

```
🔓 APP-BACKEND SCHEMA
  raw query introspection:    {"data":{"__schema":{"queryType":{"fields":[]}}}}
  raw mutation introspection: {"data":{"__schema":{"mutationType":null}}}
  __type(PolestarGraphQlQuery):    {"data":{"__type":{"fields":[]}}}
  __type(PolestarGraphQlMutation): {"data":{"__type":{"fields":[]}}}
  softwar software getSoftware ota getOta updat update getUpdate downloa download
    firmwar instal upgrad vehicl → no suggestion
  ⭐️ vdm → Did you mean 'vdms'?
  ⭐️ car → Did you mean 'cars'?     (type CarsQueries)
```

Required headers, established by the format matrix above:

```
X-PolestarId-Authorization: Bearer <app access_token or id_token>   # raw (no Bearer) → "accessToken not provided"
X-Polestar-Force-Update-Version: 5.5.0                              # omit → HTTP 428
X-Polestar-Locale: SE
User-Agent: PolestarApp/5.5.0b1102 Android/14
```

---

## 13. app-backend subfield oracle + wake-then-recheck

`testFurtherOtaAvenues` — two avenues, both clean-negative.

**A. Subfields of `CarsQueries` / `VdmsGraphQlQueries`.** Every software/consent/preference/campaign
stem returns a bare `Cannot query field 'X' on type '…'` with **no "Did you mean"** — i.e. absent:

```
🅰️  APP-BACKEND SUBFIELD ORACLE
── cars ({"data":{"cars":{"__typename":"CarsQueries"}}})
── vdms ({"data":{"vdms":{"__typename":"VdmsGraphQlQueries"}}})
  (software, ota, update, download, firmware, install, consent, preference, setting,
   campaign, notification, status, version → no suggestion on either type)
```

**B. Wake the car with a real command, then re-read.** `Lock` succeeds, but the software state
does not advance off `available`:

```
🅱️  WAKE-THEN-RECHECK
  state before wake: Available
  wake (Lock): completed
  state +5s:  Available (installed=—)
  state +10s: Available (installed=—)
  state +15s: Available (installed=—)
```

A working command wakes the car for *that command*, but does not make the OTA campaign advance —
consistent with the download being a backend-authorised, not car-initiated, step.

---

## 14. The one false positive

Recorded so it isn't trusted later.

**Service enumeration on C3 does not work.** `testDownloadTriggerLastResort` probed
`/<service>/__probe__` and read `Method not found` as "service exists":

```
🗂  C3 SERVICE ENUMERATION
  ota_mobcache.OtaDiscoveryService               ⭐️ SERVICE EXISTS
  ota_mobcache.ConsentService                    ⭐️ SERVICE EXISTS   ← invented
  ota_mobcache.DownloadService                   ⭐️ SERVICE EXISTS   ← invented
  ota_mobcache.CampaignService                   ⭐️ SERVICE EXISTS   ← invented
  services.vehiclestates.ota.OtaService          ⭐️ SERVICE EXISTS   ← invented
  ota.OtaService                                 ?                    ← not routed
```

`services.vehiclestates.ota.OtaService`, a name with no basis, "exists" identically to a real
one. The probe measures **package routing** (`ota_mobcache.*` and `services.vehiclestates.*` are
routed to a backend that says "Method not found" for any child; `ota.*` and `software.*` are not),
not service existence. Discard every "SERVICE EXISTS" line above.

The **subfield oracle in section 13** had the mirror-image bug in its *detector* (it compared
against an ASCII `'` while the JSON encodes `'`, flagging every field as EXISTS). The detector
was fixed; the underlying responses were always the clean negatives shown there. Both are the same
lesson: a probe that returns a hit for a name you invented is measuring something other than what
you think.

---

## 15. Chronos writes verification — SetTargetSoc(90)

`testLiveChronosTargetSocWrite` — verified live against a real Polestar 2 using the **web client token** (`l3oopkc_10`) against `api.pccs-prod.plstr.io:443`.

```
⚡️ LIVE CHRONOS WRITE PROBE
  Endpoint: pccs.chronos.services.v1.TargetSocService/SetTargetSoc
  Host: api.pccs-prod.plstr.io:443
  Token: Web client (l3oopkc_10)
  Target SOC: 90% (same-value mutation to avoid disturbing vehicle)

  Envelope:
    1: <request-uuid>
    2: YSM…228
    3: "RCS"
    4: {1: 120}  # timezone offset in minutes (+2h CEST)
  Payload:
    2: 90
    3: 1

  Response:
    HTTP 200 OK
    Payload: {3: 3}  # Status = 3 (Completed)
    Outcome: .completed ✅

  Readback Verification:
    Endpoint: pccs.chronos.services.v1.TargetSocService/GetTargetSoc
    Response: {3: {1: 90}}
    Target SOC verified: 90% ✅
```
