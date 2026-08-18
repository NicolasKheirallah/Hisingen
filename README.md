# Hisingen

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![CI](https://github.com/NicolasKheirallah/Hisingen/actions/workflows/ci.yml/badge.svg)](https://github.com/NicolasKheirallah/Hisingen/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Your Polestar or Volvo, in the macOS menu bar.**

Hisingen is a native macOS app for checking your car without reaching for your phone. It brings vehicle status, charging, health information and supported remote controls into the menu bar, with separate integrations for Polestar and Volvo.

It is open source, runs locally on your Mac, and has no Hisingen-operated backend or account service.

[**Download latest release**](https://github.com/NicolasKheirallah/Hisingen/releases/latest) · [Vehicle support](#vehicle-support) · [Volvo setup](#volvo-setup) · [Documentation](docs/README.md) · [Changelog](changelog.md)

![Hisingen showing vehicle status from the macOS menu bar](website/public/assets/product/00-menu-bar-overview.png)

## What Hisingen Can Show

What is available depends on the vehicle, model year, region, account and the services exposed by Polestar or Volvo.

| Area                 | Examples                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------ |
| **Battery & range**  | Battery level, electric range, charging state and estimated charging time                  |
| **Charging**         | Plug state, charging power, current, target charge level and current limit where available |
| **Fuel & hybrids**   | Fuel level, distance to empty, fuel consumption and combined vehicle information           |
| **Doors & locks**    | Central locking, doors, windows, hood, tailgate, charge lid and sunroof where reported     |
| **Vehicle health**   | Tyre warnings or pressures, service information, fluids, lighting and 12 V warnings        |
| **Climate**          | Current climatization state, timers and other climate information where supported          |
| **Trips**            | Odometer, trip meters, consumption and average speed where available                       |
| **Connectivity**     | Vehicle availability and connectivity information exposed by the provider                  |
| **Software**         | Installed or available vehicle software information where the provider exposes it          |
| **Location**         | Last reported position, heading and Maps integration when enabled                          |
| **Weather**          | Weather around the vehicle when separately enabled                                         |
| **Charging history** | Local charging sessions, estimated energy use, charging cost and export                    |

Hisingen supports battery-electric, plug-in hybrid and combustion vehicles. The interface adapts to the data available from the selected vehicle rather than showing empty EV or fuel controls that do not apply.

## Screenshots

|                                         Polestar                                         |                                        Volvo                                       |
| :--------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------: |
| ![Polestar overview in Hisingen](website/public/assets/product/07-polestar-overview.png) | ![Volvo overview in Hisingen](website/public/assets/product/01-volvo-overview.png) |

|                                             Charging history                                             |                                  Vehicle controls                                  |
| :------------------------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------: |
| ![Polestar charging history in Hisingen](website/public/assets/product/08-polestar-charging-history.png) | ![Volvo controls in Hisingen](website/public/assets/product/06-volvo-controls.png) |

|                                             Service and information                                             |                                        Vehicle health and climate                                        |
| :----------------------------------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------: |
| ![Polestar doors, openings and tyre information](website/public/assets/product/17-polestar-openings-and-tyres.png) | ![Polestar health and climate information](website/public/assets/product/10-polestar-health-climate.png) |

## Vehicle Support

Hisingen does not treat a model name as proof that every feature is available.

It uses a capability model that combines conservative defaults with information observed from the vehicle and its backend. A feature can therefore be:

* supported
* handled automatically by the vehicle
* unavailable
* dependent on the vehicle backend or account

This matters because two cars with the same model badge can expose different services depending on model year, software, region, account permissions and backend rollout.

For the detailed capability model, see [Vehicle Capabilities](docs/domain/capability-matrix.md).

### Polestar

Hisingen understands the following Polestar model families:

* Polestar 1
* Polestar 2
* Polestar 3
* Polestar 4
* Polestar 5

All veichles connected to your account should be supported. Hisingen can retain the reported model and discover available capabilities conservatively.

Polestar does **not** currently provide a supported public third-party vehicle-cloud API for this use case. Hisingen therefore relies on interfaces derived from current first-party. Everything runs in your context with your logged in account

That has an important consequence: Polestar can change these services without notice. A feature that works today can temporarily or permanently stop working after a backend change.

Hisingen therefore tries to fail conservatively instead of presenting unavailable functionality as working.

See [Polestar API](docs/api/polestar.md) for the technical details.

### Volvo

Hisingen has model handling for:

* XC40
* EX40
* C40
* EC40
* XC60
* XC90
* S60
* S90
* V60
* V90
* EX30
* EX90
* ES90

Other Volvo vehicles can still be discovered and represented without pretending their capabilities are known in advance.

Volvo support is based on Volvo Cars' documented developer APIs, including:

* Connected Vehicle API v2
* Energy API v2
* Location API v1 when enabled and authorized

Available data and commands vary by vehicle and by the access granted to your Volvo Developer application.

See [Volvo API](docs/api/volvo.md) for the implementation details.

## Vehicle Images

### Polestar

Where image data is available, Hisingen supports six Polestar exterior render positions:

* front three-quarter
* front
* side
* rear three-quarter
* rear
* overhead

Images are cached locally so switching between available views does not require fetching them every time.

### Volvo

Volvo's API provides its own vehicle imagery rather than the same multi-angle image set used by Polestar.

Hisingen uses the exterior and interior images supplied for the vehicle where they are available.

## Charging

For charging-capable vehicles, Hisingen can combine provider data into a more useful charging view.

Depending on the vehicle, this can include:

* battery state of charge
* electric range
* charging state
* charger connection
* AC/DC charging type
* charging power
* current and voltage
* current limit
* charge target
* estimated completion time
* charging speed
* average consumption

### Charging History

Hisingen can keep local summaries of charging sessions.

These can include:

* starting and ending battery level
* estimated energy added
* charging duration
* peak charging power
* configured electricity price
* estimated charging cost

Charging history can be exported for further analysis.

The calculated energy and cost values are estimates based on the information available to Hisingen. They should not be treated as utility-grade metering.

## Vehicle Health

Where the provider reports it, Hisingen can show information such as:

* doors and openings
* lock state
* tyre status
* individual tyre pressure on vehicles that expose it
* exterior lighting warnings
* washer and other fluid warnings
* service status
* service countdown
* 12 V battery warnings
* odometer
* trip information
* vehicle connectivity

Some providers expose much more detail than others. Hisingen leaves unsupported values unavailable rather than inventing a value.

## Remote Controls

Remote controls are **opt-in**.

Hisingen only exposes a control when both of these are true:

1. the provider integration implements the operation
2. the current vehicle capability model permits it

Depending on the provider and vehicle, supported controls can include operations such as:

* climate start and stop
* lock and unlock
* horn and lights
* window operations
* charging settings
* charging or climate schedules
* other provider-specific vehicle functions

Sensitive operations can require local device-owner authentication using Touch ID or the Mac password.

Remote controls are never assumed to work simply because a model appears in the supported-vehicle list.

### Command status

Vehicle commands are often asynchronous.

A backend accepting a request does not necessarily mean the physical vehicle has already completed it. Hisingen uses the command result reported by the provider where possible and follows commands with updated vehicle state instead of treating every HTTP or backend acknowledgement as final proof of execution.

### Polestar controls

Polestar controls rely on undocumented vehicle-cloud interfaces and are therefore more likely to change without notice.

Capability availability also differs substantially between Polestar models.

For example, climate temperature selection should not be assumed to exist on a Polestar 2 simply because newer models expose more detailed climate controls.

### Volvo controls

Volvo uses documented Connected Vehicle API commands.

Command availability can depend on:

* vehicle model
* model year
* region
* Volvo account
* Developer application
* subscribed API products
* granted OAuth scopes
* vehicle state

Some command scopes require additional approval from Volvo Cars.

## Location & Weather

Location-related features are optional.

### Vehicle Location

When **Vehicle Location** is enabled, Hisingen can retrieve the latest location reported by the provider and use Apple's system services to turn those coordinates into a readable location.

The current vehicle coordinates are not written to Hisingen's persistent vehicle-state cache.

Location represents the position last reported by the vehicle. It should not be treated as real-time tracking.

### Vehicle Weather

Weather is a separate optional feature.

When enabled, Hisingen can send the vehicle coordinates to Open-Meteo to retrieve weather for the vehicle's location.

If you do not want vehicle coordinates sent to Open-Meteo, leave Vehicle Weather disabled.

## Notifications

Hisingen can notify you about vehicle events without requiring the main interface to stay open.

Depending on enabled features and available vehicle data, notifications can include:

* charging started
* charging completed
* interrupted or failed charging
* low battery
* service or vehicle warnings
* tyre warnings
* software-update information
* authentication problems
* an unlocked parked vehicle
* rain or snow while an opening is reported open

Notification preferences can be configured in Settings.

A privacy mode is available for reducing the amount of vehicle information shown directly in notification banners.

## macOS Integration

Hisingen is designed as a native menu bar application rather than a wrapped web application.

### Menu Bar

The menu bar can show combinations of:

* battery level
* range
* charging time
* charging power
* lock status
* an icon-only view

### Launch at Login

Hisingen can register itself using macOS' normal Login Items system.

### Keyboard Shortcuts

Keyboard shortcuts are available for common navigation and vehicle-switching actions.

Some global shortcuts require the normal macOS Accessibility permission.

### URL Scheme

Hisingen registers the `hisingen://` URL scheme for local automation.

Available actions include navigation and vehicle operations implemented by the app, such as opening Settings, refreshing vehicle state and copying the current VIN.

Remote actions still pass through Hisingen's normal capability and authorization checks.

### Shortcuts

Hisingen includes a read-only App Intent that can expose cached battery, range and charging information to Apple Shortcuts.

Remote vehicle operations should be performed through Hisingen's normal control paths rather than assuming that the presence of an App Intent means a vehicle command was executed.

## Multiple Vehicles

Hisingen supports accounts containing multiple vehicles.

Vehicle-specific information such as:

* cached vehicle state
* charging history
* charging baselines
* capability observations
* local nicknames

is kept separately for each VIN.

If both Polestar and Volvo are configured, the two providers keep separate authentication state and can be switched without mixing their credentials or vehicle data.

## Appearance & Languages

Hisingen supports:

* System appearance
* Light appearance
* Dark appearance
* multiple optional themes
* configurable distance units
* configurable fuel-volume units
* configurable fuel-economy units
* multiple interface languages

The application currently contains nine optional themes:

* Hisingen Glass
* Polestar Minimal
* Volvo Iron
* Nordic Night
* Aurora Borealis
* Swedish Gold
* Cyan Racing
* Gothenburg Forest
* Sand Dune

These are appearance choices only and do not imply affiliation with the brands referenced by some theme names.

## Installation

Hisingen requires **macOS 14 Sonoma or later**.

Published releases support:

* Apple Silicon
* Intel Macs

### Install a Release

1. Download `Hisingen.dmg` from the [latest release](https://github.com/NicolasKheirallah/Hisingen/releases/latest).
2. Open the disk image.
3. Drag **Hisingen.app** into **Applications**.
4. Open Hisingen.
5. Open **Settings** and choose your vehicle provider.

Published production releases are built as universal binaries, signed with a Developer ID certificate, notarized by Apple and stapled before publication.

SHA-256 checksums are published with the release artifacts.

## Polestar Setup

1. Open **Settings**.
2. Select **Polestar**.
3. Sign in using your Polestar account.
4. Select your vehicle if the account contains more than one.

Hisingen communicates directly with the services used for the Polestar integration. There is no Hisingen account or Hisingen authentication server in between.

Because the Polestar vehicle interfaces are undocumented, sign-in or vehicle functionality can occasionally require an application update when Polestar changes its services.

## Volvo Setup

Volvo support requires your own application in the Volvo Cars Developer Portal.

This is different from Polestar because Volvo's public APIs issue credentials to registered developer applications.

### 1. Create a Volvo Developer Application

Create an application through the Volvo Cars Developer Portal and add the API products required for the features you intend to use.

At minimum this normally includes the APIs used for vehicle and energy data.

Location is optional and requires the corresponding Location API access.

### 2. Register the OAuth Callback

Configure this callback URL for the application:

```text
https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html
```

Volvo requires an HTTP(S) OAuth callback.

Hisingen therefore uses a small static GitHub Pages bridge. Volvo redirects the OAuth response there and the page passes the response back to Hisingen through its local `hisingen://` URL scheme.

The callback page does not operate a Hisingen backend or account service.

### 3. Add Your Credentials to Hisingen

Enter the credentials for your Volvo Developer application in Hisingen Settings:

* Client ID
* Client Secret
* VCC API Key

Then choose **Sign In with Volvo ID** and complete authorization in your browser.

Sensitive secrets and session tokens that need to persist are stored locally using the macOS Keychain.

Some Volvo functionality, especially location and remote commands, may require additional products or OAuth scopes beyond basic read access.

For the full authentication flow, see [Authentication](docs/api/authentication.md).

## Privacy

Hisingen has:

* no advertising
* no analytics SDK
* no Hisingen telemetry service
* no Hisingen vehicle-data backend
* no Hisingen account system

Vehicle data is requested directly from the relevant vehicle provider.

### Credentials

Sensitive credentials and refresh tokens are stored in the macOS Keychain.

Keychain entries use `AfterFirstUnlockThisDeviceOnly`.

This means the credentials remain local to the Mac and do not sync through iCloud Keychain, while still allowing a menu bar application to refresh after the computer has been unlocked once following startup.

This should not be confused with Secure Enclave-backed key storage. Hisingen uses the macOS Keychain rather than claiming that ordinary account credentials are stored as Secure Enclave keys.

### Local Cache

Hisingen keeps a limited local cache so useful vehicle state can remain visible if the vehicle is asleep or temporarily unreachable.

The persisted cache can include information such as:

* VIN
* vehicle model
* battery and charging state
* range
* selected capability information
* local charging history

More sensitive or short-lived information is deliberately not kept in the persisted vehicle snapshot, including:

* current vehicle coordinates
* owner name
* registration number
* detailed location information

For the exact current behavior, see [Privacy](docs/security/privacy.md).

### External Services

Apart from Polestar or Volvo, Hisingen can contact a small number of external services for optional functionality:

| Service                        | Used for                              |
| ------------------------------ | ------------------------------------- |
| Apple system location services | Reverse geocoding vehicle coordinates |
| Open-Meteo                     | Weather at the vehicle location       |
| GitHub Releases                | Optional update checks                |
| GitHub Pages                   | Volvo OAuth callback bridge           |

Location-based services receive coordinates only when the corresponding feature is enabled.

No vehicle data is sent to a server operated by the Hisingen developer.

## Security

Hisingen handles sensitive information including account sessions, vehicle telemetry, VINs, location and remote vehicle operations.

Security-related implementation details are documented separately rather than hidden behind broad claims in this README.

See:

* [Security Policy](SECURITY.md)
* [Security Overview](docs/security/overview.md)
* [Privacy](docs/security/privacy.md)
* [Keychain Storage](docs/security/keychain.md)
* [Threat Model](docs/security/threat-model.md)

If you discover a vulnerability, please report it privately through the process in [SECURITY.md](SECURITY.md) rather than opening a public issue.

Do not include real credentials, access tokens or full VINs in public bug reports.

## Known Limitations

Hisingen depends on vehicle-cloud services that it does not control.

A few things are worth knowing before using it:

* Polestar's vehicle interfaces used by Hisingen are undocumented and can change without notice.
* Volvo API availability varies between vehicles, regions, applications and OAuth scopes.
* A supported vehicle does not imply support for every capability.
* Vehicle data can be delayed while a car is asleep or offline.
* Some values are not exposed by every provider.
* Location is the latest position reported by the vehicle, not guaranteed live tracking.
* Charging energy and cost calculations are estimates.
* Remote commands can be accepted by a backend before the vehicle has actually completed them.
* New vehicle software or backend changes can temporarily break functionality without a Hisingen code change.

Hisingen tries to expose uncertainty instead of presenting missing data as a successful result.

## Build From Source

Requirements:

* macOS 14 or later
* Swift 5.9 or later
* Xcode or compatible Command Line Tools

Clone the repository:

```bash
git clone https://github.com/NicolasKheirallah/Hisingen.git
cd Hisingen
```

Check the development environment:

```bash
make doctor
```

Run the normal deterministic CI suite:

```bash
make ci
```

Build the application:

```bash
make app
open Hisingen.app
```

Normal CI does not require a real vehicle account and does not send commands to a real vehicle.

Live integration testing is kept separate from the deterministic test suite.

See [Getting Started](docs/development/getting-started.md) for the contributor workflow.

## Documentation

The root README is intentionally focused on people who want to understand, install or contribute to Hisingen.

Detailed engineering documentation lives under [`docs/`](docs/README.md).

Useful starting points:

* [Documentation Index](docs/README.md)
* [Architecture](docs/architecture/overview.md)
* [Vehicle Capabilities](docs/domain/capability-matrix.md)
* [API Overview](docs/api/overview.md)
* [Polestar API](docs/api/polestar.md)
* [Volvo API](docs/api/volvo.md)
* [Authentication](docs/api/authentication.md)
* [Privacy](docs/security/privacy.md)
* [Security](docs/security/overview.md)
* [Testing](docs/testing/strategy.md)
* [Release Process](docs/operations/releases.md)
* [Changelog](changelog.md)

Keeping these details outside the README avoids maintaining multiple competing descriptions of the same architecture.

## Contributing

Issues and pull requests are welcome.

Before making a larger change:

1. read the [development guide](docs/development/getting-started.md)
2. run `make ci`
3. add or update tests for behavior you change where practical
4. keep vehicle-provider behavior capability-aware
5. avoid adding real credentials, tokens, VINs or captured personal vehicle data to tests or documentation

API integrations should fail conservatively. A backend response should not be interpreted as proof of functionality unless the response actually supports that conclusion.

## Credits

Hisingen is maintained by [Nicolas Kheirallah](https://github.com/NicolasKheirallah).

Thanks to everyone who tests the application across different vehicles, model years, markets and configurations. That feedback is particularly valuable because vehicle-cloud capabilities often vary beyond what model names alone suggest.

## License

Hisingen is released under the [MIT License](LICENSE).

## Disclaimer

Hisingen is independent open-source software.

It is **not affiliated with, endorsed by, sponsored by, or maintained by Polestar Performance AB or Volvo Car Corporation**.

Polestar and Volvo are trademarks of their respective owners and are referenced only to describe vehicle compatibility.

Use of the corresponding vehicle services remains subject to the terms, policies and availability of those providers.

See [Terms & Conditions](TERMS.md) for additional information.
