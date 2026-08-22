# Changelog

All notable changes to Hisingen are documented in this file. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
