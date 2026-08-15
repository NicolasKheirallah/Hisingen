# Hisingen

[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Architecture](https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-purple)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Hisingen is a native macOS menu bar application for monitoring Polestar and Volvo vehicles. It is written in Swift with AppKit and SwiftUI. Polestar support communicates directly with Polestar-operated OIDC, GraphQL, C3, and PCCS services; Volvo support uses Volvo's official Connected Vehicle API v2 and Energy API v2 via Volvo ID OAuth2. The two brands are entirely separate providers behind a shared `VehicleProviding` interface — see [Architecture And Security](#architecture-and-security) — so signing into one never touches the other's credentials or vehicle state.

Polestar does not publish a supported third-party vehicle-cloud API. Hisingen therefore uses undocumented interfaces reconstructed from current first-party client behavior for Polestar vehicles. These interfaces can change without notice, and optional capabilities vary by model, model year, region, account role, vehicle state, and backend rollout. Volvo support is built on Volvo's *official*, documented Connected Vehicle API — but using it requires each user to register their own free API application at [developer.volvocars.com](https://developer.volvocars.com) (a Client ID, Client Secret, and VCC API Key), which Hisingen cannot do on your behalf. See [Volvo Support](#volvo-support) below.

[Download Latest Release](https://github.com/NicolasKheirallah/hisingen/releases/latest) · [All Releases](https://github.com/NicolasKheirallah/hisingen/releases) · [Features](#read-only-capabilities) · [Vehicle Support](#supported-vehicles) · [Volvo Support](#volvo-support) · [Installation](#installation) · [Changelog](changelog.md)

## Table of Contents

- [Screenshots](#screenshots)
- [At A Glance](#at-a-glance)
- [Read-Only Capabilities](#read-only-capabilities)
- [Charging Intelligence](#charging-intelligence)
- [Notifications](#notifications)
- [Menu Bar And macOS Integration](#menu-bar-and-macos-integration)
- [Multiple Vehicles](#multiple-vehicles)
- [Supported Vehicles](#supported-vehicles)
- [Volvo Support](#volvo-support)
- [Refresh And Reliability](#refresh-and-reliability)
- [Architecture And Security](#architecture-and-security)
- [Remote Controls](#remote-controls)
- [Installation & Setup](#installation)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Authors And Credits](#authors-and-credits)
- [License And Disclaimer](#license-and-disclaimer)

## Screenshots

The screenshots show the current native popover in Swedish. Hisingen can follow macOS automatically or use English or Swedish independently of the system language.

| Vehicle overview | Telemetry details |
| --- | --- |
| ![Vehicle overview with studio image, owner greeting, registration, battery, range, status and odometer](assets/hisingen-vehicle-overview.png) | ![Telemetry cards for charging, vehicle state, climate and connectivity](assets/hisingen-telemetry-details.png) |

| Controls status | Display settings |
| --- | --- |
| ![Controls tab explaining that remote commands are unavailable](assets/hisingen-controls-unavailable.png) | ![Language, charging history, menu bar, unit, startup and electricity settings](assets/hisingen-settings-display.png) |

| Telemetry features | Diagnostics and notifications |
| --- | --- |
| ![Individual read-only telemetry feature switches](assets/hisingen-settings-telemetry.png) | ![Diagnostics and notification settings](assets/hisingen-settings-diagnostics-notifications.png) |

## At A Glance

Hisingen keeps the selected vehicle visible without opening a full application window:

- battery percentage, estimated range, charging state, and data freshness;
- studio render, owner greeting, per-vehicle nickname, model, year, registration number, and VIN;
- charging connection, AC/DC type, power, current, voltage, target, time remaining, and ready time;
- locks, openings, alarm, tyres, service, fluid, light, and 12 V warnings;
- climate state, cabin/requested temperature, timers, air quality, and pre-cleaning status;
- odometer, trip meters, software/OTA state, network status, location, maps, and weather;
- configurable notifications, multiple vehicles, and privacy-aware local caching.

Standard Hisingen builds are read-only. Remote controls are unavailable because Polestar currently restricts vehicle commands to officially paired mobile clients.

## Read-Only Capabilities

Every optional group can be enabled independently. Unsupported services degrade gracefully and do not prevent core battery refreshes.

| Capability | Data shown |
| --- | --- |
| Core telemetry | Battery, range, charging state, time to full, fetch time, vehicle-reported time, and stale/asleep state |
| Vehicle identity | Model, year, registration, VIN, per-VIN local nickname, and account vehicle discovery |
| Owner greeting | Polestar ID first name localized using the selected app language |
| Studio image | Transparent configured vehicle render from Polestar's image service |
| Charging details | Plug state, type, power, current, voltage, target SOC, current limit where supported, ready time, speed, and charger module state |
| Charging history | Optional local summaries capped at 20 per vehicle: SOC gained, estimated energy, peak power, duration, and cost |
| Availability | Online/offline state and reasons such as power saving, vehicle in use, service mode, tracking, or OTA |
| Odometer and service | Odometer, service countdown, service state, and fluid warnings |
| Exterior | Central lock, doors, windows, sunroof, hood, tailgate, charge lid, and alarm |
| Tyres and warnings | Direct pressures where reported, tyre warnings, lights, fluids, service, and 12 V warning |
| Trip meters | Manual and automatic trip distances with Digital Twin and legacy fallback |
| Climate | Activity, heating/cooling/ventilation, time remaining, actual/requested temperature, and timers |
| Charging schedules | Global and saved-location charge windows and departure schedules; precise locations and aliases are discarded |
| Air quality | Cleaning state, AQI, PM2.5, runtime remaining, and reported errors |
| Connectivity | Legacy network type, connection status, signal strength, and timestamp when available |
| Vehicle software | Version/title, OTA state, scheduled installation, and update timestamp |
| Vehicle location | Opt-in coordinates, heading/speed when reported, Apple reverse geocoding, and Maps shortcut |
| Vehicle weather | Opt-in temperature, condition, apparent temperature, and humidity using Open-Meteo with first-party fallback |
| Capability observations | Positive per-VIN service observations augment conservative model profiles and are cached locally |

## Charging Intelligence

- Dynamic battery gauge with charge-target marker and subtle charging pulse.
- Ready-time calculation based on the vehicle-reported sample timestamp.
- Charging-speed estimate in `km/h` or `mph`.
- Estimated completion cost using a configurable electricity rate and currency.
- Session sparkline with a capped rolling sample buffer.
- Optional local session summaries; raw long-term telemetry is not collected.
- **Range Health Estimate**, explicitly labeled as range-based rather than measured battery State of Health.
- Anti-phantom filtering to avoid treating regenerative power as plug-in charging.

## Notifications

- charging started, completed, interrupted, or faulted;
- configurable low-battery threshold from 5% to 50%;
- vehicle software available, completed, or failed;
- newly appearing service, tyre, light, fluid, 12 V, and alarm warnings;
- rain or snow near the vehicle while a window or sunroof is open;
- parked and unlocked reminder between 21:00 and 06:00;
- authentication-required reminder when the session cannot be restored.

Private notification mode hides detailed vehicle values from banners. Stable identifiers and notification threads prevent repeated copies of the same alert.


## Menu Bar And macOS Integration

### Display Presets

1. **Battery Percentage** — `73%`
2. **Battery and Range** — `73% · 280km`
3. **Charging Aware** — `73% · 1h42m` while charging
4. **Compact Charging** — `73% (1h42m)` while charging
5. **Battery and Power** — `73% · 7.2 kW` while charging
6. **Range** — `280km`

The icon can remain monochrome or tint green while charging and orange at low battery. Values use tabular digits to avoid width jitter.

### Keyboard And Context Menu

- `Option + P` toggles the popover globally after macOS Accessibility approval.
- `Option + [` and `Option + ]` move between vehicles.
- `Option + 1` through `Option + 9` select a vehicle directly.
- Right-click opens refresh, Maps, VIN copy, vehicle switching, Settings, and Quit actions.
- Scrolling remains enabled while visual scroll indicators stay hidden.
- Launch at login uses `SMAppService` and the normal Login Items approval flow.

### Personalization

- Per-vehicle local nicknames.
- System, English, or Swedish interface language.
- Kilometers or miles.
- Electricity rate and currency.
- Configurable read-only feature groups and notifications.
- Optional charging-session history.

## Multiple Vehicles

Hisingen discovers all vehicles returned by the signed-in account and isolates state, charging baselines, capability observations, and nicknames per VIN. Vehicles can be switched from the footer, keyboard, or context menu. Guest or secondary accounts without an account vehicle list can provide a validated VIN manually. Only one brand is active at a time today. Switching from Volvo to Polestar (by saving Polestar credentials) or vice versa doesn't delete the other provider's stored session — but switching back through Settings currently re-runs that provider's full sign-in rather than silently resuming it, even though the stored token would still work on a fresh app launch.

## Supported Vehicles

| Vehicle | Current behavior |
| --- | --- |
| Polestar 1 | Best-effort core and optional services; broad live verification remains required |
| Polestar 2 | Model-aware support; direct tyre pressure and selectable climate temperature are not assumed |
| Polestar 3 | Model-aware support with runtime confirmation for backend-dependent capabilities |
| Polestar 4 | Digital Twin support; current limit, pre-cleaning, legacy connectivity, and remote OTA are not assumed |
| Polestar 5 and 6 | Conservative backend-dependent profile with positive runtime observations |
| Future/unknown | Model name is preserved and capabilities remain probeable rather than rejected |

The model table is deliberately conservative: service availability is confirmed at runtime per VIN and may vary independently of the model badge.

## Volvo Support

Hisingen supports Volvo Cars as a second, independent provider alongside Polestar — pick one from the account picker in Settings. It is built on Volvo's current, official Connected Vehicle API v2 and Energy API v2 (not the discontinued "Volvo On Call" API, which Volvo shut down in 2025 and which no longer works with any client). Read-only telemetry is implemented for battery/charging state (BEV and PHEV), fuel level and range (ICE and PHEV), doors/windows/locks, tyre warnings, service diagnostics, and odometer.

**Setup requires your own Volvo Developer Portal registration.** Volvo issues each application its own OAuth Client ID, Client Secret, and VCC API Key rather than a shared public client — register a free API application at [developer.volvocars.com](https://developer.volvocars.com) with redirect URI `hisingen://oauth/volvo/callback`, then enter the three values in Settings and sign in with your Volvo ID in the system browser window that opens (Volvo's own 2FA happens there, never inside Hisingen).

**What's conservative about this today:**

- Volvo's lineup spans BEV, PHEV, ICE, and mild-hybrid vehicles in ways Polestar's doesn't. Powertrain is read from each vehicle's own reported fuel type, never guessed from its model name — the same XC60 model name ships as all four.
- Capability support (charge target, current limit, direct tyre pressure, and similar) is intentionally *not* hardcoded per model. Volvo's own API is capability-driven — it exposes what a given vehicle supports at runtime — so Hisingen probes rather than assumes, the same conservative philosophy it already applies to Polestar's own less-certain capabilities.
- Remote commands (lock/unlock/climate/honk) are implemented but excluded from standard builds behind the same `HISINGEN_EXPERIMENTAL_REMOTE` build flag Polestar's own remote commands use. Live testing confirmed the `/commands` endpoint returns 403 for a standard read-scoped app even with `conve:commands` granted — command execution needs an authorization path this hasn't been cleared to explore yet.
- Field mappings for the Connected Vehicle side (vehicle details, doors, windows, tyres, diagnostics, odometer, trip meters, fuel/electric range) have been validated against Volvo's own live sandbox demo vehicles — real field names, not guesses. The Energy API side (battery percentage, charging power/current/voltage, charge target) and Location API remain unverified against a live response and should be treated as best-effort until checked the same way. Decoding stays deliberately tolerant of missing/unexpected fields either way, so a remaining mismatch degrades to "no data" rather than a crash.

## Refresh And Reliability

- One in-flight refresh with duplicate manual-refresh coalescing.
- 60-second cadence while charging and 5-minute cadence while idle.
- Exponential backoff, jitter, `Retry-After`, and rate-limit enforcement.
- Network reachability, macOS sleep/wake, and stale-on-activation handling.
- Optional capability cache/backoff so one unavailable service cannot fail core telemetry.
- Freshness-aware merging; missing data never becomes a fabricated zero.
- Seven-day privacy-safe core cache and restart-safe charging baselines.


## Deep Technical Architecture & Engineering

### 1. Zero-Dependency Protobuf & gRPC Wire Engine

Unlike traditional Swift projects that bundle heavy external runtimes (like `SwiftProtobuf` or C++ gRPC binaries), Hisingen features a **lightweight, pure-Swift binary serialization and gRPC framing engine** (`PolestarGRPC.swift`, `PolestarGRPCCapabilities.swift`):

- **Varint Encoding & ZigZag Serialization**: Implements 7-bit payload chunking with MSB continuation markers for arbitrary integers, signed values, and booleans.
- **Wire Type Decoding**: Directly parses wire types `0` (Varint), `1` (64-bit fixed), `2` (Length-delimited strings/embedded messages), and `5` (32-bit fixed) into structured byte slices.
- **HTTP/2 gRPC Framing**: Generates the standard 5-byte length-prefixed binary envelope (`[compressed_flag: 1 byte][message_length: 4 bytes big-endian]`) over ephemeral HTTP/2 `URLSession` data tasks.
- **Internal Service Topology**:
  - **C3 Dynamic Discovery**: `https://cnepmob.volvocars.com`
  - **Polestar GraphQL Gateway**: `https://api.polestar.com/v2/graphql`
  - **Chronos / PCCS Services**: `https://api.pccs-prod.plstr.io:443` (Target SoC & Ampere limits)
  - **Volvo Connected Vehicle API v2 & Energy API v2**: `https://api.volvocars.com`

### 2. Actor-Isolated Concurrency & Refresh State Machine

Hisingen enforces strict compile-time Swift 6 concurrency (`-strict-concurrency=complete`) with zero mutexes or manual locks:

```
┌─────────────────────────────────────────────────────────────┐
│                 @MainActor RefreshCoordinator               │
│  - State Machine (idle, refreshing, error, sleeping)        │
│  - In-flight Task Coalescing & Deduplication                │
│  - Adaptive Jitter Backoff Algorithm                        │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
               ▼                               ▼
    ┌────────────────────┐          ┌────────────────────┐
    │ actor PolestarAPI  │          │   actor VolvoAPI   │
    │ + actor gRPC Engine│          │ + REST & Energy v2 │
    └────────────────────┘          └────────────────────┘
```

- **In-Flight Task Coalescing**: Multiple UI triggers or simultaneous timer events join a single active `Task<VehicleState, Error>`, eliminating redundant round-trips.
- **Adaptive Backoff & Jitter**: Failed network calls apply truncated exponential backoff with random jitter to prevent thundering herd against backend gateways:
  $$\text{Interval} = \min\Big(\text{MaxInterval},\; \text{BaseInterval} \times 2^{\text{retries}}\Big) \pm \text{UniformRandom}(0, \text{Jitter})$$
- **System Power Lifecycle Integration**: Subscribes to `NSWorkspace.willSleepNotification` to immediately halt network polling and `NSWorkspace.didWakeNotification` to schedule immediate stale-recovery refresh cycles upon machine wakeup.
- **Reachability Monitoring**: Hooks `NWPathMonitor` to seamlessly pause dispatch queues when offline and resume upon network restoration.

### 3. Digital Twin Normalization & Charging Intelligence

Vehicular telemetry arrives in drastically different formats across brands and protocols. Hisingen normalizes these into an immutable `VehicleState` domain model:

- **Anti-Phantom Charging Filter**: Prevents false charging alerts caused by downhill regenerative energy harvesting or battery voltage bounce. A state transition to `.charging` is only committed when physical plug-in state is confirmed alongside sustained positive wattage deltas.
- **Per-VIN Dynamic Capability Probing**: Instead of making brittle assumptions based on model names (e.g. Polestar 2 vs Polestar 4 vs Volvo XC60 Recharge), the runtime dynamically probes capabilities (amperage control, charge windows, direct tyre pressures) and caches positive responses locally.
- **Range Health Estimation**: Calculates dynamic baseline efficiency against standard battery temperature and SOC curves without pretending to be a battery degradation gauge.

### 4. Hardware-Backed Security & Cryptography

- **PKCE Implementation (RFC 7636)**: Generates 32-byte cryptographically secure random verifiers using Apple's `SecRandomCopyBytes`, computing `CC_SHA256` digests formatted as base64url strings.
- **Isolated Keychain Partitioning**: Access tokens and refresh tokens are stored in the macOS Keychain (`kSecClassGenericPassword`) bound strictly to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Polestar and Volvo credentials reside in completely segregated service domains (`io.kheirallah.hisingen`).
- **Privacy-Scrubbed Persistence Pipeline**: Before writing cached snapshots to disk, Hisingen's `VehicleStateStore` strips all raw GPS coordinates, VIN details, owner names, license plates, and schedule location strings.

### 5. Hybrid AppKit / SwiftUI Menu Bar Engine

- **Jitter-Free Status Item**: Implements custom AppKit `NSStatusItem` metrics with `monospacedDigit()` font tracking, ensuring the menu bar item width remains stable as percentage and charging timer strings update.
- **Global Event Interception**: Coordinates global hotkey dispatch (`Option + P`, `Option + [`, `Option + ]`) via `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` after Accessibility grant.
- **Ventura+ Login Items**: Integrates modern `SMAppService.mainApp` daemon control, adhering to macOS Ventura/Sonoma/Sequoia background management without legacy helper bundles.


## Installation & Setup

1. Download `Hisingen.dmg` from [the latest release](https://github.com/NicolasKheirallah/hisingen/releases/latest).
2. Open the disk image and drag `Hisingen.app` into `/Applications`.
3. Launch Hisingen and open **Settings**:
   - **For Polestar**: Select *Polestar* as brand and sign in directly with your Polestar ID.
   - **For Volvo**: Select *Volvo* as brand, enter your Client ID, Client Secret, and VCC API Key from [developer.volvocars.com](https://developer.volvocars.com), and complete authorization in the browser.
4. Enable optional read-only telemetry capabilities individually after vehicle discovery.

Production releases are universal binaries, Developer ID signed, hardened-runtime enabled, notarized, and stapled. Checksums are published with release assets.

### Build From Source

Requirements: macOS 13 Ventura or later and Xcode 15+ or compatible Command Line Tools with Swift 5.9+.

```bash
git clone https://github.com/NicolasKheirallah/hisingen.git
cd hisingen
make doctor
make test
make app
open Hisingen.app
```

`make app` produces an ad-hoc-signed local build. Rebuilding changes its identity and can cause Keychain or Accessibility approval to be requested again. Stable trust across rebuilds requires a Developer ID-signed release.

## Documentation & Terms

- [Changelog](changelog.md) — Release notes, historical fixes, and new features.
- [Terms & Conditions](TERMS.md) — Data privacy, account handling, and disclaimers.

## Frequently Asked Questions

### Why does the vehicle show as asleep or stale?

Polestar vehicles enter a low-power state while parked. Hisingen distinguishes fetch time from vehicle-reported sample time and retains the last safe snapshot while the vehicle is asleep or unreachable.

### Is Range Health Estimate battery State of Health?

No. Polestar does not reliably expose measured usable capacity or battery State of Health through these services. Range Health compares current range at the reported SOC with a model baseline; weather, wheels, speed, terrain, HVAC, and recent driving all affect it.

### Can Hisingen retrieve the nickname configured in the Polestar app?

No known current or legacy response includes an owner-assigned vehicle nickname. Hisingen stores optional nicknames locally and separately per VIN.

### Why are remote controls disabled?

Polestar rejects these commands without official paired-mobile authorization. Hisingen keeps the UI disabled rather than implying that an unverified mutation succeeded.

### Why can weather reveal the vehicle position to Open-Meteo?

Weather requires coordinates. When **Vehicle Weather** is enabled, Hisingen sends latitude and longitude to Open-Meteo. Disable Vehicle Weather if that disclosure is not acceptable.

## Authors And Credits

- **Nicolas Kheirallah** ([@NicolasKheirallah](https://github.com/NicolasKheirallah)) — architecture, API integration, security, localization, notifications, and native macOS experience.

## License And Disclaimer

Hisingen is released under the [MIT License](LICENSE).

Hisingen is independent open-source software and is not affiliated with, maintained by, or endorsed by Polestar Performance AB or Volvo Car Corporation.

See [Terms & Conditions](TERMS.md) for details on data handling, third-party account usage, and liability.
