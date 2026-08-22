# Changelog

All notable changes to Hisingen are documented in this file. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] - 2026-08-22

### Fixed

- Added fallback code signing and packaging in the release workflow when Apple Developer ID certificates are not configured.
- Defaulted the Polestar public render-CDN key in `Scripts/inject-secrets.sh` to the documented public AppSync key.
- Updated all GitHub Actions workflow pins to their latest verified immutable commit SHAs.
- Added notification quick actions: an evening-unlocked banner offers a Lock
  button and an interrupted-charging banner offers Resume Schedule. Actions
  route through the same capability gates as the in-app controls and act only
  on the currently selected vehicle.
- Added a parameterized Set Charge Target shortcut intent and a Where Is My
  Car intent that returns the last reported position plus a map link from the
  local cache only, plus a matching hisingen://charge-target URL route.
- Added a custom date-range option to the History dashboard alongside the
  fixed 7-day/30-day/all periods.
- Added a projected next-service estimate combining the vehicle's own service
  countdowns with the observed km/day rate from odometer history.
- Added a full local-history JSON backup export (all tables, all vehicles)
  in Settings → Storage; coordinates are included only when location history
  is opted in, and there is deliberately no import path.
- Added per-session raw-sample CSV export for charging curves.
- Telemetry rows now record whether a consumption figure is kWh/100 km or
  L/100 km, so combustion history can never be misread as energy data going
  forward.
- Polling now stretches to a 15-minute floor while the vehicle reports itself
  unavailable (asleep/power-saving), returning to normal cadence on wake.
- Added a Connectivity & Wake card: why the car is currently awake, network
  and signal level, a signal-history sparkline, and recent wake reasons —
  built from locally recorded connectivity samples (Polestar platforms).
- Added a cabin temperature trend chart for digital-twin climate platforms,
  with dashed setpoint overlay; hidden on vehicles that never report it.
- Menu bar charging countdown now targets the configured charge level
  ("72→80 · 25m") instead of always counting down to 100 %.
- Added an estimated lifetime charging cost per distance figure to the History
  overview, clearly labeled as estimated.
- Charge-location rows now name their optimised-charging mode (intelligent
  timer vs price-optimised) when the backend reports one.
- Added a Max Heat preconditioning macro (30 °C setpoint) alongside the
  temperature slider on platforms that accept explicit temperatures. The
  backend exposes no dedicated defroster field, so this is honestly labeled
  as heat rather than defrost.
- Added Screenshot Privacy Mode (Settings → Appearance): VIN, plate, and
  coordinates render as placeholders across the app while enabled, so shared
  screenshots stay safe.
- Vehicle state is now surfaced in system Spotlight: searching the car's
  nickname shows battery/range/charging at a glance; entries are wiped on
  sign-out and contain no VIN.
- Chart colors now follow theme tokens instead of hardcoded hues, keeping
  multi-series cards readable under monochrome themes.
- Added amp-limit preset chips (6/8/10/13/16 A) beside the charging-current
  slider; presets outside the vehicle's advertised range are hidden.
- Added a floating always-on-top charging mini-panel (optional, in Settings →
  Appearance) showing SoC→target, power, and ETA without activating Hisingen;
  position is remembered and it closes on unplug.
- Charging detail rows on the Charging card can now be reordered from
  Settings; unlisted rows keep their default position, so a partial order is
  safe.
- Vehicle nicknames now appear in notifications and Shortcuts responses
  instead of the generic brand name (Spotlight already used them).
- Completed sessions at a named location whose peak power falls far below that
  location's own norm trigger an "unusually slow charging" notice — a failing
  cable or derated charger hint. Requires three comparable prior sessions, so
  first visits never fire it.
- Hybrid and combustion owners can log fuel fill-ups locally (volume, price,
  odometer); fill-ups are included in lifetime cost-per-distance so PHEV and
  ICE economics are complete rather than silently electric-only.
- The parking-location card now resolves a street address via reverse
  geocoding, with GPS coordinates kept below as the precise fallback. Both
  respect Screenshot Privacy Mode.

## [1.2.0] - 2026-08-22

### Added

- Added a dedicated History dashboard with 7-day, 30-day, and all-time views,
  locally inferred and grouped journeys, distance charts, charging trends,
  command outcomes, summary metrics, optional map endpoints, and trip CSV export.
- Added persistent Polestar server-streaming gRPC connections for battery and
  exterior changes, with visible connection state, exponential reconnect, and
  scheduled polling retained as a reliability fallback.
