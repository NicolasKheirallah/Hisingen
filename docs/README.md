# Hisingen documentation

Hisingen is a native macOS menu bar app for Polestar and Volvo. The app uses AppKit and SwiftUI. Vehicle requests go from your Mac to the vehicle provider.

[Hisingen README](../README.md) · [Changelog](../CHANGELOG.md) · [Contributing](../CONTRIBUTING.md)

## User guides

| Guide | What it covers |
| --- | --- |
| [Install and connect your car](install.md) | Homebrew, signed downloads, updates, Polestar account modes and Volvo ID. |
| [Product tour](product-tour.md) | Sample screenshots of Now, Plan, Log, Car, charger integrations and Settings. |
| [Vehicle support and readings](vehicle-features.md) | Recognised models, battery and fuel, climate, trips, location, software and diagnostics. |
| [Remote controls](remote-controls.md) | Commands by brand, vehicle capabilities, authorization, routines, Retry and Undo. |
| [Home charging and electricity prices](home-charging.md) | NexBlue, Easee, Zaptec, Home Assistant, Tibber, fees, tariffs and charging plans. |
| [Using Hisingen](using-hisingen.md) | Garage, notifications, macOS integration, themes, layout, backups and privacy. |
| [Help](help.md) | Sign-in problems, stale readings, missing features, known limitations and issue reporting. |

## Developer reference

Start with the [development setup](development/getting-started.md) and [repository layout](development/repository-layout.md). For local builds, CI commands and signing, see [building and validating Hisingen](operations/build.md).

- The [architecture overview](architecture/overview.md) maps the app. [Components](architecture/components.md), [runtime](architecture/runtime.md), [data flow](architecture/data-flow.md) and [state management](architecture/state-management.md) explain how it runs.
- The [API overview](api/overview.md) covers [authentication](api/authentication.md) and [errors and rate limits](api/errors-and-rate-limits.md). See the [Polestar integration](api/polestar.md), [Volvo integration](api/volvo.md) and [field mappings](api/field-mappings.md) for provider calls and decoded fields.
- The [vehicle domain](domain/vehicle.md) defines the shared models. See the [capability matrix](domain/capability-matrix.md), [charging](domain/charging.md), [notifications](domain/notifications.md) and the [glossary](glossary.md).
- The [security overview](security/overview.md), [threat model](security/threat-model.md), [Keychain](security/keychain.md), [privacy architecture](security/privacy.md) and [data retention](data-retention.md) explain where credentials and readings go.
- The [test strategy](testing/strategy.md), [CI](operations/ci.md), [releases](operations/releases.md), [updater](updater-architecture.md) and [maintainer runbooks](operations/troubleshooting.md) cover validation and operations.

### Architecture by area

| Area | Reference |
| --- | --- |
| App boundaries | [System context](architecture/system-context.md), [Providers](architecture/providers.md), [Architecture decisions](adr/README.md) |
| Vehicle updates | [Capabilities](architecture/capabilities.md), [Refresh system](architecture/refresh-system.md), [Concurrency](architecture/concurrency.md) |
| Local data | [Persistence](architecture/persistence.md), [Logging](architecture/logging.md), [Themes and caching](architecture/theme-and-caching-architecture.md) |
| Interface | [Design](../DESIGN.md), [Motion system](architecture/motion-system.md), [Vehicle motion](architecture/vehicle-motion.md) |
| Contributions | [Development workflow](development/development-workflow.md), [Adding a feature](development/adding-a-feature.md), [Adding a provider](development/adding-a-provider.md) |

[Project history and credits](project.md) · [Security reporting](../SECURITY.md)
