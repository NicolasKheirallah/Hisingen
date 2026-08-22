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
- `currentRangeVsModelWltpPercent(specification:)` — a range comparison against static model-family reference data, or a VIN-specific `VehicleSpecificationOverride` when one exists (see below), computed for any model with a non-zero reference entry in `VehicleModelFamily`'s tables (`hasModelReferenceSpecs`) — Polestar and the Volvo BEVs that have verified numbers.
- `stateSummary: VehicleStateSummary` — the single most-important-thing-to-show string, prioritized: alarm triggered > low battery (≤15%, not charging) > openings needing attention > unlocked > charging fault > service warning > fluid warning > health warning > tyre warning > actionable software failure > unavailable > engine running/secured > neutral "no active warnings reported".
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

## Current Range vs Model WLTP

`VehicleState.currentRangeVsModelWltpPercent(specification:)` — compares the currently reported range at the currently reported SOC with a WLTP reference at the same SOC: a VIN-specific `VehicleSpecificationOverride.wltpRangeKm` entered in Settings when one exists, otherwise `VehicleModelFamily.nominalWltpRangeKm` for any model where `hasModelReferenceSpecs` is true. It is shown as a direct percentage without a health score or qualitative rating. It is not measured battery State of Health; weather, tyres, speed, terrain, HVAC, vehicle variant and recent driving can all change it. Requires `batteryPercentage >= 20` — below that the vehicle's own range readout is too noisy to be a useful denominator.

`VehicleModelFamily.hasModelReferenceSpecs` is model-driven, not brand-driven: it's true wherever `nominalWltpRangeKm` and `nominalUsableCapacityKwh` are both non-zero. That covers every Polestar model plus the Volvo BEVs with verified numbers in the same table (XC40, EX40, C40, EC40, EX30, EX90, ES90); it's false for Volvo ICE/PHEV/unrecognized models, which have no BEV reference data to compare against.

## Battery Health & SoH (Calculated)

`BatteryHealthEstimator.estimate(state:chargingSessions:specification:previous:now:)` (`Domain/BatteryHealthEstimator.swift`) — a weighted blend of up to four independent signals, each individually bounded and only included when its inputs are available:

- **Charge-power integration** (base weight 0.55, the strongest signal) — trapezoidal-integrates observed `ChargingSample.powerWatts` over time across recent sessions, applies a charging-type-specific loss factor (AC ≈0.88, DC ≈0.97, unknown ≈0.90 — AC still passes through the onboard charger; DC mostly bypasses it), divides by the SOC gained, and takes the median across qualifying sessions. The signal's actual weight scales down from that 0.55 ceiling when fewer sessions qualify or when they disagree with each other (`sessionConfidence` × `agreementConfidence`), so one noisy session doesn't carry the same trust as five consistent ones.
- **Range versus model/VIN reference** (weight 0.20) — compares reported range at the reported SOC against a temperature-corrected expected range. The temperature correction only applies when `VehicleWeather.timestamp` is within a few hours of the range reading it's meant to explain, so a stale weather-vs-range pairing falls back to the temperature-unknown default instead of misapplying it.
- **Long-term consumption** (weight 0.10) — compares `BatteryDiagnostics.averageConsumption` against the model's reference Wh/km. Volvo's value is confirmed kWh/100km (the API tags its own unit); Polestar's is an unlabeled raw gRPC double with no independently verified unit, so a 5–60 kWh/100km plausibility band exists specifically to degrade a possible unit mismatch to "signal skipped" rather than silently corrupting the blend.
- **Age/mileage prior** (weight 0.15 baseline) — a conservative fleet-style fallback, explicitly not vehicle telemetry. Its weight is a true Bayesian-style prior: it carries more (up to 0.35) when it's the only signal available and steps aside toward 0.15 as real telemetry-backed signals accumulate.

Reference capacity prefers, in order: a user-entered VIN-specific `VehicleSpecificationOverride`, then the provider's own reported pack spec (`VehicleState.reportedBatteryCapacityKwh` — exact for that VIN on Volvo), then the generic per-model-family table (which can't distinguish Standard Range/Long Range trims).

**Temporal smoothing**: each fresh calculation is blended toward the most recent `battery_health_history` row (`BatteryHealthPriorEstimate`) rather than standing entirely on its own — a battery can't meaningfully change SoH between two polls minutes apart, so refresh-to-refresh noise shouldn't visibly move the number. How much a new reading is trusted over the prior scales with confidence (high 0.6 / medium 0.4 / low 0.25 blend weight toward the new value). A prior older than 14 days is treated as a cold start rather than an anchor, since real degradation could plausibly have happened in that window. Both `VehicleStateStore.save` (the persisted path) and `InfoTabView`'s battery health card read the same last-stored row, so the displayed number matches what gets written to history.

Every SoH surface labels this as a calculated estimate, never a BMS measurement — see `BatteryHealthEstimate.methodologySummary` and [domain/charging.md](charging.md).

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