- Added background refresh for every authenticated Polestar and Volvo account
  so the unified Garage contains current multi-provider vehicle snapshots rather
  than only a cached vehicle from the inactive provider.
- Added a transparent calculated battery State of Health estimate using observed
  charging-power integration, current range, long-term consumption, age, and
  mileage signals. Every SoH surface and export identifies it as calculated—not
  a BMS measurement—and reports signal weights and confidence.
- Added VIN-specific usable-capacity and WLTP references in Settings for exact
  vehicle variants; user-entered references are visibly distinguished from
  provider telemetry and static model-family data.
- Added Shortcuts for vehicle status, charging status, recent trip summaries,
  flashing lights, and honk-and-flash, plus provider-result waiting for command
  shortcuts and links to locally audited outcomes.
- Added complete information tooltips throughout the vehicle, diagnostics,
  charging, software, warranty, settings, and capability views.
- Added user-selectable pressure units, including PSI and kPa, alongside the
  existing distance and temperature preferences.
- Added a user-editable, VIN-scoped warranty in-service date for providers that
  do not supply verified warranty dates.
- Added local dismissal and restoration for stale vehicle-software failure
  events without claiming that the event was cleared on the vehicle.
- Added explicit data-provenance tracking for tyre, fluid, exterior-light, and
  low-voltage-battery warnings.
- Added Volvo engine diagnostics and explicit running/stopped state handling.
- Added redacted API diagnostic export and expanded diagnostic controls for
  investigating provider compatibility without exposing credentials or vehicle
  identifiers.
- Added neutral unavailable gauges and widget states for missing energy data.
- Added official Volvo Energy API v2 field/unit decoding, nested capability parsing,
  charging type and charger-power state, mileage normalization, altitude, and
  command-accessibility reasons.
- Added exact Volvo per-VIN remote-command capability probing and reduced-guard
  locking, engine start/stop, standalone honk, staged-unlock handling, and
  opt-in approval-gated OAuth scopes.
- Added real Apple Shortcuts handoffs for supported Volvo lock, authenticated
  unlock, and climate commands; shortcuts no longer claim success before a
  provider command is sent.
- Added local remote-command auditing with provider outcome, failure detail,
  duration, and recent activity display.
- Added typed drive-history retrieval and an activity summary in Vehicle Info.
- Added per-vehicle CSV exports for drive telemetry and remote-command audits.
- Added electric-consumption units for kWh/100 km, kWh/100 mi, and mi/kWh.
- Added configurable notifications for doors/windows left open, upcoming
  service, stale telemetry, and unusually slow charging.
- Added explicit last-known-data category and source-age labels when a partial
  provider refresh retains older values.
- Added an opt-in precise-location history preference; historical coordinates
  and charging-location labels are excluded by default.
- Added a unified Garage summary for cached vehicles across both provider
  accounts, with one-click same-brand selection and cross-brand switching.
- Added regression coverage for provider warning provenance, software-event
  dismissal, unit formatting, Volvo engine decoding, and model-reference range
  comparisons.
- Added a local cabin air-quality history: samples are recorded during normal
  refreshes, a trend chart appears on the CleanZone card, and history is
  exportable to CSV alongside the existing charging, battery-health, trip, and
  command exports.
- Added notifications for the software-update states between "available" and
  "completed"—scheduled, downloading, and installing—so a pending install
  isn't silent.
- Added a Settings toggle for the low-battery plug-in reminder notification,
  which previously fired by default with no way to see or disable it.
- Added automatic retention for charging-session, battery-health, and
  remote-command-audit history (previously only charging samples and drive
  telemetry were ever pruned, manually).
- Added a browser-based sign-in for authorizing Polestar remote commands
  ("Authorize Remote Commands" in Settings), separate from the account
  sign-in.
- Added ADR-0010 documenting why biometric confirmation defaults off for
  routine remote commands.
- Added Polestar saved charge-location management: create a location at the
  car's current position, rename it, set its per-location charging-current
  limit and minimum charge level, toggle optimised charging, and delete it,
  all through the vehicle's own Chronos charge-location service with wire
  shapes cross-checked against independent implementations. Controls appear
  only after a fetch returns locations, so unverified platforms show nothing
  rather than controls that may not exist.
