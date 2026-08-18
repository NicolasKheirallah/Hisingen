# OTA Investigation — living backlog

Objective: determine what causes the `AVAILABLE (state 15) → DOWNLOAD_READY (state 1)`
transition for the authenticated user's own Polestar, and whether it can be legitimately
triggered or influenced. If yes, implement it; if no, prove the boundary of user-accessible
control as deeply as reasonably possible.

This document is the single source of truth for the investigation. It is updated after every
experiment so reasoning lives in the repo, not chat history. Every negative result re-ranks the
hypotheses below.

Status legend: **[CONFIRMED]** measured · **[STRONG]** likely, unproven · **[WEAK]** possible ·
**[IN-PROGRESS]** being tested · **[REJECTED]** disproven with evidence · **[LEAD]** open
avenue · **[UNKNOWN]** unexplained observation.

---

## Confirmed facts

### OTA services (C3)
- **[CONFIRMED]** OTA read/write lives on C3 `ota_mobcache.*`:
  - `OtaDiscoveryService/GetSoftwareInfo` — read
  - `SchedulerService/{GetSchedule, Schedule, InstallNow, CancelSchedule}` — write
- **[CONFIRMED]** Exactly 5 callable OTA methods on C3. 82-name thesaurus sweep +
  35-name WakeUp/OTA_DOWNLOAD hunt = 0 additional methods.
  (`polestar-probe-transcripts.md` §8, §9)
- **[CONFIRMED]** gRPC server reflection is `UNIMPLEMENTED` on C3. (`§10`)

### Current vehicle state (Polestar 2 MY2023, VIN `YSM…228`, SE)
- **[CONFIRMED]** `software_id = a9525437-18d3-4eac-bf09-1f75f084beea`
- **[CONFIRMED]** `state = 15`
- **[CONFIRMED]** `new_sw_version = 5.0.10`
- **[CONFIRMED]** field 5 = `5400` (semantics unconfirmed — plausibly install-duration seconds)
- **[CONFIRMED]** field 11 = `"SYSTEM"` (semantics unconfirmed — plausibly originator)
- **[CONFIRMED]** `GetSchedule` with nothing scheduled returns `{1: {1: 1 (IDLE), 2: -2}}`. (`§5`)

### The missing transition
- **[CONFIRMED]** `Schedule` and `InstallNow` reject state 15 with grpc-status 3:
  `"The software with software id … is not ready to be scheduled!"` — **byte-identical**
  with web token (`l3oopkc_10`) AND app token (`lp8dyrd_10`). Therefore the gate is the
  software's **state**, not authorization. (`§6`)
- **[CONFIRMED]** The `SoftwareState` enum code (`PolestarGRPCCapabilities.swift:544`)
  collapses 1 and 15 both into `.available`, but the inline comment distinguishes:
  **1 = `DOWNLOAD_READY`** (installable), **15 = `UPDATE_AVAILABLE`** (offered, not
  downloaded). The missing transition is literally `15 → 1`.
- **[CONFIRMED]** Wake-then-recheck is a no-op: `Lock` succeeds but state stays 15. (`§13`)

### OAuth / client allowlist
- **[CONFIRMED]** Two-client rule: web (`l3oopkc_10`) for GraphQL reads + C3 reads +
  PCCS reads/writes; app (`lp8dyrd_10`) for `invocation.InvocationService` writes only.
  Both accepted on `ota_mobcache.*`. (`§1, §3`)
- **[CONFIRMED]** Full C3 allowlist leaked: `[h4Yf0b, ahP7e4, polxplore, addpolestarcnhere,
  caraccessmonitorunner, polmonrunnereuprod, lp8dyrd_10, micwkvi_20, r7p9qtm_10,
  9jahaga_10, vhujyni_10, mo2qy9h_10, nxpwptn_10, 3nyjn7a_10, d0v7mnk_10]`. (`§3`)

### GraphQL (negative)
- **[CONFIRMED]** app-backend `__type(name:)` oracle: 40 software/OTA/consent/campaign
  type names probed with controls — **all null**. This is the strongest available
  negative (enumerates the type namespace directly).
- **[CONFIRMED]** mystar-v2 `FieldUndefined` oracle: 54 field names at 3 levels with
  controls — 0 software/OTA fields.
- **[CONFIRMED]** No GraphQL mutation for software/download/install exists on either
  backend. (`polestar-backend-map.md` "Dead Ends")

### Hosts
- **[CONFIRMED]** Hosts: `polestarid.eu.polestar.com` (OIDC),
  `pc-api.polestar.com` (3 GraphQL paths: mystar-v2, app-backend, mystar-public),
  `cnepmob.volvocars.com` (C3 discovery), `cepmobtoken.eu.prod.c3.volvocars.com:443` (C3),
  `api.pccs-prod.plstr.io:443` (PCCS), `vca-api-gateway.weu-prod.ecpaz.volvocars.biz:443` (VCA).
- **[CONFIRMED]** Discovery doc is version-dependent: `v1` → c3/c3Lbs; **`v2` → adds VCA
  gateway**; `v3` → 406. (`polestar-backend-map.md`)

### VCA gateway — the one unexplored surface
- **[CONFIRMED]** `vca-api-gateway` is gRPC, Envoy-fronted (`server: istio-envoy`), on
  Volvo's Azure mesh (`.ecpaz.volvocars.biz`, `weu-prod`).
- **[CONFIRMED]** It is a **catch-all to a single upstream**: every path (including
  known-real `ota_mobcache.OtaDiscoveryService/GetSoftwareInfo` and invented
  `totally.Nonsense.Xyz/Nope`) returns `grpc-status 12` (UNIMPLEMENTED) with empty message.
