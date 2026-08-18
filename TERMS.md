# Hisingen Terms of Use

*Last updated: 2026-08-18*

These Terms of Use apply to official builds of **Hisingen**, a free and open-source native macOS application maintained by Nicolas Kheirallah.

Hisingen lets you view information from, and where supported control, compatible Polestar and Volvo vehicles directly from your Mac.

Hisingen is an independent personal open-source project. It is not a product or service of Polestar or Volvo Cars.

## 1. What Hisingen Is

Hisingen is a local macOS application.

**Hisingen has no backend server, cloud service, relay, account system, telemetry platform, analytics service, or developer-operated infrastructure that handles your vehicle data.**

The application running on your Mac communicates directly with the relevant services operated by Polestar or Volvo Cars.

Vehicle information is fetched from the manufacturer and processed locally on your Mac. It is not routed through a Hisingen server because no such server exists.

Some optional features may communicate directly with other services, as described in [PRIVACY.md](PRIVACY.md).

## 2. Open-Source Licence

Hisingen is released under the [MIT License](LICENSE).

The MIT License governs your rights to use, copy, modify, merge, publish, distribute, sublicense, sell, fork, or otherwise create derived versions of the Hisingen source code.

Nothing in these Terms is intended to restrict or replace any right granted under the MIT License.

These Terms instead describe the use of official Hisingen builds and their interaction with manufacturer and third-party services.

A fork, modified build, repackaged version, or version distributed by someone other than the Hisingen maintainer may behave differently. The Hisingen maintainer does not control and is not responsible for those versions.

## 3. Independent Software

Hisingen is not affiliated with, endorsed by, sponsored by, approved by, or maintained by **Polestar Performance AB** or **Volvo Car Corporation**.

"Polestar", "Volvo", "Volvo Cars", and other manufacturer names or marks are used only where necessary to describe compatibility and the services Hisingen communicates with.

Your relationship with Polestar or Volvo Cars remains separate from your use of Hisingen.

Manufacturer accounts, connected services, APIs and other services remain subject to the applicable terms, policies and restrictions of the relevant manufacturer.

## 4. Your Account and Vehicle

Only use Hisingen with accounts and vehicles that you own or are otherwise authorized to access and control.

You must not use Hisingen to:

* access another person's account or vehicle without authorization;
* use credentials you are not authorized to use;
* bypass authentication or other access controls;
* interfere with manufacturer systems or services; or
* use vehicle data or remote functions for an unlawful purpose.

If a vehicle is shared, leased, company-owned or part of a fleet, you are responsible for making sure you have the necessary authority to access its information and use its remote functions.

## 5. Polestar

Hisingen signs in using your Polestar account and communicates directly from your Mac with Polestar-operated services.

Hisingen uses these services to retrieve information made available for vehicles associated with your account and, where supported, to perform vehicle functions.

Some Polestar interfaces used by Hisingen are not offered as documented public third-party APIs. They have been implemented based on the behaviour of Polestar's own services and clients and may change, stop working, become restricted, or behave differently without notice.

The fact that an interface is undocumented does not by itself determine whether its use is permitted or prohibited. Your use of Polestar services remains subject to the terms and technical controls applicable to those services.

Hisingen does not claim to provide an official Polestar integration.

## 6. Volvo Cars

Hisingen communicates directly from your Mac with Volvo Cars' identity services and APIs.

Volvo support uses Volvo Cars' OAuth authorization and developer APIs.

Depending on the Hisingen build and configuration, Volvo access may use developer application credentials configured for Hisingen or credentials provided through a custom Volvo developer application.

If you register or configure your own application through the Volvo Cars Developer Portal, your use of that application and its credentials is separately subject to Volvo Cars' Developer Portal and API terms.

Hisingen does not claim to provide an official Volvo Cars integration unless Volvo Cars expressly states otherwise.

## 7. Credentials and Authentication

Authentication information required by Hisingen is handled locally by the application and the relevant manufacturer services.

Sensitive credentials and refresh tokens retained by Hisingen are stored locally using the macOS Keychain.

Hisingen currently uses the `AfterFirstUnlockThisDeviceOnly` Keychain accessibility class for stored secrets. This allows Hisingen to continue accessing the required Keychain items after the Mac has been unlocked following a restart, including while the screen is subsequently locked.

