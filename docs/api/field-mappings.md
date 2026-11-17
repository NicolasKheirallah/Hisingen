# Data sources and field mappings

This section shows where each part of the app gets its data and which backend call carries each
command. Volvo uses documented developer APIs. Everything Polestar-side below was reverse
engineered, can change without notice, and is not endorsed by Polestar. Where a mapping is not
confirmed, the table says so.

## Hosts

| Brand | Host | Used for |
| --- | --- | --- |
| Polestar | `polestarid.eu.polestar.com` | Sign-in (OpenID Connect) |
| Polestar | `pc-api.polestar.com/eu-north-1/mystar-v2/` | Vehicle discovery and telematics (GraphQL), session grant only |
| Polestar | `pc-api.polestar.com/eu-north-1/app-backend/api/graphql` | Second discovery source (VDMS), command grant only |
| Polestar | `pc-api.polestar.com/eu-north-1/mystar-public/` | Car renders, API key, no sign-in |
| Polestar | `pc-api.polestar.com/eu-north-1/data-portal/m2m/` | Developer Portal REST (EU Data Act) |
| Polestar | `cnepmob.volvocars.com` | Returns the C3 gRPC host. Looked up again every 12 hours, keeping the last working host if the lookup fails |
| Polestar | C3 host from discovery | Vehicle-state reads, remote commands, software updates |
| Polestar | `api.pccs-prod.plstr.io` | Charging settings: reads and writes |
| Volvo | `volvoid.eu.volvocars.com` | Sign-in (OAuth 2 with PKCE) |
| Volvo | `api.volvocars.com` | Connected Vehicle, Energy and Location APIs |

