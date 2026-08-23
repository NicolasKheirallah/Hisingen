# Changelog

All notable changes to Hisingen are documented in this file. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.2] - 2026-08-23

### Added

- Selectable panel sizes for the menu bar dropdown (Settings → General →
  Panel Size): Compact, Standard, Large (tall), Wide, and Grand (wide & tall)
  presets control both the width and height of the popover. The choice is
  persisted, applied live while the panel is open — switching a preset
  resizes the dropdown instantly — and every view (dashboard, settings,
  sign-in) follows the selected width automatically.
- Content Density control beside Panel Size: zooms everything inside the
  dropdown independently of the window preset (Compact 85%, Standard 100%,
  Relaxed 115%). Because the content tree is laid out at the inverse scale
  and then scaled into place, a Grand panel at Compact density shows
  substantially more rows before scrolling instead of just stretching the
  same content larger.
- Custom Size overrides with independent width and height sliders (bounded,
  snapped to 10/20 pt steps), a Reset Sizes button, a proportional size
  preview against the Standard panel, and VoiceOver labels plus selected
  traits on every preset tile. All panel/density strings are localized in
  all sixteen languages.
- Quick switching without opening Settings: the status icon's right-click
  menu gained Panel Size and Content Density submenus with checkmarks on the
  active options; picking a preset there also clears any custom override.
- Responsive Wide/Grand layouts: mid-size vehicle cards flow two per row
  above a 500 pt width instead of stretching full-width one by one, and the
  hero car render grows up to +35 % with the extra width — including its
  decode budget, so larger renders stay sharp rather than upscaled.
- Card Layout setting (Settings → General) decides how those mid-size cards —
  tires/TPMS, vehicle location, fuel & engine, doors & openings — flow on
  wide panels: Full Width (default, every card spans the panel) or Two
  Columns (side by side). Applies live and is localized in all languages.
- Panel auto-close setting (Settings → General → Panel auto-close) chooses
  how the dropdown behaves when focus moves elsewhere: Keep Open Until
  Dismissed (the previous behavior — the panel stays until the menu bar icon
  is clicked again) or Close When Switching Apps (standard macOS popover
  behavior — any click outside, including another app taking focus, closes
  it). The choice applies live to an open panel, persists across launches,
  and defaults to Keep Open so upgrades change nothing; a click guard keeps
  the icon toggle from instantly reopening a panel macOS just auto-closed.
- Two new PanelCloseBehavior unit tests covering the default mapping and the
  transient/semitransient popover-behavior translation.
- Twelve new PanelLayout unit tests covering persistence round trips,
  fallbacks for corrupt values, custom-override clamping, the
  logical-times-scale = physical-width invariant, whole-point rounding, the
  screen-fit clamp with injected visible-frame heights, and the Card Layout
  default/round-trip.

- Regression coverage for same-account multi-vehicle selection, reproducing
  the original two-car switch lockup across vehicle chips, the switcher menu,
  keyboard cycling, and context-menu paths.

- Diagnostic log export (Settings → SQLite Storage & Data → Export Diagnostic
  Logs): bundles app/system metadata, the last 24 hours of Hisingen's own
  unified-log entries, the redacted API request history (now including gRPC
  status/message detail), refresh diagnostics with since-launch
  attempt/success/failure counters, recent remote-command audits, and database
  stats into a single versioned JSON file for bug reports. Vehicle identifiers,
  UUIDs, and credential-bearing substrings are replaced with placeholders before
  the file is written; only this process's logs are read, never other apps'.

- Every vehicle notification now names the car it is about: the vehicle's
  nickname (or brand fallback) appears in the banner subtitle across all
  alerts — charging events, warnings, security, software, service, and
  reminders — so multi-car households can tell banners apart at a glance.
- Notification sounds: urgent alerts (alarm triggered, vehicle warnings,
  rain with windows open, evening unlocked, openings left open) and charging
  problems now play a sound; routine informational banners stay silent. A
  "Notification Sounds" toggle in Settings → Notifications controls all of it.
- Quiet Hours (Settings → Notifications): hold non-urgent notifications
  during a configurable window (default 22:00–07:00) and deliver them when
  the window ends instead of dropping them; security-class alerts always
  break through.
- Per-vehicle muting ("Mute This Vehicle" for the active car): silenced
  vehicles keep their baselines advancing so un-muting never replays a burst
  of stale edge events, and lingering sustained timers are cleared on mute.
- New event types: charge-cable connect/disconnect confirmations and cabin
  climate start/stop notices, each with its own toggle.
- Tapping a notification banner now opens Hisingen focused on the tapped
  vehicle — switching brands first when the VIN belongs to the dormant
  account — instead of just bringing the app forward wherever it left off.