`ThisDeviceOnly` Keychain items are not intended to synchronise through iCloud Keychain.

Polestar and Volvo authentication information is stored separately.

Access tokens that do not need to survive an application restart may be held only in memory.

See [PRIVACY.md](PRIVACY.md) for a more detailed description of authentication and local storage.

## 8. Vehicle Data

Depending on the vehicle, provider and enabled features, Hisingen may process information including:

* VIN;
* model and model year;
* battery level and range;
* charging state and charging information;
* locks, doors and windows;
* climate information;
* diagnostics and warnings;
* service and software information;
* charging history;
* schedules;
* vehicle capabilities;
* vehicle location; and
* information related to remote commands.

This information originates from manufacturer services and is processed by the Hisingen application on your Mac.

Hisingen may keep a limited local cache so that some previously retrieved information can still be displayed when a vehicle or manufacturer service is temporarily unavailable.

Not every type of information retrieved from a manufacturer is written to that cache.

Details about what Hisingen stores locally and what information may be sent to optional external services are maintained in [PRIVACY.md](PRIVACY.md).

## 9. No Hisingen Data Collection

Hisingen does not send vehicle telemetry, account credentials or usage analytics to the Hisingen maintainer.

There is no Hisingen backend collecting this information.

The maintainer therefore does not ordinarily receive information such as:

* your vehicle telemetry;
* your VIN;
* your vehicle location;
* your Polestar or Volvo credentials;
* your remote-command history; or
* information about how you use Hisingen.

You may, of course, voluntarily provide information to the maintainer when opening a GitHub issue, submitting diagnostics, sending an email or otherwise asking for support.

Do not include passwords, access tokens, refresh tokens, API secrets or other sensitive information in public issue reports.

## 10. Other Services

Certain Hisingen features may communicate directly with services other than Polestar or Volvo Cars.

Depending on the features you enable, these can include:

### Apple

When vehicle location functionality is enabled, Hisingen may use Apple's location and geocoding services to turn vehicle coordinates into a human-readable location.

### Open-Meteo

When vehicle weather functionality is enabled, Hisingen may send the vehicle's latitude and longitude directly to Open-Meteo to retrieve weather information for that location.

Hisingen does not need to send your VIN or manufacturer account credentials with that weather request.

### GitHub

Hisingen may contact GitHub to check for available Hisingen releases.

Volvo authentication may also use a static GitHub Pages redirect page to pass the OAuth callback from the browser back to the Hisingen application.

This static page is not a Hisingen backend, relay or application server. It does not process vehicle telemetry on behalf of Hisingen.

These services operate independently and are subject to their own terms and privacy practices.

## 11. Remote Vehicle Controls

Hisingen can send remote commands where the vehicle, manufacturer service and current Hisingen implementation support them.

Available commands vary between manufacturers, vehicle models, model years, software versions, accounts and regions.

Depending on the vehicle, functionality can include operations such as:

* starting or stopping climate control;
* locking or unlocking the vehicle;
* opening, closing or unlocking supported doors, windows, trunks or tailgates;
* flashing lights or sounding the horn;
* changing supported charging settings;
* starting or stopping charging-related functions;
* managing supported charging or climate schedules;
* starting or stopping an engine where supported; and
* performing other vehicle functions exposed by the applicable manufacturer service.

Some functionality is not implemented due to not having any documented API, all other API's are documnented.

Remote commands have real-world effects.

Before confirming a command, make sure that:

* the correct vehicle is selected;
* the requested action is appropriate;
* nobody could be put at risk by the action; and
* you are authorized to control the vehicle.

Security-sensitive actions may require additional confirmation or local device-owner authentication.

## 12. Command Results

A response from a manufacturer service does not necessarily prove that the physical vehicle completed the requested action.

A command may be:

* accepted by a backend but not yet delivered;
* delivered but not executed;
* delayed;
* rejected by the vehicle;
* prevented by the vehicle's current state;
* affected by connectivity;
* affected by manufacturer service availability; or
* reported differently from the eventual physical result.

Hisingen may display the best status available from the manufacturer service, but you should verify important actions when necessary.

In particular, do not assume that a displayed acknowledgement conclusively proves that a vehicle has locked, unlocked, started charging, stopped charging, changed climate state or completed another physical action.

