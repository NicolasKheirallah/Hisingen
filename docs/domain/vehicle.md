# Vehicle Domain Model

`Sources/Hisingen/Domain/` — brand-agnostic types both providers produce and everything else consumes. All value types (`struct`/`enum`), `Codable`, `Sendable`.

## `VehicleState` — the central model

`VehicleDomainTypes.swift` / `VehicleState.swift`. One flat struct carrying everything the UI can show: identity (`vin`, `modelName`, `modelYear`, `registrationNo`), charging (`batteryPercentage`, `rangeKm`, `chargingState`, `chargingPowerWatts`, `chargingCurrentAmps`, `chargingVoltageVolts`, `chargeTargetPercentage`, `estimatedChargingTimeToFullMinutes`, `chargingType`, `chargerConnection`), availability (`availability: VehicleAvailability`), exterior (`exteriorStatus: ExteriorSnapshot?`), health (`healthDetails: VehicleHealthDetails?`, `daysToService`, `distanceToServiceKm`, `serviceWarning`, `fluidWarnings`), software (`softwareInfo`), schedules (`chargingSchedules`, `climateTimers`), climate (`climateStatus`), trip meters, connectivity, air quality, battery diagnostics, weather, location, powertrain (BEV/PHEV/ICE/mild-hybrid + `fuelLevelPercent`/`fuelRangeKm`), plus bookkeeping: `unavailableFeatures: [AppFeature]`, `probedCapabilities: VehicleProbedCapabilities?`, `chargingSamples`/`chargingSessions`, `imageData`, `fetchedAt`, `vehicleReportedAt`, `dataWarnings`.

