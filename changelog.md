# Changelog

All notable changes to Hisingen are documented here.


## 2.5.0 — 2026-08-14

### Added (API Completion, Privacy & Session Reliability)

- Added server-side OIDC refresh-token revocation on sign-out while preserving guaranteed local credential cleanup.
- Reduced normal startup to one Keychain credential read and eliminated unchanged token rewrites and unused password deletion.
- Added positive per-VIN runtime capability probes backed by the privacy-safe vehicle cache.
- Added vehicle software version, update state, schedule, and timestamp presentation.
- Added Digital Twin cabin and requested climate temperatures.
- Added per-VIN local vehicle nicknames with migration from the previous single nickname.
- Added opt-in, capped local charging-session summaries with SOC gain, estimated energy, peak power, and cost.
- Added software-update, vehicle-warning, 12 V, tyre, light, fluid, and alarm transition notifications.
- Added an in-app System/English/Swedish language selector and completed primary popover localization.
- Disclosed Open-Meteo coordinate use for optional vehicle weather and GitHub Releases update checks.
- Renamed the range-derived health metric to **Range Health Estimate** so it is not presented as measured battery SoH.

### Added (Telemetry Intelligence, Smart Alerts & Micro-Animations)

- **Charging Session Graph & Telemetry Sparkline**:
  - Implemented real-time in-memory charging telemetry sample buffering (`ChargingSample`) during active charging sessions.
  - Built a native SwiftUI vector `ChargingSparklineView` with gradient stroke and area fill, visualizing battery % progression and starting-to-current charge delta in the Charging details card.
  - Automatically resets session telemetry upon disconnection or charge completion to preserve zero-disk privacy.
- **Dynamic Menu Bar Tinting**:
  - Added user-configurable status bar icon tinting (vibrant green while charging, orange below 20% SoC, or classic monochrome template) with instant live preview in Settings.
- **Multi-Vehicle Fast Switcher & Hotkeys**:
  - Added global and local keyboard shortcuts (`⌥ + [` and `⌥ + ]`) to cycle between vehicles, and (`⌥ + 1` ... `⌥ + 9`) to jump directly to any vehicle.
  - Added inline `<` and `>` chevron navigation buttons in the popover footer next to the vehicle picker.
  - Added vehicle index shortcuts and direct hotkey triggers to the right-click status item menu.
- **Menu Bar Customization & Monospaced Typography**:
  - Added new configurable menu bar display presets: **Compact Charging** (e.g. `⚡ 82% (1h42m)`), **Battery and Power** (e.g. `82% · 7.2 kW`), **Battery and Range**, and **Range**.
  - Configured status bar label with `NSFont.monospacedDigitSystemFont` to eliminate menu bar width jitter during percentage and range updates.
  - Added live preview banner in Settings to instantly audition menu bar format changes.
- **Charging Telemetry & Wall-Clock Ready Time**:
  - Added localized wall-clock charging completion calculations (`Ready around 15:38` or `Ready around 3:38 PM`) in the Charging details card and status bar tooltips.
  - Added real-time charging speed calculations (`+40 km/h` or `+25 mph`) derived from active charging power and model-specific consumption baselines.
- **Vehicle Sleep & Freshness Presentation**:
  - Distinguishes live telematics from vehicle deep sleep with relative staleness badges ("Vehicle asleep · Updated 8 min ago").
- **Battery State of Health (SoH %) Estimator**: Added real-time battery degradation estimation in the Diagnostics card based on vehicle model nominal battery pack capacities (78 kWh / 69 kWh / 111 kWh / 102 kWh).
- **Estimated Charging Cost Calculator**: Added automatic charging cost calculations in the Charging card based on user-configured electricity tariffs (`kr/kWh`, `$/kWh`, `€/kWh`) in Settings.
- **Reverse-Geocoded Human-Readable Address**: Built `ReverseGeocoder` using Apple's `CoreLocation` framework (`CLGeocoder`) to automatically resolve GPS coordinates into street and city names (e.g. *"Hamngatan 14, Stockholm"*) with local coordinate caching.
- **Smart Security & Weather Notifications**:
  - **Rain with Windows Open Alert**: Monitors live ambient on-car weather conditions and immediately alerts if rain or snow is detected while windows or sunroof are vented.
  - **Evening Unlocked Reminder**: Periodically verifies central locking between 21:00 and 06:00 and notifies if the vehicle is left parked and unlocked.
  - **Anti-Phantom Recuperation Filter**: Verified speed and charging connection states to prevent downhill regenerative braking spikes from falsely registering as plugged-in charging sessions.