- Optional dock warning badge ("Warning Badge"): shows the number of vehicles
  currently reporting warnings or a triggered alarm while enabled.
- "Send Test Notification" button in Settings → Notifications renders a real
  sample banner honoring privacy mode, sounds, quiet hours, and the subtitle.
- A master "Notifications" feature toggle now sits at the top of the
  notification settings card; previously the flag was only reachable by
  re-picking a feature preset.
- All new notification copy is localized in Swedish and German; other
  languages fall back to English until translated.
- Notification posting logic is now unit-testable: the notifier talks to
  UserNotifications through an injectable dispatcher, and ten new tests cover
  posting paths that previously had no coverage — subtitle inclusion,
  privacy-mode bodies, service-due and sustained-latch persistence across
  relaunches, muted vehicles still advancing baselines, quiet-hours deferral
  with urgent bypass, warning-count callbacks, quiet-hour edge cases,
  frontmost-app presentation, thread-to-VIN parsing, and the fingerprint
  history including legacy-baseline migration.

### Changed

- Panel geometry now resolves through a single PanelLayout source: preset,
  custom override, density zoom, whole-point rounding, and the screen-fit
  clamp live in one testable place, so the popover window, the SwiftUI
  frames, and readouts can never disagree. Heights are clamped to what fits
  below the menu bar, which stops silent bottom-edge clipping of tall panels
  on small displays.
- The dropdown's SwiftUI tree reads panel settings via AppStorage, so preset,
  custom-slider, and density changes invalidate natively and resize with a
  short animation instead of waiting for the refresh round trip — scroll
  positions and disclosure state survive resizes.
- The floating charging mini-panel follows the dropdown's Content Density
  choice, and reopening it applies the scaled width.
- Cabin-air button row height raised to match the other remote-command rows.
- Logging overhaul: every logger is now created through a single AppLog factory
  (CI-guarded), Polestar's category renamed `api` → `polestar-api`, remote-command
  execution and all previously-silent failure paths (command failures, sign-out
  revocation, live-stream drops, preference migration) now log with structured
  error detail instead of localizedDescription, and unrecoverable database
  failures use the `.fault` level. Server-supplied error strings are scrubbed
  before public logging. Refresh round trips — including initial session
  establishment — emit os_signpost intervals for Instruments.
- API diagnostic store: entries retained for 24 h / 2,000 records with a 32 MB
  cumulative payload budget so the archive stays bounded, persisted across
  relaunches (redacted data only, flushed on quit), timestamped at request start
  so exports correlate with the unified log, and error types now carry enum
  payloads and codes (`server(statusCode: 503)`) rather than bare type names.
  Update checks are recorded as first-party `.hisingen` traffic; CDN image
  fetches and Apple geocoding are deliberately excluded and documented as such.
- The old payload-only "Export Redacted API Data" button was replaced by the
  full diagnostic bundle export; the export UI is localized in all app languages.
- The default Hisingen Glass theme now renders as a true Apple Liquid Glass
  surface: the popover's opaque backing is cleared so its translucent material
  samples the real desktop and windows behind it rather than a solid panel,
  layered with a specular top-light wash and a soft amber-tinted vignette
  (a neutral dark falloff in dark mode). Frosted-material cards now read as
  raised glass layers floating over the see-through window. All other themes
  keep their opaque canvas.
- Tyre status presentation reworked to be honest about what the provider
  reported. The summary pill now distinguishes "Check Pressure", "Everything
  looks good", partial "No warnings reported", and "Data unavailable"; per-tyre
  pills combine a direct pressure reading with any warning level ("35.0 psi ·
  High"); colors follow the reported severity (red critically low, orange
  low/high, green explicitly OK, muted when unreported) instead of a binary
  warning flag; the vehicle outline rolls each axle up to the worst reported
  level rather than treating unknown as healthy; and the card title reflects
  whether the vehicle reports numeric pressures ("Tire Pressure") or only
  warning levels ("Tire Status (iTPMS)").
- README rebuilt around reader tasks: table of contents, FAQ, troubleshooting,
  known limitations, roadmap and non-goals, plus contribution and support
  sections, alongside an expanded Units list documenting every selectable unit.

- Urgency model for every notification: urgent banners post with the
  time-sensitive interruption level (and bypass Quiet Hours), background
  chatter such as stale telemetry, service due, slow charging, and software
  updates posts passively and silently, and charging problems get an audible
  active-level banner.
- While Hisingen is the frontmost app, routine banners now drop silently into
  the notification list instead of popping over the window; time-sensitive
  alerts still surface.
- Remote-command result notifications: successes still self-dismiss after
  five seconds, but failures persist until dismissed — and carry the active
  vehicle's name as their subtitle.
- Private notification mode keeps bodies anonymous now that subtitles identify
  the car: charging banners read "Started charging." / "Finished charging."
  instead of repeating the vehicle name, and low-battery/unlocked/plug-in
  copy follows suit.