## 13. Vehicle Information May Be Delayed or Incorrect

Hisingen displays information received from third-party manufacturer services.

That information may sometimes be:

* delayed;
* stale;
* incomplete;
* temporarily unavailable;
* inconsistent between manufacturer services; or
* incorrect.

This can affect information such as:

* lock status;
* door or window status;
* vehicle location;
* battery percentage;
* estimated range;
* charging state;
* charging completion estimates;
* climate status;
* diagnostics;
* software information; and
* remote-command status.

Hisingen should not be treated as a safety-critical system.

Where information matters for the safety, security or operation of the vehicle, verify it using the vehicle itself or an appropriate manufacturer-provided interface.

## 14. Manufacturer Services Can Change

Hisingen depends on services that the project does not control.

Polestar, Volvo Cars and other providers may change:

* APIs;
* authentication flows;
* endpoints;
* permissions;
* data formats;
* rate limits;
* account requirements;
* vehicle capabilities;
* available commands; or
* access to their services.

Such changes may cause individual Hisingen features, or the application as a whole, to stop working temporarily or permanently.

Hisingen does not guarantee continued compatibility with any manufacturer, vehicle or external service.

## 15. No Warranty

Hisingen is provided under the warranty disclaimer contained in the MIT License and is provided **"as is"** and **"as available"**.

There is no guarantee that Hisingen will:

* operate without errors;
* remain available;
* remain compatible with manufacturer services;
* support every vehicle or configuration;
* provide complete or current information;
* successfully perform a remote command; or
* continue providing any particular feature.

No commitment is made to provide support, maintenance, updates or continued development.

## 16. Limitation of Liability

To the extent permitted by applicable law, the Hisingen maintainer is not liable for indirect or consequential loss arising from use of, or inability to use, Hisingen.

This includes loss arising from matters such as:

* inaccurate, incomplete or delayed vehicle information;
* manufacturer API or service changes;
* service outages;
* authentication failures;
* loss of manufacturer account access;
* rate limiting or access restrictions;
* remote commands that fail, are delayed or produce an unexpected result; or
* incompatibility between Hisingen and a vehicle or manufacturer service.

Nothing in these Terms excludes or limits liability where such exclusion or limitation is not permitted by applicable law.

## 17. Your Account

Your Polestar or Volvo account is controlled by the relevant manufacturer, not by Hisingen.

Hisingen cannot guarantee that use of third-party software will always be accepted by a manufacturer or that a manufacturer will continue allowing access through a particular service or interface.

The Hisingen maintainer cannot:

* restore a suspended manufacturer account;
* change manufacturer account permissions;
* restore an expired or revoked manufacturer service;
* override manufacturer rate limits;
* require a manufacturer to maintain an API; or
* guarantee continued access to undocumented or unsupported functionality.

## 18. Stopping Use

You can stop using Hisingen at any time.

You may:

* sign out of a manufacturer account in Hisingen;
* remove locally stored Hisingen authentication information;
* remove locally stored Hisingen data;
* revoke manufacturer-side access where the manufacturer provides a mechanism for doing so; and
* uninstall Hisingen.

Hisingen has no developer-controlled user account or subscription that needs to be cancelled.

The maintainer also has no Hisingen backend through which access to your vehicle can be independently enabled or disabled.

## 19. Changes to Hisingen

Hisingen is under active development and its functionality may change.

Features may be added, changed or removed, particularly where manufacturer services change.

Experimental or newly discovered functionality may behave differently between vehicles and may later be changed or removed if it proves unreliable, unsafe or incompatible with manufacturer services.

## 20. Changes to These Terms

These Terms may be updated when Hisingen's functionality, technical architecture or legal environment changes.

The current version will be published in the Hisingen repository with an updated revision date.

Changes to these Terms do not modify or revoke rights already granted to the Hisingen source code under the MIT License.

## 21. Governing Law

These Terms are governed by Swedish law.

Nothing in these Terms is intended to exclude, restrict or waive any right or remedy that cannot lawfully be excluded or restricted.

Where mandatory law gives you rights regardless of these Terms, those rights continue to apply.

## 22. Contact

Hisingen is maintained by **Nicolas Kheirallah**.

Questions about Hisingen, these Terms or the project can be raised through the Hisingen GitHub repository:

**github.com/NicolasKheirallah/Hisingen**