- **Micro-Animations & Native Craftsmanship**:
  - **Breathing Charging Pulse**: Added a soft, rhythmic breathing glow (`easeInOut`) to `BatteryGauge` during active charging, mimicking the vehicle's charge port LED.
  - **Spinning Refresh Indicator & Haptics**: Added smooth 360° rotation animation on manual refresh and tactile feedback via `NSHapticFeedbackManager`.
  - **Interactive 4-Wheel iTPMS Hover**: Added smooth scaling and border highlight transitions on the tire schematic cards.
  - **Native SF Pro Typography**: Modernized typography across all live metrics and status readouts to use Apple SF Pro with tabular digits (`.monospacedDigit()`).
- **Global Keyboard Shortcut & Context Menu**:
  - Registered `Option + P` (`⌥ + P`) global and local event monitor to toggle the popover from anywhere in macOS.
  - Built rich right-click AppKit context menu on the status bar icon with vehicle headers, live charging/lock indicators, Maps launch, VIN copy, and multi-vehicle switching submenus.

### Added (capability-driven architecture)

- Made `VehicleModelFamily.unknown` preserve the original model name so future Polestar models are not silently discarded. The UI now shows "Polestar 7 Synergy" instead of "Unknown model" when a new model appears, and all capabilities default to `.backendDependent` (probed at runtime) rather than assumed unsupported.
- Added `FeatureAvailability` and `VehicleFeatureStatus` models that distinguish whether a vehicle *can* perform a feature (capability) from whether it *currently can* (availability). A Polestar 4 that supports remote climate but is offline now reports `support = .supported, availability = .vehicleOffline` rather than conflating the two.
- Added `internalVehicleIdentifier` to the `getConsumerCarsV2` GraphQL discovery query, matching the current Polestar mobile app's request shape.
- Added `docs/polestar-api.md` — comprehensive reconstructed API reference covering authentication, GraphQL operations, gRPC service paths, protobuf field numbers, enum values, rate limits, capability caching, and known limitations with per-endpoint confidence levels.
- Added `docs/vehicle-capabilities.md` — full per-model capability matrix (P1–P5) with evidence sources, a detailed Polestar 2 vs Polestar 4 comparison, and explanation of the capability detection hierarchy.
- Added sanitized VDMS discovery and multi-vehicle account fixtures.
- Added 10 new tests: unknown model name preservation, P2 hides climate temperature/tyre pressure, P4 shows climate temperature and hides current limit/pre-cleaning, `FeatureAvailability` distinguishes capability from offline availability, unsupported capabilities are never usable, VDMS discovery decodes model from content, legacy discovery decodes `internalVehicleIdentifier`.

### Added (PCCS host routing, streaming, location/weather, amp-limit read)