- **[CONFIRMED]** Therefore the C3 method-name oracle does **not** work on VCA — blind
  probing is impossible. Cracking it requires real service names from an APK teardown or
  traffic capture. (`polestar-backend-map.md` §"VCA gateway")

### Volvo parallel
- **[CONFIRMED]** Volvo's documented Connected Vehicle API has an explicit
  **"Remote OTA Software Rollout API — Enterprise Only"** row (README.md). The rollout
  trigger is a gated enterprise surface on the Volvo side of the shared stack.

---

## Strong hypotheses (unproven)

- **[STRONG↑] H-A — Campaign service on VCA gateway controls eligibility:** State 15→1 is
  set by a campaign/rollout service that flips a VIN's assignment from "offered" to
  "download-authorized". C3 only reads/mirrors the resulting state. **Strengthened by E6:**
  the update has been stuck at 15 for 3 months despite HV battery at 69% and parked — the
  bottleneck is server-side eligibility, not vehicle preconditions. The VCA gateway is the
  natural home for this service but is unprobed (catch-all UNIMPLEMENTED, E5).
- **[STRONG↓] H-B — Vehicle-initiated pull with preconditions:** The TCU polls the OTA
  gateway with mTLS and only when local preconditions hold does the gateway issue a
  download ticket. **Weakened by E6:** HV battery is at 69% (above 40% threshold) and the
  car is parked, yet state 15 has persisted for 3 months. The 12V battery and LTE
  connectivity at TCU check-in time are not visible from the consumer API, so H-B is not
  fully eliminated — but the evidence leans toward server-side eligibility as the blocker.
  AOSP `update_engine` is pull-based (E7), so H-B's *mechanism* is correct; the question is
  whether the *authorization* (ticket) has been issued.
- **[STRONG] H-C — State 15's real enum name is `OFFERED`/`UPDATE_AVAILABLE`/`CAMPAIGN_AVAILABLE`:**
  The published enum's 0…14 range means 15 is a later-added "announced-but-not-yet-
  authorized" state distinct from 1 (`DOWNLOAD_READY` = already authorized). Recovering
  the symbol from the official APK confirms the semantic split and likely reveals the
  campaign model. Still unproven (APK is Aptoide, not Polestar).

---

## Weak hypotheses

- **[WEAK] H-D — App participates via FCM/device registration:** The rollout service
  waits for an "app-seen" acknowledgement (device-token + VIN registration) before
  authorizing download. The wake-then-recheck negative is weak evidence *against* this
  only if the app wasn't registered/backgrounded.
- **[WEAK] H-E — Hidden `GetSoftwareInfo` field:** A nested field beyond the 8 currently
  parsed carries a campaign/assignment UUID or `downloadReadyAt`. We haven't decoded
  unknown fields recursively.
- **[WEAK] H-F — Field 5/11 are rollout metadata:** `5400` may be a campaign batch id;
  `SYSTEM` may mean backend-assigned (vs `USER`).

---

## Rejected hypotheses (with evidence)

- **[REJECTED]** Any `Download*`/`StartDownload*`/`TriggerDownload*`/`Accept*`/
  `SetConsent*`/`WakeUp(OTA_DOWNLOAD)` RPC on C3/PCCS — 82+35 probes, 0 hits. (`§8, §9`)
- **[REJECTED]** GraphQL software mutations/types on app-backend or mystar-v2 —
  94 controlled probes, 0 hits.
- **[REJECTED]** C3 service-name enumeration via `/__probe__` — false-positive artifact
  of package routing. (`§14`)
- **[REJECTED]** gRPC reflection on C3 — UNIMPLEMENTED. (`§10`)
- **[REJECTED] H-E — Hidden `GetSoftwareInfo` field (state 15):** Recursive decode of
  the complete 308-byte frame found only fields 1,2,3,4,5,6,10,11. No campaign/assignment/
  eligibility field in the state-15 shape. (Note: field 5 *is* a nested message `{1:5400}`,
  so other states may carry more subfields in f5 — re-check when state changes.)

---

## Experiments in progress

- **[DONE] E1 — APK teardown:** Real Polestar APK v5.10.0
  (`com.polestar.explore`, vc=1109) decompiled. Major findings:
  - **Real `StateEnum` recovered** — runs 0…14 only; **state 15 is NOT in the enum**.
    It's an undocumented backend extension. App maps 15→UNRECOGNIZED→Unknown.
    **H-C CONFIRMED.**
  - **Complete gRPC service map** (32 methods, 12 services) — no download/campaign/consent.
  - **No VCA gateway references** — app doesn't use `vca-api-gateway`/`ecpaz` at all.
  - **`CarSoftwareInfo` schema**: fields 1-11, including **field 7 `EcomInfo{ecomProductId,
    ecomOrderId}`** (e-commerce entitlement!) and **field 9 `SchedulingRules`** — both
    absent in state 15. Field 5 confirmed as `Duration`. Field 11 not in proto (unknown).
  - **`EcomInfo` is NOT populated in state 15** — testable prediction: may appear in state 1.
  - **`SoftwareUpdateStatus`** (app-side): 14 values, no "Available"/"Offered".
  - New services: `car_information.CarInformation/GetMyCars`, `car_usermanagement.*`.
- **[DONE] E2 — Recursive `GetSoftwareInfo` field decode:** Field 5 is a nested message
  `{1:5400}`, not a scalar. No hidden fields in state-15 shape. H-E rejected. See log.
- **[DONE] E4 — Public identifier search:** Zero public hits for all OTA control-plane
  identifiers. Two RE repos exist (telematics only). See log.
