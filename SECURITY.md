# Security Policy

Hisingen communicates directly from the user's Mac with Polestar and Volvo services. It has no Hisingen-operated backend server, relay, account service, telemetry collector, or cloud database.

Because the application handles manufacturer authentication, vehicle telemetry, location data, and remote vehicle commands, security issues can have consequences beyond the Mac itself.

**Please report security vulnerabilities privately. Do not open a public GitHub issue for a vulnerability that could expose credentials, personal data, vehicle information, or remote-control functionality.**

## Reporting a Vulnerability

Use [GitHub Security Advisories](https://github.com/NicolasKheirallah/Hisingen/security/advisories/new) to report vulnerabilities privately.

Please include, where possible:

* a clear description of the issue;
* the potential security or privacy impact;
* affected Hisingen version or commit;
* affected macOS version;
* affected provider, such as Polestar or Volvo;
* steps to reproduce;
* whether user interaction is required;
* whether the issue affects telemetry, authentication, local data, or remote commands; and
* any suggested mitigation or fix you have identified.

Proof-of-concept code is welcome when it can be shared safely.

### Do not include real secrets

Do **not** include real:

* passwords;
* access tokens;
* refresh tokens;
* OAuth authorization codes;
* Volvo Client Secrets;
* VCC API keys;
* signing certificates or private keys;
* VINs;
* precise vehicle locations; or
* other personal or account information.

Use clearly fake or sanitized values instead.

If reproducing the issue genuinely requires sensitive information, describe that requirement in the private advisory first rather than attaching the secret.

## Security Model

Hisingen is a local macOS application.

Vehicle data is requested directly from Polestar or Volvo by the application running on the user's Mac and is processed locally.

Hisingen does not operate a backend through which vehicle traffic, credentials, telemetry, or remote commands are relayed.

Security reports that show Hisingen unintentionally breaking this boundary are considered particularly important.

Sensitive authentication material retained by the application is stored using the macOS Keychain. Other application state and limited vehicle information may be persisted locally where required for normal operation.

## In Scope

### Authentication and credentials

Issues involving:

* Polestar authentication;
* Volvo OAuth and PKCE flows;
* OAuth state or redirect validation;
* token acquisition or refresh;
* access-token or refresh-token handling;
* Keychain storage;
* credential separation between Polestar and Volvo;
* accidental credential disclosure;
* insecure handling of Volvo developer credentials;
* OAuth callback handling; and
* authentication session cleanup during sign-out.

Relevant implementation includes:

`Sources/Hisingen/Services/Persistence/Keychain.swift`

and the provider authentication implementations under:

`Sources/Hisingen/Services/API/`

### Remote vehicle commands

Security issues involving remote commands are in scope.

Examples include:

* a command being sent to the wrong VIN;
* authorization checks being bypassed;
* commands being available for the wrong account or vehicle;
* local confirmation or device-owner authentication being bypassed;
* command replay caused by Hisingen;
* unintended duplicate command execution caused by Hisingen;
* command parameters being changed or incorrectly validated;
* security-sensitive controls becoming available when they should not be;
* capability checks being bypassed;
* unsafe handling of command acknowledgements or completion state; and
* a remote-control feature remaining usable after sign-out.

This includes functionality such as locking and unlocking, climate control, windows, trunk or tailgate operations, lights and horn, charging controls, schedules, engine commands, software-related operations, and other supported vehicle functions.

Do not test remote commands against a vehicle or account that you do not own or have explicit authorization to control.

### Local data and privacy

Issues involving information written to disk or otherwise retained locally, including:

* precise GPS coordinates;
* VINs;
* registration numbers;
* owner or account information;
* vehicle telemetry;
* charging history;
* diagnostics;
* API responses;
* notification contents;
* temporary files;
* application caches;
* logs; and
* credentials accidentally stored outside the Keychain.

Reports showing that Hisingen persists information that it claims not to persist are in scope.

### External service boundaries

Issues involving information unexpectedly sent to services other than the intended manufacturer are in scope.

This includes Hisingen's use of:

* Polestar services;
* Volvo Cars services;
* Apple geocoding services;
* Open-Meteo;
* GitHub Releases; and
* the static GitHub Pages redirect used during Volvo authentication.

A report is especially relevant if Hisingen sends credentials, VINs, precise location information, vehicle telemetry, or other sensitive information to a service that does not need it.

### Provider isolation

Issues where information or authentication state from one provider can cross into another provider are in scope.

For example:

* Polestar credentials becoming available to Volvo code;
* Volvo credentials being sent to Polestar;
* state from one manufacturer being associated with a vehicle belonging to another;
* one provider's sign-out affecting or exposing the other's secrets unexpectedly.

### Local authorization

Issues involving Hisingen's protection of security-sensitive actions are in scope, including:

* bypassing required macOS authentication;
* incorrectly classifying a security-sensitive command as routine;
* performing a protected action without the expected confirmation;
* using stale authorization to execute a later protected command.

### Network security

Issues involving Hisingen's own networking implementation are in scope, including:

* insecure endpoint validation;
* unexpected clear-text communication;
* redirect handling vulnerabilities;
* request manipulation caused by Hisingen;
* authentication information being sent to an unintended host;
* insufficient validation of dynamically discovered authentication endpoints.

### Release and supply-chain security

Issues involving the integrity of official Hisingen releases are in scope, including:

* GitHub Actions workflows;
* build secrets;
* dependency integrity;
* release artifact integrity;
* code signing;
* notarization;
* signing certificates;
* accidental inclusion of development secrets;
* generated credential files;
* release validation; and
* differences between published source and distributed binaries.

Relevant tooling includes:

`Scripts/validate-release.sh`

and the workflows under:

`.github/workflows/`

## Vendor Vulnerabilities

A vulnerability that exists entirely within Polestar, Volvo Cars, Apple, GitHub, Open-Meteo, or another third-party service should normally be reported directly to that provider.

However, please report it to Hisingen as well if the Hisingen implementation:

* exposes the vulnerability to users in a new way;
* makes exploitation materially easier;
* handles the affected service unsafely;
* fails to enforce a security boundary that Hisingen controls;
* leaks information because of the third-party behaviour; or
* can reasonably mitigate the problem client-side.

Finding an undocumented manufacturer endpoint is not by itself a Hisingen security vulnerability.

## Out of Scope

The following are generally outside the scope of this policy:

* vulnerabilities entirely within Polestar or Volvo infrastructure that Hisingen does not cause or meaningfully amplify;
* general availability or outages of manufacturer services;
* manufacturer API changes or removed functionality;
* rate limiting imposed by a manufacturer;
* social-engineering attacks unrelated to Hisingen;
* attacks requiring an already-compromised operating system with unrestricted access to the user's session; and
* theoretical issues with no credible security or privacy impact.

Physical access is **not automatically out of scope**.

For example, a vulnerability that allows an attacker with limited local access to extract protected credentials, bypass macOS authentication, or perform a protected remote command may still be relevant.

## Responsible Testing

Security research must be performed only against systems, accounts, Macs, and vehicles that you own or are explicitly authorized to test.

Please avoid:

* accessing another user's vehicle or account;
* attempting to obtain another person's credentials;
* intentionally degrading manufacturer services;
* high-volume API probing;
* destructive tests against a vehicle;
* testing commands that could endanger people or property; and
* retaining personal information discovered accidentally.

If testing could cause a physical vehicle action, use the least disruptive method available.

## Supported Versions

Security fixes are provided for the **latest published Hisingen release**.

Before reporting an issue found in an older version, please verify that it is still reproducible in the latest release or current source where practical.

Reports concerning the current development branch are also welcome when the affected code has not yet been released.

## Credential Exposure and Rotation

Secrets used to build or operate Hisingen must never be committed to the repository, included in release artifacts, written to build logs, or included in diagnostic archives.

If Volvo Developer API credentials or another project secret may have been exposed:

1. treat the credential as compromised;
2. revoke or rotate the affected credential through the relevant provider;
3. replace the corresponding GitHub Actions secret or local build secret;
4. inspect repository history, workflow logs, release artifacts, and diagnostic files for further exposure;
5. remove exposed material where possible; and
6. run `Scripts/validate-release.sh` before producing another release.

Generated credential source files are build-local artifacts and must never be committed or distributed as source.

Removing a secret from the latest Git commit is **not sufficient** if the secret previously appeared in repository history or a published artifact. Rotate it.

## Disclosure

Please give the project a reasonable opportunity to investigate and fix a reported vulnerability before publishing technical details that could expose users.

No fixed response or remediation deadline is promised because Hisingen is an independently maintained open-source project.

Where appropriate, confirmed vulnerabilities may be documented through a GitHub Security Advisory and associated with a fixed release.

## Security Updates

Security fixes may be released as part of normal Hisingen releases or as dedicated security releases where the issue warrants it.

Users should normally run the latest published version of Hisingen, particularly when a release contains authentication, remote-control, privacy, or credential-handling changes.

## Contact

Security vulnerabilities should be reported through:

**[GitHub Security Advisories](https://github.com/NicolasKheirallah/Hisingen/security/advisories/new)**

For non-security bugs, feature requests, and general questions, use the normal Hisingen GitHub issue tracker.
