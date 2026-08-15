# Terms & Conditions

_Last updated: 2026-08-15_

These terms cover use of **Hisingen**, a native macOS menu bar application for monitoring Polestar and Volvo vehicles. Hisingen is an independent, open-source personal project — not a company product — maintained by Nicolas Kheirallah. By downloading, installing, or using Hisingen, you agree to these terms.

## 1. What Hisingen Is

Hisingen is a menu bar utility that connects to **your own** Polestar and/or Volvo account to display vehicle telemetry (battery, range, charging state, locks, doors, diagnostics, and similar) directly in the macOS menu bar. It has no server, backend, or account system of its own — it talks directly to Polestar's and Volvo's own services using credentials you provide.

Hisingen is released under the [MIT License](LICENSE). The source code is publicly available; you're free to inspect exactly what it does.

## 2. Not Affiliated With Polestar or Volvo Cars

Hisingen is independent software and is **not affiliated with, endorsed by, or maintained by Polestar Performance AB or Volvo Car Corporation**. "Polestar" and "Volvo" are trademarks of their respective owners, referenced here only to describe compatibility. Use of Hisingen with either brand's services is subject to that brand's own terms of use, which you are responsible for reviewing and complying with independently of these terms.

## 3. Your Accounts and Credentials

- **Polestar**: you sign in with your own Polestar ID. Hisingen performs the sign-in flow directly against Polestar's identity service.
- **Volvo**: Volvo requires each application to register its own OAuth client. To use Volvo support, you must register your own free application at [developer.volvocars.com](https://developer.volvocars.com) and provide the resulting Client ID, Client Secret, and VCC API Key. You are responsible for that registration and for complying with Volvo Cars' own API Terms & Conditions for it.
- You are solely responsible for the security of your own account credentials, for any activity performed through your accounts, and for revoking access (via Polestar's or Volvo's own account settings) if you stop using Hisingen or suspect unauthorized access.

## 4. Data Handling

Hisingen has no analytics, advertising, telemetry, or relay backend of its own. Specifically:

- Credentials and session tokens are stored **locally on your Mac**, in the macOS Keychain, protected with `WhenUnlockedThisDeviceOnly` accessibility. Polestar and Volvo credentials are kept in entirely separate Keychain entries and are never sent to each other's services.
- Vehicle data is fetched directly from Polestar's or Volvo's own services and cached locally for offline display. Cached snapshots deliberately omit registration numbers, owner names, image data, raw coordinates, detailed health records, and schedule locations.
- Optional features send limited data to third parties only when you enable them:
  - **Vehicle Location** — coordinates to Apple's CoreLocation/Maps for reverse geocoding, if enabled.
  - **Vehicle Weather** — coordinates to Open-Meteo, if enabled.
  - **Update Checks** — app version to the GitHub Releases API, if enabled.
- No vehicle data, credentials, or usage data is collected by, or transmitted to, the developer of Hisingen at any point.

## 5. No Warranty

Hisingen is provided **"as is," without warranty of any kind**, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. Vehicle-cloud APIs (particularly Polestar's, which are undocumented and reconstructed from observed client behavior) can change without notice, and optional data may be inaccurate, delayed, missing, or unavailable at any time.

## 6. Remote Commands

Standard builds of Hisingen do not send remote commands to any vehicle. Where experimental command support exists, it is opt-in, excluded from standard/distributed builds, and unverified against live Volvo command endpoints. **You use any remote-command capability entirely at your own risk.** Hisingen does not guarantee that a command was received or executed by your vehicle, and treats a backend acknowledgment as confirmation of delivery only, not of execution.

## 7. Limitation of Liability

To the maximum extent permitted by law, the developer of Hisingen shall not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, vehicle access, vehicle state, or account access, arising from your use of, or inability to use, Hisingen — including damages resulting from third-party API changes, outages, unintended vehicle behavior triggered through a remote command, or account actions taken by Polestar or Volvo in response to Hisingen's use of their services.

## 8. Changes

These terms and Hisingen itself may change over time. Continued use after a change constitutes acceptance of the updated terms. Material changes will be reflected in this document's "Last updated" date and in the project's [changelog](changelog.md).

## 9. Termination

You may stop using Hisingen at any time by quitting the app, signing out, and/or revoking its access from your Polestar or Volvo account settings. Nothing in these terms restricts your right to do so.

## 10. Contact

Questions about these terms or about Hisingen: **Nicolas Kheirallah** — [github.com/NicolasKheirallah](https://github.com/NicolasKheirallah).