- Software-update failure and installing banners include the version string
  when the provider reports one.
- The resume-schedule quick action on charging-interrupted banners now
  requires device unlock, matching the lock action's gate on write commands.
- Sustained conditions (openings left open, slow charging) are re-evaluated
  by a lightweight timer, so a car parked open still escalates even if the
  telemetry polling loop stalls.

### Fixed

- Opening the dropdown no longer uses a stale size after the panel preset was
  changed externally while the popover was closed: geometry is re-resolved on
  every open.
- Switching between two vehicles on the same brand account no longer locks the
  switcher after one use. The visible active-car marker synced only from
  session-level events while the coordinator compared its own stored VIN, so
  the two guards vetoed every follow-up switch in opposite directions;
  selection idempotence now lives in one place, the marker follows user intent
  immediately, a failed or raced selection retries briefly instead of parking a
  signed-in user on "Open Settings to sign in.", each user-initiated attempt
  gets a fresh retry budget rather than inheriting an exhausted one, and an
  unresolved switch is reported as `vehicleSwitchPending` in exported
  diagnostic bundles so support data can distinguish a pending switch from an
  idle app.
- Polestar vehicle identity is now stored per VIN instead of on the shared
  "currently selected car" slot. Model name, model year, registration number,
  paint, upholstery, wheels, packages, and render images are keyed by VIN, so
  telemetry for one car can no longer pick up another car's details while the
  background garage scan cycles through the account's vehicles. The race-prone
  selected-car post-check and its cached-discovery recovery shim became
  unnecessary and were removed with it.
- Polestar remote commands no longer require the target vehicle to be the
  currently selected one. The background garage scan temporarily re-points the
  shared selection while refreshing other vehicles, which could make a valid
  lock or climate command fail with "missing context" mid-scan; commands
  address their vehicle explicitly by VIN and now only check that it belongs
  to the signed-in account.
- A scheduled session-retry timer that fired while another request was still
  in flight no longer disappears silently. Direct triggers (launch, wake,
  network restore, manual refresh) keep yielding to in-flight work, which
  rearms itself; the timer path now retries shortly instead of dropping the
  attempt, where previously one busy request could stop all automatic session
  recovery until the next manual interaction.
- The background garage scan no longer races manual vehicle switching: it
  stands down if the user changes cars mid-scan (previously flipping the shared
  provider selection under an in-flight switch), restores the pre-scan
  selection only when it is still current, and skips scanning entirely while a
  refresh or rate-limit pause is active so interactive requests are never
  starved.
- North American units are now applied across the board. The start-climate
  confirmation and biometric prompts show the setpoint in the selected
  temperature unit (°F instead of a hardcoded °C), the History dashboard's
  seasonal efficiency buckets relabel to °F thresholds, the cabin temperature
  trend chart converts plotted values and labels its axis, average trip speeds
  show mph when miles is selected, and the Info tab's Fuel Level and Average
  Consumption rows honor the gallon and MPG selections. README's Units list
  documents every selectable unit including Fahrenheit and PSI.
- Polestar 2 tyre status no longer sticks on "Unknown" while the car is
  healthy. The backend omits proto3 zero/unset values, so an all-clear health
  report carries explicit 1s for every other category (fluids, lights, 12 V)
  while the tyre-warning quadruple is absent entirely — which parsed as
  unknown and kept the tyre card at "Unknown" forever. Within such a
  substantive payload, missing tyre fields now read as "no warning", verified
  against a live vehicle; empty or truncated payloads still stay unknown,
  guarded by a regression test built from the live capture.
- Enabling only some notification toggles no longer skips requesting system
  permission: five toggles (openings left open, service due, stale telemetry,
  slow charging, plug-in reminder) were missing from the authorization check,
  leaving users who picked just those with silent, never-delivered alerts.
- The service-due banner no longer refires after every relaunch while the
  condition persists: the was-due state is persisted per VIN rather than kept
  only in memory.
- "Vehicle left open" and stale-telemetry latches survive relaunches, so a
  restart mid-condition no longer duplicates the banner.
- Charging-transition deduplication keeps a short fingerprint history instead
  of a single slot: two events emitted by one evaluation (e.g. fault plus
  low battery) previously overwrote each other's fingerprint, letting a
  replayed sample double-post the first event. Existing persisted baselines
  migrate losslessly.
- The account sign-in-required notice no longer suppresses the other brand's
  notice (the latch is per brand), always names the account that failed, and
  groups under its own thread.
- The charging-anomaly banner respects private notification mode: location
  names were previously posted in plain text regardless of the setting.
- v1→v2 preference migration carries the `.notifications` feature flag
  forward; upgrading installs could silently lose all alerts otherwise.