- Expanded the History dashboard with charging-curve drill-down (charge level,
  power, voltage, and current traces with session picker), 10–80% charge-time
  estimation, idle-tail detection, charging-loss and tariff-aware cost
  estimates, energy-by-time-of-day breakdown, seasonal efficiency split,
  monthly mileage buckets, battery-health slope and next-10,000 km projection,
  remote-command success statistics, data-coverage confidence labels, an air
  quality trend card, and CSV exports for air quality, telemetry, battery
  health, and charging sessions alongside trips.
- Added ADR-0011 documenting the two-OAuth-client constraints behind Polestar
  sign-in: why the telemetry client cannot use a standards-compliant browser
  handoff today, what would trigger redesigning it, and why the password path
  is treated as accepted risk rather than silently carried.

### Changed

- Trip persistence now supports combustion, hybrid, and electric vehicles and
  groups adjacent movement samples into journeys separated by parked periods.
- Calculated SoH milestones now use explicit `calculated-v2` provenance; older
  inferred rows are migrated to `legacy-estimate` instead of being mislabeled
  as measured data.
- Charging-energy estimates now honor the same VIN-specific usable-capacity
  reference used by the SoH calculation.
- Condensed the five-tab navigation and added a live-stream status indicator to
  keep the expanded dashboard readable within the menu-bar popover.
- Reworked the Polestar 2 and Polestar 4 vehicle presentation, perspective
  selection, door/opening highlighting, and menu-bar status presentation.
- Replaced the ambiguous unlocked padlock with a clearly differentiated open
  lock symbol and stronger unlocked-state styling.
- Climate and weather text now respects the selected temperature unit, wraps
  within the available viewport, and exposes the complete value through help
  text where appropriate.
- Vehicle distance, trip, range, pressure, and temperature formatting now use
  the selected application units consistently.
- Volvo remote controls now derive support from the official command-list
  endpoint instead of model-wide assumptions.
- Volvo charging power now honors the API's watts unit rather than treating
  every value as kilowatts, while legacy kW payloads remain compatible.
- Renamed the misleading `Body Style` door count to `Door Sensors Reported`.
- Charging current draw and the configured charging-current limit are now
  represented separately.
- Charge target and current-limit controls now wait for provider values instead
  of presenting invented defaults.
- Climate temperature in Controls is now identified as a saved
  preconditioning command setpoint rather than live cabin telemetry.
- Battery capacity and WLTP figures are now labeled as provider-reported or
  model-reference specifications as applicable.
- Replaced the misleading Range Efficiency health rating with the factual
  `Current Range vs Model WLTP` comparison.
- Charging-session energy is now labeled as estimated when derived from SOC and
  model-reference capacity.
- Capability inspection now distinguishes `not reported` from `not supported`.
- Software fields from undocumented Polestar responses are labeled as
  backend-reported and unverified instead of authoritative installed versions.
- Updated the product website, design documentation, screenshots, and gallery
  asset names to match the current interface.
- Authorizing Polestar remote commands now happens through a real browser
  sign-in instead of Hisingen submitting the account password to the login
  form itself; the previous silent password-based re-authorization path was
  removed, so a signed-out command session now requires a one-time browser
  step rather than resolving itself invisibly.
- The battery-pack description shown in Vehicle Info now derives its kWh
  figures from the same computed capacity values shown elsewhere in the app,
  instead of separately hardcoded numbers that could drift out of sync with
  them.
- Volvo's tyre-status card now explains that Volvo reports a warning level
  per tyre rather than an exact pressure reading, matching what the API
  actually returns.

### Fixed

- Fixed truncated Climate & Timers and ambient-weather content.
- Fixed information icons that had no hover help or click behavior.
- Fixed warranty cards fabricating expired coverage from inaccurate assumed
  in-service dates.
- Fixed stale or ambiguous software-update events appearing as an active vehicle
  failure indefinitely.
- Fixed doors, windows, charge lids, and other openings being counted together
  as the vehicle's body-style door count.
- Fixed mirrored or out-of-view doors sharing indistinguishable hover
  highlights in the vehicle visualization.
- Fixed Auto Trip and other vehicle distances bypassing the selected distance
  unit.
- Fixed missing tyre responses being synthesized as four healthy tyres.
- Fixed absent fluid, lighting, low-voltage-battery, AQI, CleanZone, fuel,
  climate, engine, battery, and tyre data being displayed as healthy, zero, or
  another fabricated value.
- Fixed Volvo engine status treating every unknown response as stopped.
- Fixed Volvo fuel percentage estimation assuming a 60-litre tank.
- Fixed Polestar charging-current limits being shown as live current draw.
- Fixed widget snapshots showing a missing battery percentage as 0%.
- Fixed model-year, battery-capacity, warranty-distance, charge-target, and
  notification fallbacks that could leak invented numeric values into the UI.