Every optional field is genuinely `Optional` — a missing value is `nil`, never a fabricated `0` or empty string. See [architecture/data-flow.md](../architecture/data-flow.md#data-merging).

Key computed properties:
- `isCharging` — `chargingState.isActivelyCharging` (`.charging` or `.smartCharging`).
- `isComplete` — `chargingState == .complete`, or battery% within 0.5 of target, or ≥99.5% with no target set.
- `isStale(at:)` / `dataTimestamp` / `freshnessDescription` — see [freshness in data-flow.md](../architecture/data-flow.md#freshness).
- `capabilityProfile: VehicleCapabilityProfile` — built on demand from `modelName`, `vin`, and `probedCapabilities`.
- `estimatedRangeHealth` — a range-based health estimate (see below), only computed for Polestar models with verified nominal specs.
- `stateSummary: VehicleStateSummary` — the single most-important-thing-to-show string, prioritized: alarm triggered > low battery (≤15%, not charging) > openings needing attention > unlocked > charging fault > service warning > fluid warning > health warning > tyre warning > software failure > unavailable > "no issues detected"/"secured".
- `cacheableCopy` — the version persisted to `VehicleStateStore`. Built by passing only a specific subset of fields (VIN, battery/charging/range, availability, model name/year, powertrain/fuel, capability observations, charging history, timestamps) into the initializer — every other field, including PII *and* location/exterior/lock status, is dropped by omission rather than an explicit strip list. See [architecture/persistence.md](../architecture/persistence.md).
- `mergingLastKnown(from:features:)` — see [architecture/data-flow.md#data-merging](../architecture/data-flow.md#data-merging).

## Identity: `VehicleModelFamily`

An enum with a case per known model (`.polestar1`...`.polestar6`, `.volvoXC40`, `.volvoEX40`, `.volvoC40`, `.volvoEC40`, `.volvoXC60`...`.volvoES90`) plus `.volvoUnknown(String?)` and `.unknown(String?)` — both preserve the original model-name string rather than discarding it, so a future/unrecognized model still displays something meaningful instead of "Unknown model."

`init(modelName:vin:)` tries, in order: a VIN-prefix heuristic for Polestar (`YSM` WMI + the 4th character identifies P2 through P6), VIN-prefix detection for Volvo (`YV1`, `YV4`, `LVY`), then normalized substring matching on the model name for both brands (`ex40` → `.volvoEX40`, `xc40` → `.volvoXC40`, `c40` → `.volvoC40`, `ec40` → `.volvoEC40`, `ex30` → `.volvoEX30`, `ex90` → `.volvoEX90`).

### Model Capability Adaptation Matrix

| Vehicle Platform / Model | Remote Start/Stop | Target Temp Stepper | Seat / Wheel Heating | Locks & Security | Honk & Flash | Remote Charging Write |
|---|---|---|---|---|---|---|
| **Volvo XC40 / EX40 / C40 / EC40** | ✅ Supported | ❌ Hidden (Preset) | ❌ Hidden (Preset) | ✅ Supported | ✅ Supported | ❌ Hidden (Read-Only) |
| **Volvo XC60 / XC90 / S60 / V60 / V90** | ✅ Supported | ❌ Hidden (Preset) | ❌ Hidden (Preset) | ✅ Supported | ✅ Supported | ❌ Hidden (Read-Only) |
| **Volvo EX30 / EX90 / ES90** (SPA2/SEA) | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ⏳ Backend Dependent |
| **Polestar 2** (CMA) | ✅ Supported | ❌ Hidden (Preset) | ❌ Hidden (Preset) | ✅ Supported | ❌ Restricted | ❌ Restricted |
| **Polestar 3 / Polestar 4** (SPA2/SEA) | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ❌ Restricted | ❌ Restricted |

In `ControlsTabView.swift`, cards adapt dynamically using `profile.hasSelectableClimateTemperature`, `profile.hasSelectableSeatHeating`, and `profile.permits(...)` so that unsupported controls (such as manual temperature inputs or seat toggles on XC40/EX40/C40) are completely hidden, showing clean active status banners instead.

## `PowertrainType`

`.bev`, `.phev`, `.ice`, `.mildHybrid`, `.unknown` — drives which range/fuel fields the UI shows (`hasElectricRange`/`hasFuelRange`).

## `AppFeature`

28 cases — one per independently-toggleable read-only capability group (`vehicleIdentity`, `chargingDetails`, `exteriorStatus`, `climateStatus`, `vehicleLocation`, ...) plus 8 `remote*` cases for command groups. `FeatureSelection` is the `Set<AppFeature>` wrapper stored in `Preferences`; its `.default` enables a conservative starter set (core telemetry, identity, image, charging, availability, health, exterior, tyres/warnings, software, climate, trip meters, battery diagnostics, location, multi-vehicle, notifications, update checks, and three low-risk remote features — climate, locks, honk/flash). Every optional GraphQL/REST/gRPC fetch in both providers is gated by whether its `AppFeature` is enabled, so disabling a feature genuinely stops the network call, not just the UI card.

## `RemoteCommand`

21 cases (`Domain/RemoteCommand.swift`) covering climate, pre-cleaning, locks, windows, honk/flash, charging (target/amp-limit/override), schedules, and OTA. Each case maps to:
- `feature: AppFeature` — which toggle gates it.
- `requiredCapability: VehicleCapability` — which capability `VehicleCapabilityProfile.permits(_:)` must allow.
- `risk: RemoteCommandRisk` — `.routine` (confirmation dialog only), `.securitySensitive` (`unlock`, `unlockTrunk`, `openWindows` — requires Touch ID/Mac password), `.destructive` (`installOTANow`, `deleteClimateTimer` — same authentication requirement).
- `adapted(to:)` — silently strips parameters the vehicle's capability profile says aren't selectable (e.g. a Polestar 2's vehicle-managed climate temperature gets reset to "unspecified" rather than sent).

Remote command dispatch is compiled into every build for both brands ([ADR-0009](../adr/0009-remote-commands-compiled-into-all-builds.md)); for Polestar only the OTA scheduler commands are reachable from the UI, and Volvo's are only partially implemented — see [api/polestar.md](../api/polestar.md#remote-commands) and [api/volvo.md](../api/volvo.md#remote-commands).

### Remote command optimistic updates

`AppDelegate.performRemoteCommand` patches `latest` in place for four commands (`startClimate`, `stopClimate`, `lock`, `unlock`) once `executeRemoteCommand` returns *any* result, including a merely-`.accepted` outcome — not waiting for the next real refresh to confirm the change. This is a UX choice (instant feedback rather than a multi-second wait for the lock icon to flip), documented here because it's easy to mistake for a bug when a command's outcome doesn't match what actually happened on the vehicle. See [architecture/technical-debt.md](../architecture/technical-debt.md#optimistic-local-state-patch-on-remote-commands-vs-ack-execution-stance).

## Range Health Estimate

`VehicleState.estimatedRangeHealth` — explicitly **not** a measured battery State of Health. It compares the currently reported range at the currently reported SOC against the model's nominal WLTP range at that same SOC, clamps the ratio to a plausible band (0.70–1.05), and maps that into an 80–99.5% "health" score with a qualitative rating (Excellent/Good/Normal/Degraded). Only computed when `battery > 10%` and the model has verified nominal specs (Polestar only). The app's own FAQ is explicit that this is range-based, not a real capacity measurement — weather, tyres, speed, terrain, HVAC, and recent driving all move it independently of actual battery health.

## Where types live

| Concept | File |
|---|---|
| `VehicleState`, `ChargingSession`, `ChargingSample` | `VehicleState.swift` |
| `CarSummary`, `ChargingState`, `ChargerConnection`, `ChargingType`, `VehicleAvailability` | `VehicleDomainTypes.swift` |
| `VehicleSchedule`, `VehicleOpening`, `OpeningState`, `ExteriorSnapshot`, `TyrePosition`, `TyrePressure`, `VehicleWarning`, `VehicleHealthDetails`, `SoftwareUpdateState`, `VehicleSoftwareInfo`, `ClimateActivity`, `VehicleClimateStatus`, `ConnectivityState`, `VehicleConnectivity`, `AirCleaningState`, `VehicleAirQuality`, `ChargerPowerState`, `BatteryDiagnostics`, `VehicleLocation`, `VehicleWeather` | `VehicleDomainTypes.swift` |
| `VehicleModelFamily`, `VehicleCapability`, `VehicleCapabilitySupport`, `FeatureAvailability`, `VehicleFeatureStatus`, `VehicleProbedCapabilities`, `VehicleCapabilityProfile` | `VehicleCapabilities.swift` |
| `VehicleBrand`, `PowertrainType` | `VehicleBrand.swift` |
| `AppFeature`, `FeatureSelection` | `AppFeature.swift` |
| `RemoteCommand`, `HeatingLevel`, `RemoteCommandRisk`, `RemoteCommandOutcome`, `RemoteCommandResult`, `RemoteCommandError` | `RemoteCommand.swift` |
