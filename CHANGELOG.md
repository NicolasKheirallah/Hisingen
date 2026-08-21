# Changelog

All notable changes to Hisingen are documented in this file. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-08-21

### Added

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
- Added regression coverage for provider warning provenance, software-event
  dismissal, unit formatting, Volvo engine decoding, and model-reference range
  comparisons.

### Changed

- Reworked the Polestar 2 and Polestar 4 vehicle presentation, perspective
  selection, door/opening highlighting, and menu-bar status presentation.
- Replaced the ambiguous unlocked padlock with a clearly differentiated open
  lock symbol and stronger unlocked-state styling.
- Climate and weather text now respects the selected temperature unit, wraps
  within the available viewport, and exposes the complete value through help
  text where appropriate.
- Vehicle distance, trip, range, pressure, and temperature formatting now use
  the selected application units consistently.
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