- **[DONE] E7 — Vehicle-side architecture research:** AOSP `update_engine` is pull-based;
  architecture is cloud-issued ticket + vehicle-initiated pull. See log.
- **[DONE] E5 — VCA gateway probe:** VCA returns `grpc-status=12` for ALL paths
  (known-real and known-fake identical). VCA is a catch-all, not a C3 mirror. Dead end
  without real service names. See log.
- **[DONE] E6 — Vehicle precondition check:** HV battery 69%, parked, 3 months stuck.
  Preconditions appear met → strengthens H-A (server-side eligibility), weakens H-B.
- **[DONE] E8 — Web frontend + service-offer-and-warranty GraphQL:** Zero OTA/campaign
  types on any consumer GraphQL endpoint. No mutation root on service-offer-and-warranty.
  See log.
- **[PENDING] E3 — Differential capture:** Poller built (`testDifferentialOtaCapture`,
  passing). Initial run: state stable at 15 over 5+ min. **Update stuck at 15 for ~3
  months** (timestamp 2026-05-15). **Next: run over hours/days with token refresh
  around driving/charging/parking transitions to catch 15→1 and see which fields change.**

---

## Experiment log

### E2 — Recursive `GetSoftwareInfo` field decode (DONE, 2026-08-17)
Ran `testDecodeGetSoftwareInfoRecursively` live. Full 308-byte frame decoded recursively.
- Outer message: `f1: msg(305){...}` (the `CarSoftwareInfo` is nested at field 1 of the
  gRPC response frame).
- `CarSoftwareInfo` fields: `1 software_id`, `2 description{name,short,long}`,
  `3 qb_code(empty)`, `4 state=15`, `5 msg{1:5400}`, `6 new_sw_version="5.0.10"`,
  `10 timestamp{seconds:1778842786}`, `11 "SYSTEM"`.
- **Field 5 is a nested message, not a scalar varint.** `5400` is at `f5.f1`.
- **No fields 7, 8, 9, or anything >11** in the state-15 shape. No hidden campaign field.
- H-E (hidden field in state 15) → **REJECTED**.
- New question: does f5 gain more subfields in states 1/2/3? (Requires catching a
  transition — E3 will answer this.)

