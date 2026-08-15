# Security Policy

Hisingen stores Polestar/Volvo authentication tokens in the macOS Keychain and
handles vehicle location and telemetry data. Please report vulnerabilities
privately rather than opening a public issue.

## Reporting a vulnerability

Use [GitHub Security Advisories](https://github.com/NicolasKheirallah/Hisingen/security/advisories/new)
to report a vulnerability privately. Include:

- A description of the issue and its impact.
- Steps to reproduce, if possible.
- The Hisingen version and macOS version affected.

Please do not include real account credentials, tokens, or VINs in a report —
describe the issue and, if needed, share sanitized examples.

## Scope

In scope:

- Credential/token handling and Keychain storage (`Sources/Hisingen/Services/Persistence/Keychain.swift`).
- OAuth/PKCE flows for Polestar and Volvo sign-in.
- Data persisted to disk, including whether it retains GPS/VIN/owner data it shouldn't.
- The release pipeline: code signing, notarization, and the integrity of published artifacts.

Out of scope:

- Vulnerabilities in the Polestar or Volvo APIs themselves — report those to
  the respective vendor.
- Issues that require physical access to an already-unlocked machine.

## Supported versions

Only the latest published release is supported. Please update before reporting
an issue you haven't reproduced on the latest version.
