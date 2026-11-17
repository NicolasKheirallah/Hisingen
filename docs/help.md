# Help with Hisingen

[Troubleshooting](#troubleshooting) · [Known limitations](#known-limitations) · [Report an issue](#support) · [Documentation](README.md)

## FAQ

**Do I need a Hisingen account?**
No. There is no Hisingen account, no subscription and no middleman server.

**What do I need to connect a Volvo?**
Sign in with Volvo ID. Hisingen supplies the default developer credentials. [Volvo setup](install.md#volvo-setup)

**Is Hisingen affiliated with Polestar or Volvo?**
No. It's independent open-source software. See the [Disclaimer](../README.md#disclaimer).

**Can using Hisingen affect my vehicle account?**
The Volvo integration uses APIs designed for third-party developers. The Polestar integration uses undocumented interfaces, which means it can break without notice and may be viewed by the provider as a terms-of-service matter. Treat Polestar remote controls as experimental and use at your own discretion.

**How fresh is the vehicle data?**
Hisingen displays the latest readings it has received. Check the last-updated time in the app.

**Does Hisingen update while my Mac is asleep?**
The app refreshes while your Mac is awake. A submitted Home Assistant plan or a timer saved to NexBlue can still run from the charger integration. [Home charging](home-charging.md)

**Where is my data stored?**
Vehicle history lives on your Mac and credentials live in the macOS Keychain. [Privacy](using-hisingen.md#privacy)

**Can I mix Polestar and Volvo cars in one garage?**
Yes. History and caches are kept per vehicle, and each brand has its own sign-in.

**Is Hisingen free?**
Yes, MIT-licensed open source. [Build it yourself](operations/build.md) if you prefer.

## Troubleshooting

### The car is showing old information

Parked or sleeping cars can stop sending fresh telemetry. Hisingen keeps the last useful
reading and shows when the car reported it.

### A feature is missing

Not every model exposes the same online functionality.

Availability can depend on:

* vehicle model
* model year
* vehicle software
* region
* account
* provider service
* API permissions (mainly relevant when using your own Volvo developer application)

### Polestar suddenly stopped updating

The interfaces used by the Polestar integration aren't a supported public third-party API and can change.

Check the [latest release](https://github.com/NicolasKheirallah/Hisingen/releases/latest) and [existing issues](https://github.com/NicolasKheirallah/Hisingen/issues) first.

### Volvo sign-in isn't working

If you're using the built-in default credentials:

* make sure you're running the [latest release](https://github.com/NicolasKheirallah/Hisingen/releases/latest)
* complete sign-in in the browser window that opens; allow pop-ups if your default browser blocks them
* try again later; temporary gateway issues on Volvo's side do happen

If you're using your own developer application, check that:

* Client ID is correct
* Client Secret is correct
* VCC API Key is correct
* the required API products are enabled
* the callback URL matches exactly
* the application has the permissions required for the feature you're trying to use

### A remote control isn't available

Make sure the feature is enabled, then check whether your car and account support the command.
The command guide lists the permissions and sign-in steps for each brand. [Remote controls](remote-controls.md)

## Known limitations

Hisingen depends on vehicle services it doesn't control.

* Polestar's vehicle interfaces can change without notice.
* Volvo API availability varies between vehicles, regions and Developer applications.
* A recognized vehicle model doesn't mean every feature has been tested on every model year.
* Parked or sleeping vehicles can report older data.
* Some information simply isn't exposed by every vehicle.
* Location is the latest reported position, not guaranteed live tracking.
* Vehicle-based charging energy and costs are estimates. A paired charger can supply measured energy.
* Some Polestar fields are decoded from the app's published protobuf schema and captured frames,
  not from documentation. A few are unconfirmed, and anything Hisingen cannot name is kept as a
  raw field you can inspect on the Car tab under Unwired Backend Fields.
* The Polestar Android app version Hisingen reports to the app-backend endpoint has to stay
  current, or that discovery source answers 426. Hisingen then stands down for a day and falls
  back to the main discovery source.
* A cloud service can accept a remote command before the physical vehicle completes it.
* Experimental remote functionality shouldn't be relied on for safety-critical or time-critical use.

## Support

* Found a bug? → [bug report template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=bug_report.md)
* Missing a feature? → [feature request template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=feature_request.md)
* Tested Hisingen with an unusual model, year or region? → [vehicle compatibility template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=vehicle_compatibility.md); this is one of the most useful contributions there is
* Security issue? → [responsible disclosure via SECURITY.md](../SECURITY.md)

Please check the [Troubleshooting](#troubleshooting) section and [existing issues](https://github.com/NicolasKheirallah/Hisingen/issues) before opening a new one.