- Fixed duplicate calculated charging rows and removed unsupported battery
  degradation and range-health claims.
- Fixed tyre-pressure warnings never reaching the general vehicle-warnings
  notification—a flagged tyre was already visible in the app but had no
  path into the notification the same warning class otherwise fires.
- Fixed a self-contradicting Polestar 4 battery-pack description that stated
  two different capacities ("100.0 kWh" and "102 kWh") in the same sentence.
- Fixed climate-timer editing being unreachable in practice: only
  delete-then-recreate worked despite an "Edit Schedule" label in the UI.
- Fixed signing out of a vehicle leaving orphaned charging-sample and
  remote-command-audit rows behind instead of clearing them with the rest of
  that vehicle's local data.
- Fixed a shared HTTP-response-reading utility always throwing Polestar's
  error type, even on the Volvo request path, which meant a Volvo-specific
  `catch` for a too-large or network-failed response could never match.
- Fixed the Settings "Test Connection" button reporting success and a
  latency figure without making any network request.
- Fixed the Polestar gRPC charging-state field being decoded by reading the
  raw wire value as a position in a hardcoded array instead of matching it
  explicitly; a future backend change that inserts or reorders a case could
  have silently relabelled a known charging state as the wrong one.
- Fixed Volvo's "Direct tyre-pressure values" capability showing as
  perpetually "backend dependent" instead of a definitive unavailable —
  Volvo's tyre API is indirect (inferred from wheel-speed-sensor imbalance)
  and has no numeric-pressure field on any model, so this can never resolve
  through a live probe and belongs in the static baseline. Tyre *warning*
  status (OK/low/very low/high) is unaffected and remains fully supported.
- Fixed Polestar 2 tyre pressures being hard-blocked as permanently
  unavailable off a single reference-car capture: the capability now probes at
  runtime, and the health parser scans neighbouring protobuf fields for a
  coherent pressure quadruple when the documented positions are empty, so
  firmware or model-year variants that report values elsewhere start working
  without an app update. The capability matrix also explains the difference
  between numeric kPa readings and warning-level indirect TPMS.
- Fixed signing out leaving Polestar session-scoped caches behind — OTA
  software ids and states, vehicle-advertised charging limits, and cached
  exterior snapshots survived into the next account sign-in on the same Mac,
  potentially mixing one account's vehicle state into another's.
- Fixed charge-target and charging-current commands being validated against
  hardcoded ranges instead of the bounds the vehicle itself advertises;
  rejections now name the vehicle-specific limit rather than failing opaquely
  server-side.
- Fixed combustion vehicles' fuel consumption (litres/100 km) being formatted
  as electric consumption (kWh/100 km) in detected-trip lists.

### Removed

- Removed an unused widget scaffold that compiled but had no widget extension
  target, so it could never appear in macOS's widget gallery; it only read as
  a shipped feature while doing nothing.

### Security and CI

- Repaired Swift CodeQL builds by removing incompatible whole-module
  optimization from the manually traced build.
- Upgraded CodeQL, Dependency Review, Pages, Node setup, artifact, checkout,
  cache, and provenance actions to current immutable commit pins.
- Added one shared Xcode-selection script across CI, security, live integration,
  and release jobs to avoid runner-image/toolchain drift.
- Hardened Volvo build-secret generation so credentials are passed to Python via
  the process environment rather than interpolated into executable source.
- Migrated the Polestar account email from cleartext `UserDefaults` storage to
  a device-only Keychain item, including safe migration of existing installs.
- Rebuilt Apple Maps and Open-Meteo coordinate URLs with explicit HTTPS URL
  components, resolving the open CodeQL cleartext-transmission findings.
- Added workflow linting, shell linting, deterministic test/build validation,
  release artifact checksum verification, immutable action pins, restricted
  token permissions, and non-persistent checkout credentials throughout CI.
- Hardened release preparation with strict semantic-version validation,
  monotonic version checks, required changelog entries, explicitly dispatched
  CI/security validation for release pull requests, notarization validation,
  and build-provenance attestations.
- Moved the Polestar public vehicle-image API key out of a plaintext source
  constant into the same build-time-injected, obfuscated pattern already
  used for the Volvo developer secrets, with a working built-in default so
  vehicle images function without any configuration.
- Documented the actual Keychain accessibility level in ADR-0004 (it
  previously stated a stricter level than the implementation has ever used).