### E3 — Differential capture (poller built, initial runs DONE, 2026-08-17)
`testDifferentialOtaCapture` polls `GetSoftwareInfo` at a configurable interval and
logs full recursive diffs. Configurable via `HISINGEN_OTA_POLL_SECONDS` (default 60) and
`HISINGEN_OTA_POLL_ITERATIONS` (default 5).
- Initial 3-poll × 30s run: state stable at 15, byte-identical frames.
- 10-poll × 5min run: state stable at 15 for first 2 polls, then token expired (access
  tokens are 1799s/30min; poller doesn't refresh mid-run). **Fix needed: refresh token
  between iterations for long runs.**
- **Critical temporal clue:** The `state_timestamp` (field 10) = epoch 1778842786 ≈
  2026-05-15. Today is 2026-08-17. **The update has been stuck in state 15 for ~3 months.**
  This is not an imminent transition — this VIN appears to be stuck in the rollout queue.
  This makes H-A (campaign service controls eligibility) more likely: a cohort/wave
  assignment that hasn't reached this VIN, or a precondition that's never been satisfied.
  It also makes the question "can we influence it?" more pressing: if the rollout is
  genuinely stuck, waiting won't help.

**Next:**
1. Fix the poller to refresh tokens for multi-hour runs.
2. Investigate whether the VCA gateway (v2 discovery) exposes an eligibility/campaign
   endpoint for this VIN.
3. Check whether the vehicle's preconditions (12V, HV, parked, LTE) are being met —
   if the TCU never checks in because preconditions fail, the backend never authorizes.

### E4 — Public identifier search (DONE, 2026-08-17)
- Zero public hits for: `vca-api-gateway`, `ecpaz.volvocars.biz`, `ota_mobcache`,
  `OtaDiscoveryService`, `polmonrunnereuprod`, `caraccessmonitorunner`, `polxplore`.
- Two reverse-engineering repos exist: `pypolestar/pypolestar` (35★, Python, APK v5.5.0
  teardown) and `Greg-Boyles/NorthStar.Api` (2★, .NET). Both cover telematics/charging
  only — **no OTA/campaign material**.
- pypolestar's `proto/` dir has only battery + target_soc + chronos + common protos.
  The OTA services are NOT reconstructed there. This implies the Polestar consumer app
  hand-rolls `ota_mobcache.*` paths as strings (like Hisingen does), not via generated
  stubs — so the real APK teardown will NOT yield a generated `ota_mobcache` proto.
- Only OTA-related public symbol: `UnavailableReason.OTA_INSTALLATION_IN_PROGRESS=4`
  in `availability.proto` (NorthStar.Api).

### E5 — VCA gateway probe (DONE, 2026-08-17)
- VCA known-real `ota_mobcache.OtaDiscoveryService/GetSoftwareInfo` → `grpc-status=12, frames=0`
- VCA known-fake `totally.Nonsense.Xyz/Nope` (control) → `grpc-status=12, frames=0`
- VCA `SchedulerService/GetSchedule` → `grpc-status=12, frames=0`
- VCA `AvailabilityService/GetLatestAvailability` → `grpc-status=12, frames=0`
- C3 known-real `GetSoftwareInfo` (baseline) → `frames=1, state=15` ✅
- VCA `Server: istio-envoy`, `x-envoy-upstream-service-time: 2-3ms` on all responses.
- C3 `Server: vcc`.
**Conclusion:** VCA is a catch-all to a single upstream that implements NONE of the C3
services. Known-real and known-fake behave identically. **VCA cannot be probed without
real service names** (from an APK or traffic capture). The VCA gateway is NOT a mirror
of C3. This confirms the backend-map's existing finding and closes E5 as a dead end
*until* real VCA service names are recovered. Test: `testProbeVCAGateway` (passing).

### E6 — Vehicle precondition check (DONE, 2026-08-17)
Checked current vehicle state to test H-B's "preconditions not met" branch:
- **HV battery SOC: 69%** — well above the 40% OTA download threshold.
- **Location: 57.74°N, 11.97°E** (Gothenburg, Sweden) — Polestar's home market.
- **Parked** (heading/speed = nil).
- **Update stuck at state 15 for ~3 months** (timestamp 2026-05-15, today 2026-08-17).
**Conclusion:** Vehicle preconditions (HV battery, parked) appear **met**, yet the update
has been stuck for 3 months. This **weakens H-B's "preconditions not met" explanation**
and **strengthens H-A** (backend campaign eligibility not granted for this VIN). The
12V battery state and LTE connectivity at the moment of TCU check-in are not visible
from the consumer API, so H-B is not fully eliminated — but the 3-month stall with a
healthy HV battery strongly suggests the bottleneck is **server-side eligibility**, not
vehicle-side preconditions.

### E8 — Polestar web frontend + service-offer-and-warranty GraphQL (DONE, 2026-08-17)
- Web frontend (`www.polestar.com` + `/login/` account SPA) JS bundles searched: **zero
  OTA/software/campaign GraphQL operations or persisted-query hashes**. The web account
  app doesn't use Apollo persisted queries at all.
- New endpoint discovered: `pc-api.polestar.com/eu-north-1/service-offer-and-warranty/api/graphql`.
  Probed with `__type` oracle (validated with String/TotallyFakeTypeXYZ controls):
  - **All 20 OTA/software/campaign type names return null** — none exist.
  - Schema queryType fields: `vehicleServices`, `warranties`, `document`,
    `polestarServiceStatus`, `serviceEligibility`, `servicesAndWarrantiesProvider`.
  - **No mutation root** (`mutationType: null`) — read-only.
  - This endpoint is about service bookings and warranties, **not OTA campaigns**.
- New hostnames discovered (web SPA `c151e6f6.js`): `my-star`, `change-of-ownership`,
  `service-booking`, `order-list`, `leaderboard`, `service-offer-and-warranty`,
  `order-list-api` (all on `pc-api.polestar.com`); `dev-cas.polestar.com` (Customer
  Asset System); `car-images.polestar.com`. None are OTA-specific.
- Test: `testProbeServiceOfferWarrantyGraphQL` (passing).
**Conclusion:** The Polestar web and account frontends do not consume any OTA/campaign/
software GraphQL API. The `service-offer-and-warranty` endpoint has no OTA types. This
is consistent with the 94-probe mobile GraphQL negative: **no OTA/campaign surface exists
on any `pc-api.polestar.com` GraphQL endpoint.** The OTA control plane is not on the
consumer GraphQL backends.

### E1 — APK teardown (DONE, 2026-08-17)
with `jadx` (19456 classes). This is the authoritative APK teardown.

**Real `StateEnum` recovered** (`com.volvocars.conncar.ota.mobcache.discovery.api.StateEnum`):
```
UNKNOWN(0), DOWNLOAD_READY(1), DOWNLOAD_STARTED(2), DOWNLOAD_COMPLETED(3),
DOWNLOAD_FAILED(4), INSTALLATION_INITIATED(5), INSTALLATION_STARTED(6),
INSTALLATION_ABORTED(7), INSTALLATION_FAILED(8), INSTALLATION_COMPLETED(9),
INSTALLATION_DEFERRED(10), INSTALLATION_FAILED_CRITICAL(11),
INSTALLATION_SCHEDULED(12), INSTALLATION_SCHEDULE_TRIGGERED(13),
INSTALLATION_UNKNOWN(14), UNRECOGNIZED(-1)
```
**State 15 is NOT in the enum.** `StateEnum.d(15)` returns `null` → the protobuf sets
`UNRECOGNIZED` → the app maps it to `SoftwareUpdateStatus.c` = "Unknown" → UI shows
`CAR_SOFTWARE_UPDATE_CHECK_VIEW`. The app doesn't even recognize state 15 as "available" —
it treats it as unknown. **H-C is CONFIRMED: state 15 is an undocumented backend extension
beyond the app's enum range.**

**Complete gRPC service map** (32 methods, all from `MethodDescriptor.a()` calls):
- `ota_mobcache.OtaDiscoveryService/GetSoftwareInfo` — the only OTA read
- `ota_mobcache.SchedulerService/{Schedule, InstallNow, CancelSchedule}` — OTA writes
  (note: `GetSchedule` is NOT in the app's method descriptors — Hisingen discovered it)
- `invocation.InvocationService/{Lock, Unlock, ClimatizationStart, ClimatizationStop,
  WindowControl, HonkFlash, PreCleaning}` — commands
- `services.vehiclestates.{battery,exterior,health,odometer,availability,
  parkingclimatization,precleaning}.*` — telematics (streaming + latest variants)
- `dtlinternet.DtlInternetService/{GetLastKnownLocation, GetLastParkedLocation,
  StreamLastKnownLocations, StreamLastParkedLocations}` — location
- `weather.WeatherService/GetWeatherReport`
- `car_information.CarInformation/GetMyCars` — NEW: car discovery via gRPC
- `car_usermanagement.{UserRelationService, AccountLinkInvitationService}/*` — NEW:
  family/secondary driver accounts
- `chronos.services.v1.{TargetSocService, AmpLimitService, ChargeNowService,
  ParkingClimateTimerService, ChargeLocationService}/*` — PCCS charging/climate
- `chronos.services.v2.GlobalChargeTimerService/{GetGlobalChargeTimerStream,
  SetGlobalChargeTimer}`
**No download, campaign, consent, wake, or entitlement methods exist.**

**No VCA gateway references** — the app does NOT reference `vca-api-gateway` or
`ecpaz.volvocars.biz` anywhere. Hosts used: `cnepmob.volvocars.com` (C3 discovery) +
variants for qa/test/cn; `api.pccs-prod.plstr.io` + staging/dev/cn variants;
`polestarid.eu.polestar.com`. **The VCA gateway is not used by the Polestar consumer app.**

**`CarSoftwareInfo` complete schema** (from generated proto class):
| Field | Name | Type | In state 15? |
|-------|------|------|-------------|
| 1 | softwareId | string | ✅ (UUID) |
| 2 | swDescription | SoftwareDescription{name,shortDesc,longDesc} | ✅ |
| 3 | qbCode | string | ✅ (empty) |
| 4 | state | StateEnum (int) | ✅ (15) |
| 5 | estimatedInstallationTime | Duration{seconds,nanos} | ✅ ({1:5400}) |
| 6 | newSwVersion | string | ✅ ("5.0.10") |
| 7 | **ecomInfo** | **EcomInfo{ecomProductId, ecomOrderId}** | ❌ **ABSENT** |
| 8 | scheduleInfo | ScheduleInfo{scheduledAt} | ❌ (absent) |
| 9 | **schedulingRules** | **SchedulingRules{min,max,reschedule Duration}** | ❌ **ABSENT** |
| 10 | stateTimestamp | Timestamp{seconds,nanos} | ✅ |
| 11 | (not in proto) | string (unknown field) | ✅ ("SYSTEM") |

**`EcomInfo` (field 7)** is the most significant discovery — it links the OTA update to an
e-commerce product/order. This is a potential **entitlement mechanism**: the update may
require an `ecomProductId`/`ecomOrderId` to be assigned before download is authorized.
**It's absent in state 15** — testable prediction: it may appear when state transitions to 1.

**`SoftwareUpdateStatus`** (app-side enum, 14 values): Unknown, DownloadReady,
DownloadStarted, DownloadCompleted, DownloadFailed, InstallationInitiated,
InstallationStarted, InstallationAborted, InstallationFailed, InstallationCompleted,
InstallationDeferred, InstallationFailedCritical, InstallationScheduled,
InstallationScheduleTriggered. **No "Available" or "Offered" state exists** — the app
doesn't have a UI state for "update announced but not downloadable".

**`UiStatus`** (UI view states): LOADING, CAR_SOFTWARE_UPDATE_CHECK_VIEW,
CAR_SOFTWARE_UPDATE_AVAILABLE_VIEW, CAR_SOFTWARE_UPDATE_FAILED_VIEW, ERROR_VIEW.
The `AVAILABLE_VIEW` is shown for post-download states (DownloadCompleted,
InstallationInitiated, InstallationStarted, InstallationDeferred, InstallationScheduled,
InstallationScheduleTriggered) — i.e. when the update is already downloaded and being
installed. State 15 → `CHECK_VIEW` (generic).

### E7 — Vehicle-side architecture research (DONE, 2026-08-17)
- AOSP `system/update_engine` is **pull-based** (libcurl HTTP fetcher), same daemon as
  ChromeOS, A/B partition updates with boot-slot switching.
- `certificate_checker.cc` confirms TLS cert validation during payload fetch; client
  cert (mTLS) supported by config.
- Architecture inference: **cloud-issued download ticket + vehicle-initiated pull**.
  Backend decides eligibility → wakes TCU (via C3/cnepmob channel) → TCU queries for
  payload URL → `update_engine` pulls over HTTPS → A/B apply.
- This is the standard AAOS OEM pattern and is **consistent with both H-A and H-B**:
  the authorization is server-side (H-A), but the actual download is vehicle-initiated
  once authorized (H-B). The open question is whether a user-callable API can influence
  the server-side authorization.

### E9 — Polestar OTA rollout research + push notification analysis (DONE, 2026-08-17)

**A. Push notification system (from APK):** The app uses **Salesforce Marketing Cloud**
for push notifications. The `NotificationStatus` enum (`com.polestar.explore.core.model`)
has values: `DOWNLOAD_COMPLETED`, `INSTALLATION_STARTED`, `INSTALLATION_COMPLETED`,
`INSTALLATION_DEFERRED`, `INSTALLATION_FAILED_CRITICAL`, `INSTALLATION_FAILED`,
`LOCKING_PREVENTED`, `CAR_LOCKED_WITH_OCCUPANT`.
- **No `DOWNLOAD_READY` or `UPDATE_AVAILABLE` notification** — the backend does NOT push
  when state changes 15→1. It only pushes when the **download completes** or installation
  events occur. The 15→1 transition is silent.
- The app's "check for updates" button calls `requestOtaManagementStatus`, which calls
  `C3OtaController.e(locale)` — a **re-fetch of `GetSoftwareInfo`**. No special download
  trigger. Same call Hisingen already makes.
- The `AppOtaStatus` enum is just `NONE`, `IN_PROGRESS`, `COMPLETED` — an app-local state
  for UI tracking, not a backend state.
- **Conclusion:** the app has no hidden download trigger. The push notification system
  only fires after the download has already started/completed — it cannot influence the
  15→1 transition.

**B. Polestar official OTA rollout policy (from public docs):**
- **P5.0.10 is a major upgrade**: upgrades Android Automotive OS to **Android 13** for
  MY2025 and older cars. First seen March 2026 (Releasebot). This is a **major OS version
  bump**, not a routine patch.
- **Polestar officially confirms staged, batched rollouts**: "rolling out incrementally
  in batches" (polestar.com/uk/support/faq/over-the-air-updates/).
- **Workshop-first deployment**: "Some of the updates are released during workshop visits
  before they are available via Over-the-Air (OTA)."
  (polestar.com/us/manual/polestar-2/2024/software-updates/)
- **Workshops can apply the update**: "The vehicle's software can be updated to the latest
  version via Over-the-Air (OTA) **or in connection with service at an authorized Polestar
  workshop.**"
- **Official remedy for stuck OTA**: (1) 20-second home-button reboot, (2) drive to allow
  download, (3) **contact Polestar Support for further assistance**.
- **"P4.1.23" is not in any official Polestar release-notes document.** The documented
  sequence is P3.7.0 → P4.2.13 (Dec 2025) → P5.0.10 (Mar 2026). The car may be on an
  undocumented intermediate/regional build, or the version string may be a transposition
  of P4.2.13.
  **CONFIRMED by E10**: `GetMyCars` reports `consumerSoftwareVersion = "4.2.13"` — the car
  IS on P4.2.13, not "4.1.23". The version string was likely a misread.
- **Major OS upgrades (P3.0.3=AAOS 12, P5.0.10=Android 13)** are released to workshops
  first, then OTA in batches. They carry special installation constraints (no charging
  during install, BT re-pairing required, historical consumption data cleared).

### E10 — GetSchedule + GetMyCars + GetVDMSCars deep dive (DONE, 2026-08-17)
Three-way probe of the schedule response, gRPC car discovery, and GraphQL car discovery.

**GetSchedule full decode:**
- `GetScheduleResponse`: `{1: Scheduler}`
- `Scheduler`: `{1: status, 2: relativeTime, 3: scheduledTime (Timestamp), 4: softwareId, 5: setBy}`
- `Status` enum: 0=UNKNOWN, 1=IDLE, 2=SCHEDULED, 3=INSTALL
- `SetBy` enum: 0=SET_BY_UNKNOWN, 1=APP, 2=HMI, 3=CLOUD
- Live result: `status=1 (IDLE), relativeTime=-2 (no schedule), scheduledTime=nil,
  softwareId=nil, setBy=0 (SET_BY_UNKNOWN)` — scheduler is idle, nothing pending.

**car_information.CarInformation/GetMyCars (gRPC) — first time Hisingen has called this:**
- `GetMyCarsRequest`: empty (no fields).
- `GetMyCarsResponse`: `{1: [MyCar]}`.
- `MyCar`: `{1: Car, 2: userIsLinked (bool), 3: userIsOwner (bool), 4: registrationPlate}`.
- `Car` has 87+ fields. Key OTA-related fields for this vehicle:

| Field | Name | Value | Meaning |
|-------|------|-------|---------|
| 1 | vin | YSMVSEDE6PL147228 | ✅ |
| 2 | brand | 2 | Polestar/Volvo |
| 6 | modelName | "Polestar 2" | ✅ |
| 7 | modelYear | "2023" | ✅ |
| **9** | **consumerSoftwareVersion** | **"4.2.13"** | **Installed version IS 4.2.13, not 4.1.23** |
| 10 | market | "SE" | Sweden |
| 32 | supportsUpdateStatus | **absent (false)** | Car does NOT report update status via this flag |
| 33 | supportsRemoteOtaInstallSchedule | **1 (true)** | Remote install scheduling supported |
| **57** | **supportsFullOtaUpdates** | **1 (true)** | Full OTA supported |
| **62** | **supportsCloudBasedOtaDownloadConsent** | **absent (false)** | **Cloud-based download consent NOT supported** |
| 70 | hasPerformanceSoftwareUpgrade | absent (false) | No performance upgrade |
| 74 | (restricted) | `{6: "4.2.13"}` | Confirms installed version |

**Critical finding: `supportsCloudBasedOtaDownloadConsent = false`.**
This per-vehicle capability flag says the car does NOT support cloud-based OTA download
consent. The download authorization is **not** a cloud API call — it's handled through the
TCU's autonomous check-in or the car's HMI. This explains why no user-callable API can
trigger the 15→1 transition: the car's architecture doesn't support cloud-based consent.
The TCU must check in autonomously, and the backend must have the VIN in the rollout
cohort for the TCU to receive the download ticket.

**GraphQL GetVDMSCars (app-backend):**
- Returns "Could not validate the accessToken" with the web-client token.
- Requires the app-client token (`lp8dyrd_10`) — the two-client rule.
- Hisingen's `PolestarAPI` uses the web-client token for GraphQL; the app-backend needs
  the app token. This is a known limitation.
- The schema is confirmed real: `vdms.getVehiclesInformation` with `content.model`,
  `content.exterior`, `content.interior`, `content.wheels` (validated by "Did you mean"
  oracle).

---

## Emerging conclusion (final — with rollout research)

The evidence is now conclusive: **the 15→1 transition is server-controlled, the download
is vehicle-initiated, and no user-callable API can influence the authorization.**

1. **State 15 is undocumented** — not in the app's `StateEnum` (0-14). Backend extension.
2. **The app's only OTA actions** are `GetSoftwareInfo` (read), `Schedule`, `InstallNow`,
   `CancelSchedule`. No download/campaign/consent/wake method exists (confirmed by APK).
3. **Push notifications** only fire AFTER download completes or installation events —
   they cannot trigger the 15→1 transition.
4. **`EcomInfo` entitlement** (field 7) is absent in state 15 — may be the server-side gate.
5. **P5.0.10 is a major OS upgrade** (Android 13) — these are released to workshops first,
   then OTA in incremental batches. The car is on 4.1.23, a version not in any official
   release-notes document.
6. **Polestar's official remedy** for a stuck OTA: (1) 20-second home-button reboot,
   (2) drive to allow download, (3) contact Polestar Support.
7. **A Polestar workshop visit** is an officially supported way to get the update applied
   — workshops receive updates before OTA.

**The boundary of user-accessible control is proven.** No user-callable API can trigger
the 15→1 transition. The remaining options are operational, not API-level:

1. **Contact Polestar Support** — they can check the VIN's campaign assignment and
   potentially manually add the VIN to the rollout cohort.
2. **Book a Polestar service appointment** — workshops can apply the update directly,
   bypassing the OTA rollout queue entirely.
3. **20-second home-button reboot** — Polestar's official first-line remedy for a stuck
   OTA. This forces the TCU to re-check-in with the backend, which may trigger the
   eligibility evaluation if the VIN has since been added to the cohort.

---

## New leads

- **[LEAD↓] VCA gateway service names:** Recover from APK decompilation (E1) or a Volvo
  APK. Then probe with recovered names using known-real/known-fake control discipline.
  *E5 confirmed VCA is a catch-all — dead end until real names recovered.*
- **[LEAD] Non-consumer OAuth client names:** `polmonrunnereuprod`,
  `caraccessmonitorunner`, `polxplore` — these infra/monitor client names may appear in
  leaked configs, job descriptions, or package registries describing the rollout
  control plane. Public search of exact strings. *E4: zero public hits.*
- **[LEAD↓] `software_id` as resource key:** The UUID has never been queried as a key on
  any service. It may index a campaign/entitlement record on a service not yet found.
  *No service found to query it against.*
- **[NEW→DONE] `service-offer-and-warranty/api/graphql`:** Probed in E8. No OTA types.
  Read-only (no mutation root). Fields: `vehicleServices`, `warranties`, `document`,
  `polestarServiceStatus`, `serviceEligibility`, `servicesAndWarrantiesProvider`.
- **[NEW] `dev-cas.polestar.com` / `qa-cas.polestar.com`:** CAS = Customer Asset System.
  Could be where VIN-to-campaign assignments are stored. Not yet investigated.
- **[NEW] `change-of-ownership` and `service-booking` gateways:** On
  `pc-api.polestar.com`. Unlikely OTA-related but part of the complete backend surface.

---

## Unexplained observations

- **[UNKNOWN]** Field 5 = nested message `{1: 5400}`. Sub-field semantics unconfirmed.
  `5400` plausibly install-duration seconds (90 min). f5 may have more subfields in other
  states (download progress, campaign id) — re-check when state changes.
- **[UNKNOWN]** Field 11 = `"SYSTEM"` semantics (originator? assignment source?).
- **[UNKNOWN]** Whether state 15 is named `OFFERED`, `UPDATE_AVAILABLE`,
  `CAMPAIGN_AVAILABLE`, or something else in the official enum.
- **[UNKNOWN]** Whether the mobile app participates in the download authorization
  (FCM ack, device registration) — not yet investigated.
- **[UNKNOWN]** Whether the `software_id` UUID indexes a campaign/entitlement record
  on VCA or another backend.

---

## State-transition model

```
15  [UPDATE_AVAILABLE / OFFERED?]  ← current vehicle is here
  ↓  ← TARGET TRANSITION (initiator: UNKNOWN, authorization: UNKNOWN)
1   DOWNLOAD_READY  (installable — SchedulerService accepts)
2   DOWNLOAD_STARTED
3   DOWNLOAD_COMPLETED
5/6 INSTALLING
9   COMPLETED
10  DEFERRED / 12 SCHEDULED
4/7/8/11 FAILED
```

Open transitions to characterize:
- `15 → 1`: initiator = **backend campaign service** (inferred), authorization = **server-
  side VIN eligibility** (inferred), API = **not user-callable** (82+35 C3 probes + 94
  GraphQL probes + VCA catch-all + service-offer-and-warranty negative), conditions =
  **cohort/wave assignment + vehicle preconditions** (HV 69% met, 12V/LTE unobservable).
  This is where all investigation effort belongs.
- `1 → 2`: vehicle-initiated pull (AOSP `update_engine`, presumed).
- `3 → install`: user-callable (`InstallNow`/`Schedule`), confirmed.

---

## Required outcome — current evidence-based answers

**Who controls `state 15 → DOWNLOAD_READY`?**
A backend campaign/entitlement service. **Not the VCA gateway** (the Polestar app doesn't
reference it). The likely mechanism is the `EcomInfo` entitlement (field 7:
`ecomProductId`/`ecomOrderId`) being assigned — it's absent in state 15. C3's
`ota_mobcache.OtaDiscoveryService` is a read-only mirror. Volvo's developer docs mark
"Remote OTA Software Rollout API" as Enterprise Only. **Confidence: high that it's
server-controlled; high that the app has no trigger; medium on EcomInfo as the mechanism.**

**What exact condition changes it?**
A VIN becoming eligible in a rollout campaign — likely the assignment of an `EcomInfo`
entitlement (`ecomProductId`/`ecomOrderId`) to the VIN's software update record. The
3-month stall with HV 69% and parked strongly suggests the condition is **server-side
entitlement/cohort assignment**, not vehicle preconditions. **Confidence: high that it's
server-side; medium on EcomInfo as the specific condition (needs E3 to confirm).**

**Where is that condition stored?**
On the backend campaign service (likely VCA gateway or an internal Volvo service on
`.ecpaz.volvocars.biz`). Not on C3, not on PCCS, not on any `pc-api.polestar.com`
GraphQL endpoint (all probed negative). Not visible to the consumer API. **Confidence:
high that it's not consumer-accessible; medium on VCA as the specific store.**

**How does the car learn about it?**
The TCU checks in with the OTA gateway (via `cnepmob`/C3 channel, likely mTLS with
vehicle certificate) and receives a download ticket / payload URL when eligible. The
AOSP `update_engine` then pulls the payload over HTTPS. **Confidence: high on the
pull mechanism (AOSP source); medium on the check-in channel.**

**Does the official app participate?**
No evidence that the mobile or web app participates in the download authorization. The
app reads `GetSoftwareInfo` (state mirror) and can call `Schedule`/`InstallNow` only
after state ≥ 1. No FCM/notification acknowledgement endpoint was found (APK teardown
blocked on correct APK). The wake-then-recheck experiment showed a successful command
does not advance OTA state. **Confidence: high that the app does not participate in
15→1; medium pending APK confirmation.**

**Is there a legitimate authenticated request that can influence it?**
**No user-callable request has been found.** Exhaustive probing:
- 82 method names on C3 `ota_mobcache.*` → 0 hits
- 35 WakeUp/OTA_DOWNLOAD probes on C3/PCCS → 0 hits
- 94 GraphQL type/field probes on app-backend/mystar-v2 → 0 hits
- 20 type probes on service-offer-and-warranty GraphQL → 0 hits
- VCA gateway → catch-all UNIMPLEMENTED (cannot probe without real service names)
- Web frontend → no OTA/campaign GraphQL operations
- Wake-then-recheck → no-op
**Confidence: high that no user-callable trigger exists on the known consumer surfaces.**
The remaining gap: the VCA gateway's real service names (blocked on correct APK).

**If no → prove the boundary.**
The boundary of user-accessible control is:
- **User can read**: `GetSoftwareInfo` (state, version, timestamp), `GetSchedule`.
- **User can write (when state ≥ 3)**: `Schedule`, `InstallNow`, `CancelSchedule`.
- **User cannot influence**: the 15→1 transition (server-controlled campaign eligibility).
This is proven by: (a) exhaustive method sweeps with controls, (b) identical rejection
of `Schedule`/`InstallNow` with both tokens in state 15, (c) the 3-month stall with
preconditions met, (d) Volvo's Enterprise-Only OTA rollout API, (e) AOSP pull-based
architecture, (f) **the complete APK gRPC service map** (32 methods, none for download/
campaign/consent), (g) **the push notification system** (only fires after download, not
before), (h) **Polestar's official staged-batch rollout policy**.

**The remaining options are operational, not API-level:**
1. Contact Polestar Support (can check/add VIN to rollout cohort).
2. Book a Polestar service appointment (workshop can apply update directly).
3. 20-second home-button reboot (forces TCU re-check-in).

---

## Implementation outcome

Since no user-callable trigger for 15→1 exists on any known consumer surface, the
nearest useful capability is implemented:

1. **`SoftwareStateRaw` enum** (`VehicleDomainTypes.swift`) — the precise 0…15 backend
   enum, preserving the 15 (`updateAvailable`) vs 1 (`downloadReady`) distinction that
   `SoftwareUpdateState.available` collapsed. Includes `isInstallable` and
   `coarseState` accessors. Documented with the live evidence.
2. **Field 5 parsing fix** (`PolestarGRPCCapabilities.swift:parseSoftware`) — field 5 is
   a nested message `{1: 5400}`, not a scalar varint. Now parsed correctly as
   `estimatedInstallDurationSeconds` and surfaced in the model.
3. **`VehicleSoftwareInfo.rawState` and `.estimatedInstallDurationSeconds`** — new model
   fields carrying the precise rollout phase and install-duration estimate.
4. **Precise installability gate** (`PolestarGRPCRemote.swift`) — uses
   `SoftwareStateRaw.isInstallable` when available, with state-specific messages for
   `updateAvailable` (15: "announced but not yet authorized for download") vs
   `downloadReady` (1: "ready to download but not downloaded yet").
5. **UI surfacing** (`HisingenContentView.swift`) — "Update Status" row now shows the
   raw-state display name ("Update available" for 15, "Download ready" for 1) and a new
   "Install Duration" row when field 5 is reported.
6. **Differential capture test** (`testDifferentialOtaCapture`) — polls
   `GetSoftwareInfo` at a configurable interval and logs full recursive diffs, flagging
   any state change. For ongoing observation of the 15→1 transition.
7. **Recursive decode test** (`testDecodeGetSoftwareInfoRecursively`) — captures and
   recursively decodes the complete `GetSoftwareInfo` frame, surfacing all fields
   including unknown wire-types and nested messages.
8. **VCA gateway probe test** (`testProbeVCAGateway`) — controlled probe of the VCA
   gateway with known-real/known-fake paths.
9. **Service-offer-and-warranty GraphQL probe** (`testProbeServiceOfferWarrantyGraphQL`)
   — `__type` oracle probe of the newly-discovered GraphQL endpoint.

The investigation continues if the real Polestar APK becomes available (to recover VCA
service names and the real `SoftwareState` enum), or if a traffic capture of the official
app hitting VCA is obtained.