Weather comes from Open-Meteo and Swedish spot prices from Elpriset just nu.se. See
[Privacy](../using-hisingen.md#privacy).


## Polestar: what is read, and from where

| Service and call | Shown in Hisingen as |
| --- | --- |
| `BatteryService/GetLatestBattery` | State of charge, range, charging state, power, current, voltage, energy breakdown, discharge info |
| `AvailabilityService/GetLatestAvailability` | Whether the car is reachable, and its usage mode |
| `ExteriorService/GetLatestExterior` | Locks, doors, windows, hood, tailgate |
| `HealthService/GetHealth` | Tyre pressures, lamp, fluid and service warnings |
| `OdometerService/GetOdometer`, `DashboardService/GetLatestDashboard` | Odometer |
| `ParkingClimatizationService/GetLatestParkingClimatization` | Climate state, seat and wheel requests, climate errors and warnings |
| `PreCleaningService/GetPreCleaning` | Cabin cleaning status and air quality |
| `DtlInternetService/GetLastKnownLocation` | Last reported location |
| `OtaDiscoveryService/GetSoftwareInfo`, `SchedulerService/GetSchedule` | Software version, update state and a scheduled install |
| `TargetSocService/GetTargetSoc`, `AmpLimitService/GetAmpLimit` | Charge target and charging-current limit |
| `ChargeLocationService/GetChargeLocations` | Saved charge locations |
| `GlobalChargeTimerService/GetGlobalChargeTimerStream`, `ParkingClimateTimerService/GetTimers` | Charging schedule and climate timers |
| `CarInformation/GetMyCars` | The car's capability record, which gates controls (see [Remote controls](../remote-controls.md#what-the-car-reports-decides-what-you-see)) |
| GraphQL `getConsumerCarsV2`, `carTelematicsV2` | Vehicle discovery and the telematics fallback |
| GraphQL `getCarImages` | Car renders |
| GraphQL app-backend `vdms.getVehiclesInformation` | Extra discovery data for the garage |

The charging-settings services run on the PCCS host. The rest run on the C3 host. The
`charging/is-at-charge-location` read is no longer used: the backend answered
`DATA_NOT_AVAILABLE` on every call.

**Developer Portal REST.** `POST /token` issues a client-credentials token. `GET /v1/vehicles`
discovers vehicles. Under `/v1/vehicles/{vin}/telemetry/`: `availability`, `battery`, `odometer`,
`location`, `exterior`, `health`, `parking-climatization` and `pre-cleaning`. Under
`/v1/vehicles/{vin}/charging/`: `target-soc`, `amp-limit`, `charge-locations`,
`global-charge-timer`, `charge-now` and `parking-climate-timer`. The portal reports odometer and
trip meters to the metre and adds reference tyre pressures, which the consumer interface does not.


## Polestar: which call carries each command

| Command | Service | Method | Grant |
| --- | --- | --- | --- |
| Lock | `invocation.InvocationService` | `Lock` | Command |
| Unlock, unlock trunk | `invocation.InvocationService` | `Unlock` | Command |
| Tailgate open, close | `invocation.InvocationService` | `TailgateControl` | Command |
| Windows open, close | `invocation.InvocationService` | `WindowControl` | Command |
| Climate start, stop | `invocation.InvocationService` | `ClimatizationStart`, `ClimatizationStop` | Command |
| Horn, lights, both | `invocation.InvocationService` | `HonkFlash` | Command |
| Cabin pre-cleaning | `invocation.InvocationService` | `PreCleaning` | Command |
| Charge target | `TargetSocService` | `SetTargetSoc` | Session |
| Charging-current limit | `AmpLimitService` | `SetAmpLimit` | Session |
| Charge now, resume schedule | `ChargeNowService` | `StartOverrideChargeTimer`, `StopOverrideChargeTimer` | Session |
| Charging schedule | `GlobalChargeTimerService` (v2) | `SetGlobalChargeTimer` | Session |
| Climate timers | `ParkingClimateTimerService` | `SetTimer`, `DeleteTimer` | Session |
| Saved charge locations | `ChargeLocationService` | `CreateAtTheCarLocation`, `UpdateAlias`, `UpdateAmpLimit`, `UpdateMinimumSoc`, `UpdateOptimizedSetting`, `DeleteLocation` | Session |
| Software install | `ota_mobcache.SchedulerService` | `Schedule`, `InstallNow`, `CancelSchedule` | Session or command |

Polestar gates remote commands on a list of approved OAuth client IDs that is separate from the
sign-in scope. Neither client Hisingen can use is enough alone. The web client can list vehicles
and change charging settings but cannot send invocation commands. The app client can send
invocation commands but its token is rejected for reads. Hisingen therefore holds two grants, the
**Session** grant and the **Command** grant, and picks one per call. That is why remote commands
need the separate authorization step. The charging services use the `pccs.chronos` prefix on the
PCCS host. Invocation commands go through the C3 host, because the PCCS invocation service
refuses both clients.

An invocation moves through queued in the cloud, acknowledged by the car, then finished.
Rejections come back as privacy mode on, an invalid vehicle mode or a conflicting command. A
command accepted by the server is not the same as a finished one, and Hisingen reports which one
it knows.


## Polestar: decoded protobuf fields

The field numbers come from the descriptors published for Polestar's own app, checked against
captured frames and the Developer Portal's official schema. Nested notation `35.5` means field 5
inside field 35. Anything Hisingen cannot name is kept as a raw field.

| Message | Field | Meaning | Status |
| --- | --- | --- | --- |
| Battery | 4, 8 | Range in km, and range in miles used only when field 4 is absent | Confirmed |
| Battery | 12 | Average consumption, kWh/100 km, automatic | Confirmed |
| Battery | 14, 15, 16 | Total energy used: manual trip, automatic trip, since charge (Wh) | Confirmed |
| Battery | 20, 21, 22 | The same three periods split into other, driving, climate and battery (Wh) | Confirmed, absent on the test car |
| Battery | 23, 24, 25 | The same split as percentages | Confirmed, absent on the test car |
| Battery | 27 | Discharge info: energy available, increase, power limit | Confirmed |
| Battery | 28 | Charging status: 1 charging, 5 idle, 15 error, 16 done (0 to 16) | Confirmed |
| Battery | 29, 30 | Manual preconditioning, cold-battery status | Confirmed in the app, never seen on the test car |
| Availability | 5 | Usage mode: 1 abandoned, 2 inactive, 3 convenience, 4 active, 5 driving, 6 engine on, 7 engine off | Confirmed |
| Climate | 4 | Errors: fuel low, battery low, not connected to power, no start needed, service required, temporarily unavailable, persistent error, reached max runtime | Numbering confirmed, never observed |
| Climate | 5 | Warnings: battery low, run time nearing limit | Numbering confirmed, never observed |
| Climate | 6 | Ventilation: 1 cooling, 2 heating, 3 neutral | Confirmed |
| Climate | 9, 10, 11, 12, 13 | Requested seat heat: front left, front right, rear left, rear right, and steering wheel (0 unspecified, 1 off, 2 low, 3 medium, 4 high) | Confirmed |
| Climate | 17 | Main climate running status | Likely, never seen on the wire |
| Car (`GetMyCars`) | 16 | Honk and flash mode: 1 none, 2 combined, 3 independent, 4 flash only, 5 horn only | Confirmed, gates the control |
| Car | 36.1, 36.2 | Lock type and unlock type, gating locking and unlocking | Confirmed, in use |
| Car | 35.10 | Charge timers and saved locations supported | Confirmed, in use |
| Car | 35.13, 35.17, 35.18 | Per-location charge limits shown in the capabilities inspector | Confirmed, in use |
| Car | 35.20 | Plug and charge identifier | Confirmed, in use |
| Car | 37.1, 37.3 | Climatization type and maximum runtime | Confirmed, in use |
| Car | 44 | Gross vehicle weight rating | Confirmed, in use |
| Car | 47 | `visual_id`: groups for vehicle type, front grille variant and model year are named | Other 13 groups unverified |
| Charging | 35.29 | Plug and charge supported | Conflicts with the REST value, so the app waits for the identifier |
| Charging | 35.43 | Unknown | Unresolved: the server sends 3, the app's schema has no such tag |

Legacy charging status values 7 and 8 mean smart charging paused and done, and field 28 is
preferred when present. Seat intensities use a different scale from the Developer Portal's 0 to 3
levels, and Hisingen converts between them. Unknown enum values and unsupported wire types stay
raw instead of becoming a known value. Decoded tags that no control uses appear on the Car tab under
"Unwired Backend Fields", and most `GetMyCars` tags now show under "Backend Reporting" instead.


## Volvo: what is read

| Endpoint | Shown in Hisingen as |
| --- | --- |
| `GET /connected-vehicle/v2/vehicles` and `/{vin}` | Vehicle list, model, year, colour, gearbox, fuel type, battery capacity, car renders |
| `GET /energy/v2/vehicles/{vin}/state` | State of charge, range, charging status and type, connector state, power, current limit, target, time to target |
| `GET /energy/v2/vehicles/{vin}/capabilities` | Which energy fields the car supports. Cached for one hour |
| `GET /connected-vehicle/v2/vehicles/{vin}/doors`, `/windows` | Central lock, doors, hood, tailgate, charge lid, windows, sunroof |
| `.../tyres` | Per-wheel tyre warnings. The API gives no pressure values |
| `.../diagnostics`, `.../engine`, `.../brakes` | Service warning, days and distance to service, fluid warnings, brake fluid warning |
| `.../warnings` | Individual lamp warnings, combined into one exterior-light warning |
| `.../odometer`, `.../statistics` | Odometer, trip meters, average consumption and speed, distance to empty |
| `.../engine-status` | Whether the engine is running |
| `.../command-accessibility` | Whether commands can be delivered now, and why not (no internet, power saving, car in use) |
| `.../commands` | The exact commands this VIN supports |
| `GET /location/v1/vehicles/{vin}/location` | Position and heading. Needs the Location API product and approved permissions on your developer application |

Fuel is read for combustion and hybrid cars. Energy endpoints are read for any car that reports
charging data, even when `fuelType` is `NONE`.


## Volvo: which call carries each command

All commands are `POST /connected-vehicle/v2/vehicles/{vin}/commands/{action}`.

| Command | Action |
| --- | --- |
| Lock | `lock` |
| Lock, reduced guard | `lock-reduced-guard` |
| Unlock | `unlock` |
| Start, stop climate | `climatization-start`, `climatization-stop` |
| Honk and flash | `honk-flash` |
| Flash | `flash` |
| Honk | `honk` |
| Start engine | `engine-start` (a runtime of 1 to 15 minutes) |
| Stop engine | `engine-stop` |

Commands are throttled to one every 6 seconds to stay inside Volvo's limit of 10 requests a
minute. Every documented failure value maps to a specific message, and a sleeping car is described
as retryable. Everything not in this table is not available through the public API.


## How a control gets enabled

Hisingen separates what it knows how to request, what a model is expected to support, and what
the provider reports for this exact car. A control appears only when all three allow it. The
per-VIN signal is the `GetMyCars` record on Polestar and the `/commands` and energy capability
lists on Volvo. Missing information is never turned into "closed", "locked" or "no update".