- Battery-percentage text in banners formats through the selected locale.

## [1.2.1] - 2026-08-22

### Added

- Notification quick actions: an evening-unlocked banner offers a Lock button
  and an interrupted-charging banner offers Resume Schedule. Actions route
  through the same capability gates as the in-app controls and act only on
  the currently selected vehicle.
- A parameterized Set Charge Target shortcut intent and a Where Is My Car
  intent returning the last reported position plus a map link from local
  cache only, with a matching hisingen://charge-target URL route.
- Custom date-range option in the History dashboard alongside the fixed
  7-day/30-day/all periods.
- Projected next-service estimate combining the vehicle's own service
  countdowns with the observed km/day rate from odometer history.
- Full local-history JSON backup export (all tables, all vehicles) in
  Settings → Storage; coordinates included only when location history is
  opted in, with deliberately no import path.
- Per-session raw-sample CSV export for charging curves.
- Connectivity & Wake card: why the car is currently awake, network and
  signal level, a signal-history sparkline, and recent wake reasons — built
  from locally recorded connectivity samples (Polestar platforms).
- Cabin temperature trend chart for digital-twin climate platforms, with
  dashed setpoint overlay; hidden on vehicles that never report it.
- Estimated lifetime charging cost per distance in the History overview,
  clearly labeled as estimated.
- Optimised-charging mode names (intelligent timer vs price-optimised) on
  charge-location rows when the backend reports one.
- Max Heat preconditioning macro (30 °C setpoint) alongside the temperature
  slider on platforms accepting explicit temperatures. The backend exposes no
  dedicated defroster field, so this is honestly labeled as heat rather than
  defrost.
- Screenshot Privacy Mode (Settings → Appearance): VIN, plate, and
  coordinates render as placeholders across the app while enabled, so shared
  screenshots stay safe.
- System Spotlight publication of vehicle state: searching the car's nickname
  shows battery/range/charging at a glance; entries are wiped on sign-out and
  contain no VIN.
- Amp-limit preset chips (6/8/10/13/16 A) beside the charging-current slider;
  presets outside the vehicle's advertised range are hidden.
- Floating always-on-top charging mini-panel (optional, Settings → Appearance)
  showing SoC→target, power, and ETA without activating Hisingen; position is
  remembered and it closes on unplug.
- Reorderable Charging-card detail rows from Settings; unlisted rows keep
  their default position, so a partial order is safe.
- Fuel fill-up logging for hybrid and combustion owners (volume, price,
  odometer); fill-ups are included in lifetime cost-per-distance so PHEV and
  ICE economics are complete rather than silently electric-only.
- Reverse-geocoded street address on the parking-location card, with GPS
  coordinates kept below as the precise fallback. Both respect Screenshot
  Privacy Mode.
- Failing-cable hint: completed sessions at a named location whose peak power
  falls far below that location's own norm trigger an "unusually slow
  charging" notice. Requires three comparable prior sessions, so first visits
  never fire it.

### Changed

- Menu bar charging countdown now targets the configured charge level
  ("72→80 · 25m") instead of always counting down to 100 %.
- Polling stretches to a 15-minute floor while the vehicle reports itself
  unavailable (asleep/power-saving), returning to normal cadence on wake.
- Telemetry rows record whether a consumption figure is kWh/100 km or
  L/100 km, so combustion history can never be misread as energy data going
  forward.
- Chart colors follow theme tokens instead of hardcoded hues, keeping
  multi-series cards readable under monochrome themes.
- Vehicle nicknames appear in notifications and Shortcuts responses instead
  of the generic brand name (Spotlight already used them).
- Snapshot encoding moved to a clustered fuel/engine layout (`fuelSystem`)
  with flat-key decode compatibility, so existing persisted snapshots keep
  loading while new writes use the nested form.
- Polestar authorization extracted behind a replaceable
  `PolestarAuthorizationCodeSource` seam (scripted PingFederate conformer
  today), containing provider-markup changes to one type.
- `VehicleDatabase` persistence split into themed extensions (sessions,
  telemetry, trends, health, fuel, exports, command audits) for navigability;
  no behaviour change.

### Fixed

- Fallback code signing and packaging in the release workflow when Apple
  Developer ID certificates are not configured.
- Defaulted the Polestar public render-CDN key in `Scripts/inject-secrets.sh`
  to the documented public AppSync key.
- Updated all GitHub Actions workflow pins to their latest verified immutable
  commit SHAs.
- Cleared four compiler warnings: a stray `await` on a synchronous call, a
  MainActor-isolated logger captured from a Sendable closure, the deprecated
  single-parameter `onChange`, and an unused binding.
- Full test suite migrated to Swift Testing; the previous XCTest files cannot
  compile on the current toolchain.

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
- Software fields from Polestar responses are labeled as
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