- Split gRPC routing into C3 (vehiclestates, OTA, location, weather) and PCCS (`api.pccs-prod.plstr.io:443`, chronos services + invocation). Previously all calls routed through C3, which could fail for chronos services that are only available on the Polestar-operated PCCS platform. Confirmed against pypolestar's two-channel architecture.
- Added `AmpLimitService/GetAmpLimit` read on PCCS. The amp limit is now fetched as part of charging details (when `chargingCurrentLimit` is permitted by the vehicle's capability profile) and used as a fallback when the battery service doesn't report the live current.
- Added `DtlInternetService/GetLastKnownLocation` (C3) and `WeatherService/GetWeatherReport` (C3) as optional read-only capabilities. Weather is gated behind a new **Vehicle weather** feature toggle and shown in the Climate & timers submenu. Location is implemented at the service layer but deliberately not exposed in the UI for privacy (the raw coordinates are not persisted in the cache).
- Added `streamMessages` for server-streaming gRPC responses. Collects multiple frames from a single HTTP/2 response with timeout tolerance — some Polestar streams (TargetSoc, invocation lifecycle) leave the stream open until the URLSession deadline.
- Added region/market awareness from the OIDC userinfo `market` claim. The VDMS app-backend `X-Polestar-Locale` header now uses the account's registered market as a fallback when the device locale doesn't provide a region.
- Added 7 new tests: amp limit response parsing, amp limit rejects zero/out-of-range, location parses lat/long, location with timestamp and heading, weather parses temperature and timestamp, weather with no data returns nil, streaming collects multiple frames.

### Added

- Added a typed per-model capability profile for Polestar 1–6 and unknown
  future vehicles, with supported, vehicle-managed, unavailable, and
  backend-dependent states. The status menu exposes the full matrix and
  Settings shows the selected vehicle's important capabilities.
- Added model-aware remote climate behavior: Polestar 2 sends start/stop with
  vehicle-managed temperature and heating (unsupported protobuf fields are
  omitted), while Polestar 4 exposes selectable temperature and heating. Known
  unsupported Polestar 4 current-limit, pre-cleaning, legacy-connectivity, and
  remote-OTA controls are suppressed and rejected before dispatch.
- Added current mobile-app `GetVDMSCars`/VDMS vehicle-discovery compatibility as
  a fallback to the legacy `getConsumerCarsV2` GraphQL schema.
- Restored the prominent full-width studio car image in the menu summary while
  preserving its default-on feature setting and native Light/Dark adaptation.
- Added deterministic model normalization, capability mapping, command
  adaptation, and automatic-climate protobuf tests.

- Replaced the screen-height flat status menu with a compact native macOS design: an at-a-glance vehicle summary, semantic battery/status presentation, SF Symbols, and focused Charging, Vehicle, Climate, Diagnostics, Remote Controls, and Attention submenus. All existing telemetry and commands remain available without overwhelming the primary menu.
- Enabled the transparent configured vehicle image by default for new installations, with an adaptive SF Symbol fallback when no image is available; it remains user-controllable in Settings.
- Audited the UI against Apple’s current macOS, menu, Dark Mode, color, materials, accessibility, and SF Symbols guidance. Native AppKit menus provide the current system material (including the latest macOS presentation), while semantic system colors, template symbols, system typography, and transparent custom content adapt automatically to Light, Dark, increased-contrast, accent-color, and desktop-tinting changes.

- Added owner-authorized experimental remote vehicle controls, quarantined behind the `POLARIS_EXPERIMENTAL_REMOTE` compile flag and absent from standard builds:
  - climate start/stop with target temperature, individual front/rear seat heat, and steering-wheel heat
  - cabin pre-cleaning start/stop
  - charge-target and AC-current-limit changes plus active-schedule override/resume
  - global charging-schedule editing and parking-climate timer create/enable/disable/delete
  - lock, unlock, trunk unlock, all-window open/close, flash, and honk+flash
  - OTA schedule, install-now, and cancel actions when current software context exists
- Added explicit per-command confirmation, selected-vehicle identification, single-command serialization per VIN, backend lifecycle/result handling, post-command refresh, and friendly failure feedback.
- Added Touch ID/Mac-password authorization for unlock, trunk unlock, window opening, and destructive actions.
- Added deterministic wire-format and command-result tests without issuing mutations to a live vehicle.

- Implemented every currently documented safe read-only capability behind individual feature toggles:
  - exterior lock, alarm, door, window, sunroof, hood, tailgate, and charge-lid state
  - model-dependent tyre pressures and tyre, fluid, light, service, and 12 V warnings
  - vehicle software/OTA state and scheduled installation time without mutation controls
  - global and saved-location charge/departure schedules with aliases and coordinates discarded
  - climate activity and parking-climate timers
  - Digital Twin trip meters with legacy dashboard fallback
  - legacy connectivity status, network type, and signal strength
  - cabin pre-cleaning, air quality, PM2.5, and runtime status
  - charger-power state, time-to-target, and reported consumption diagnostics
- Added per-VIN capability backoff so an unsupported service is retried later without delaying or failing core battery refreshes.
- Added manual-VIN discovery fallback for secondary and guest accounts whose account vehicle list is empty, including strict VIN validation.
- Added Digital Twin and legacy protobuf decoding, partial exterior snapshot merging, privacy-safe schedule derivation, backward-compatible cache decoding, localized menu presentation, and deterministic parsing tests for the new capabilities.

- A typed `VehicleState` domain model separating API transport values from application and UI state.
- Forward-compatible charging, charger-connection, charging-type, and vehicle-availability enums with explicit unknown states.
- Verified read-only vehicle-service fields:
  - battery percentage and estimated range fallback
  - vehicle-reported timestamp
  - charging state and time-to-full
  - charger connected, disconnected, or fault state
  - AC, DC, or wireless charging type
  - charging power, current, and voltage
  - configured charge target
  - vehicle availability and unavailable reason
- Freshness-aware merging of GraphQL and vehicle-service battery results. The newest reported sample wins without replacing valid fields with missing values.
- Automatic discovery of vehicles associated with the authenticated account.
- Multiple-vehicle switching with per-VIN cached state and notification baselines.
- Optional vehicle image display.
- Four stable menu-bar presets:
  - battery percentage
  - battery and range
  - charging-aware battery/time display
  - range
- Relative last-updated text and an explicit stale-data warning. Charging data becomes stale after 15 minutes; idle data after one hour.
- A dedicated `RefreshCoordinator` responsible for:
  - one in-flight request at a time
  - duplicate manual-refresh coalescing
  - request cancellation and stale-response rejection
  - 60-second charging and 5-minute idle intervals
  - exponential retry backoff
  - retry jitter
  - `Retry-After` support and manual rate-limit enforcement
  - network reachability changes
  - macOS sleep and wake
  - refresh on application activation when stale
  - cached offline state
- Local privacy-preserving diagnostics showing app version, session state, network state, last success, request latency, next refresh, and the last friendly error.
- Restart-safe charging transition detection for:
  - charging started
  - charging completed
  - explicit charging fault
  - charging interrupted, confirmed over two samples
  - configurable low-battery threshold with hysteresis
- Stable per-vehicle notification identifiers and notification threads.
- An authentication-required notification with deduplication.
- Notification privacy controls that can hide battery, range, and charging details.
- A user-controlled sign-out action that clears account settings, cached vehicle data, notification baselines, password, and refresh token.
- A lightweight `VehicleProviding` boundary so refresh behavior can be tested with a mock without protocolizing the rest of the application.
- A manual **Check for Updates…** menu action with explicit update-available, up-to-date, and failure results.
- An **About Polaris** menu action.
- Native, keyboard-accessible copy actions for VIN and registration plate.
- VoiceOver labels for the status item, vehicle state, stale-data state, menu rows, and vehicle image.
- Typed per-feature controls for vehicle identity, owner greeting, vehicle image, charging details, availability, odometer/service data, multiple-vehicle switching, notifications, and update checks.
- Network-aware feature gating: disabled image, owner, charging-enrichment, availability, and vehicle-health capabilities no longer make their optional API requests. Battery percentage, range, charging state, freshness, refresh, and settings remain the dependable core.

### Authentication and API reliability

- Converted `PolestarAPI` and the vehicle gRPC client to actors.
- Added typed OAuth token, OIDC discovery, GraphQL response, vehicle, odometer, health, and account-vehicle decoding.
- Added flexible integer and floating-point decoding for API values that may be encoded as numbers or strings.
- Added cryptographically secure PKCE verifier and OAuth state generation.
- Added OAuth callback state validation and exact redirect scheme, host, and path validation.
- Added an OAuth redirect delegate that stops and captures the configured callback before `URLSession` follows it away.
- Restricted discovered OIDC endpoints to HTTPS Polestar domains and validated the issuer origin.
- URL-encoded login and token form bodies using `URLComponents` instead of hand-built strings.
- Serialized refresh-token rotation so simultaneous API requests cannot run competing refreshes.
- Retried GraphQL requests once after a 401/403 with a forced token refresh.
- Distinguished network, authentication, rate-limit, server, GraphQL, partial-data, decoding, API-incompatibility, invalid-response, configuration, and Keychain failures.
- Preserved partial GraphQL data and surfaced a limited-data warning instead of failing a complete refresh.
- Kept missing API fields optional instead of displaying fabricated zero values.
- Added HTTP response-size, gRPC frame-size, image MIME-type, image status, HTTPS, and image-size validation.
- Reduced optional vehicle-service request timeouts so unavailable enrichment data cannot hold up the app for long periods.
- Coalesced concurrent C3 service-discovery requests.
- Cached charge targets for 15 minutes to reduce unnecessary network traffic.
- Removed raw redirect URL, token, authorization-header, password, and personal-data logging.
- Replaced ad-hoc logging with Apple unified `Logger` categories.

### Security and Keychain

- Changed Keychain writes to update in place and add only when an item does not exist, avoiding delete-before-write credential loss.
- Scoped secrets with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Made Keychain deletion errors observable instead of silently ignoring unexpected failures.
- Kept plaintext legacy-password migration recoverable until the Keychain write succeeds.
- Stored the account password only long enough to establish a renewable OAuth session, then removed it.
- Made refresh-token persistence part of successful token application so a password is never deleted before a usable session is securely stored.
- Added rollback when a settings credential change cannot delete the previous session.
- Made sign-out attempt removal of both session and password even when one Keychain operation fails.
- Added a dedicated friendly protected-storage error without exposing Keychain contents.

### Menu and settings

- Rebuilt menu rendering around typed state instead of raw GraphQL/gRPC strings.
- Added battery, range, status, charger connection, charging type, target, power, current, voltage, completion estimate, vehicle availability, odometer, service, and warning rows when data exists.
- Corrected estimated completion time to use the vehicle-reported timestamp rather than blindly using fetch time.
- Updated relative timestamps whenever the menu opens.
- Added automatic VIN behavior and made manual VIN entry optional.
- Added settings for menu-bar preset, distance unit, optional feature selection, charging notifications, low-battery notification and threshold, private notification details, and launch at login.
- Made dependent notification controls unavailable when notifications are disabled, and cleared Polaris-delivered and pending notifications when the master notification feature is turned off.
- Stopped reading an existing password back into the settings field.
- Added current diagnostics to Settings.
- Synchronized launch-at-login preferences with `SMAppService` after registration errors.
- Kept cached vehicle information visible alongside transient/offline errors.

### Notification behavior

- Moved notification decisions from individual API samples to persisted state transitions.
- Suppressed notifications for duplicate samples, stale samples, first observation after launch, smart-charging pauses, and scheduled charging.
- Required two consecutive interruption samples before reporting an unexpected stop.
- Added low-battery deduplication and a 5-percentage-point reset hysteresis.
- Deferred notification authorization until the user saves enabled notification preferences.
- Kept notifications unavailable when running the unbundled development binary.

### Update checker

- Added correct dotted Semantic Version comparison, including prerelease and build metadata behavior.
- Ignored draft and prerelease GitHub releases.
- Added GitHub API `Accept` and `User-Agent` headers and a request timeout.
- Recorded the daily check timestamp only after a successful response.
- Cached an available update across launches and removed obsolete cached versions.
- Coalesced manual and automatic checks into a single request.
- Kept failed automatic checks silent while giving manual checks clear feedback.

### Tests

- Migrated the suite from unavailable standalone-CLT XCTest to Apple Swift Testing, including async continuations and credential-gated test traits; 52 deterministic tests now execute with the installed toolchain.

- Added sanitized deterministic fixtures for:
  - idle vehicle
  - charging vehicle
  - completed charging
  - charging fault
  - partial GraphQL response
  - GraphQL error
- Added tests for flexible GraphQL decoding, missing fields, partial responses, GraphQL error paths, token expiration decoding, and HTTP failure classification.
- Added protobuf and gRPC battery parsing coverage for charge percentage, range, time, state, connection, type, power, current, and voltage.
- Added charging-transition tests for start, completion, fault, duplicate suppression, restart-safe state, two-sample interruption, stale-event suppression, and low-battery hysteresis.
- Added refresh-policy tests for normal cadence, charging cadence, exponential backoff, rate-limit minimums, and maximum retry delay.
- Added a mock-provider coordinator test proving simultaneous launch/manual refresh requests coalesce into one vehicle fetch.
- Added stale-data threshold tests.
- Added Semantic Version and stable-release evaluation tests.
- Added feature-selection and optional GraphQL-selection tests.
- Added an opt-in, credential-gated live integration test for authentication, vehicle discovery, state retrieval, and sign-out. Ordinary tests skip it without dedicated test-account secrets.
- Retained login resume-path parsing fixtures for the brittle identity-provider HTML boundary.
- Enabled complete Swift concurrency warnings in CI.

### Build and release

- Repaired standalone Command Line Tools support by selecting the installed macOS SDK and conditionally supplying only its Swift Testing framework/runtime paths. `swift build`, plain `swift test` compilation, and the executable test mode now work without requiring the full Xcode application.

- Added universal Apple silicon and Intel release builds using isolated SwiftPM scratch paths and `lipo` verification.
- Required production signing and notarization secrets instead of silently publishing an ad-hoc-signed fallback.
- Limited signing and notarization secrets to only the steps that need them.
- Pinned GitHub Actions by commit SHA.
- Pinned CI and release builds to Xcode 16.2 and made missing-toolchain detection fail closed.
- Moved CI and release jobs to the supported macOS 15 runner generation and added CI coverage for both Apple silicon and Intel runners.
- Added a manually dispatched live Polestar integration workflow that requires dedicated repository secrets and performs read-only account/API verification.
- Added CI concurrency cancellation and explicit timeouts.
- Added tests before release packaging.
- Added Developer ID identity validation, hardened-runtime signing, signature verification, Gatekeeper assessment, notarization, stapling, and stapler validation.
- Notarized and stapled both the application and DMG.
- Added universal-architecture verification.
- Added `Polaris.dmg`, `Polaris.zip`, and `SHA256SUMS` release assets.
- Added always-run temporary certificate and build-Keychain cleanup.
- Kept least-privilege read permissions by default and granted release write permission only to the publishing job.

### Documentation

- Corrected claims that Polaris uses a supported public “official API.” It uses first-party-operated but undocumented/reconstructed services.
- Documented which fields are primary, best effort, or not reliably available.
- Documented automatic VIN discovery and multiple vehicles.
- Documented password removal after session establishment.
- Documented signed, notarized, universal releases and checksums.
- Updated the website installation and privacy language.
- Extracted all website presentation into `docs/styles.css` and all website behavior into `docs/site.js`; the HTML contains no inline style or script blocks.
- Added English and Swedish website locale catalogs, an accessible language selector, locale persistence, localized metadata/alternative text, and complete English no-JavaScript fallback content.
- Removed the website's Google Fonts requests and now use the native system font stack, eliminating an unnecessary third-party network dependency.
- Added a restrictive website Content Security Policy for self-hosted styles, scripts, locale data, and images.
- Added a model-aware API capability map covering implemented read-only fields, model/backend caveats, privacy constraints, external verification needs, and deliberately excluded mutations.

### Project structure and localization

- Reorganized the flat Swift target into `App`, `Domain`, `Services/API`, `Services/Notifications`, `Services/Persistence`, `Services/Refresh`, `Services/Updates`, `Support`, `Resources`, and `UI` boundaries.
- Split tests into `Unit`, `Integration`, and sanitized `Fixtures` directories.
- Added a centralized `L10n` resource accessor and moved user-facing AppKit, notification, domain-display, diagnostic, and friendly-error strings into `Localizable.strings`.
- Added complete English resources, Swedish UI translations, retained localized greetings, and localized `Info.plist` display/copyright resources.
- Updated SwiftPM and the custom `.app` assembler to package localization resources correctly.
- Added `make doctor` to detect mismatched Swift compiler, SDK, SwiftPM, and selected developer-tool installations before a build.
- Made the Polestar API accept an injected `KeychainStore`, isolating live integration credentials from installed-app credentials.

## Remaining external verification

All currently identified source-level changes and test hooks are implemented.

Completed live verification:

- [x] Dedicated read-only account login and one-vehicle discovery.
- [x] Core battery/range state retrieval.
- [x] Refresh-token session restoration.
- [x] Identity, studio image, charging enrichment, availability, and odometer/service responses on the supplied vehicle.
- [x] Isolated-Keychain sign-out and cleanup without touching the installed-app namespace.

The following executions still require infrastructure, additional vehicle models, signing credentials, installed builds, or upstream cooperation:

- [ ] Finish Apple Command Line Tools repair. The installed Swift compiler is
  6.3.3, the selected macOS 26.5 SDK's Swift standard library is 6.3.2, and the
  bundled Swift Testing framework requires newer `SendableMetatype` support
  than the compatible macOS 15.4 SDK provides. Production and experimental app
  builds pass with the 15.4 SDK and serialized compilation; `swift test` cannot
  compile until Software Update installs one internally matching CLT release.
- [ ] Observe a successful CI matrix run on the `macos-15` and `macos-15-intel` GitHub-hosted runners with Xcode 16.2. The workflows and Swift Testing invocation are implemented; hosted execution still requires GitHub infrastructure.
- [ ] Configure the same dedicated credentials as GitHub repository secrets and observe the live integration workflow succeeding on its hosted runner.
- [ ] Exercise expired-session recovery and account switching against dedicated test accounts; these destructive/session-lifecycle cases remain intentionally outside the read-only smoke test.
- [ ] Verify how accounts requiring MFA, CAPTCHA, or newly introduced identity-provider steps behave. Polaris reports these as an additional/changed sign-in step; a browser fallback cannot be guaranteed until Polestar provides a callback that a third-party macOS app can securely claim.
- [ ] Validate optional gRPC fields and availability reasons on Polestar 2, 3, and 4 vehicles across supported regions. The reconstructed services explicitly vary by vehicle model and may change without notice.
- [ ] Run the production release workflow with the repository's Developer ID and notarization secrets, then verify Gatekeeper on clean Apple silicon and Intel Macs.
- [ ] Confirm launch-at-login approval and behavior from an app installed in `/Applications` on each supported macOS major version.
- [ ] Validate each enabled remote command on owner-authorized Polestar 2, 3, and 4 vehicles, one command at a time; no live vehicle mutation is part of automated testing.

## Upstream limitations and deliberate exclusions

- Software/update information is implemented as an optional read-only capability. It has been observed returning no record on Polestar 4 when no OTA is pending, so empty remains a normal result until broader model coverage exists.
- Usable battery capacity, battery state of health, and estimated remaining kWh are not exposed reliably by the current cloud services. Polaris leaves them unavailable rather than guessing.
- The Polestar interfaces are undocumented and have no public compatibility guarantee. Schema/capability monitoring remains ongoing maintenance, not a one-time code fix.
- Vehicle wake-up remains excluded because the current backend explicitly reports that invocation as unimplemented.
- Direct start/stop of unrestricted charging remains unavailable; the implemented official-app-style calls only override an active charge schedule.
- Saved charge-location CRUD remains excluded because it handles precise vehicle locations and is not required for global charging/climate schedule control.
- Location tracking, analytics, telemetry, continuous streams, background daemons, Electron, and heavyweight state-management frameworks remain deliberately out of scope.
