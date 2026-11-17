# Install Hisingen and connect your car

[Documentation](README.md) · [Polestar setup](#polestar-setup) · [Volvo setup](#volvo-setup) · [Verify a download](#verify-the-download-checksum)

## Installation

Hisingen runs on macOS 15 Sequoia or later on Apple Silicon and Intel Macs.

### Homebrew

```bash
brew install --cask nicolaskheirallah/tap/hisingen
```

Run `brew upgrade --cask hisingen` to update.

### Disk image

1. [Download the latest `Hisingen.dmg`](https://github.com/NicolasKheirallah/Hisingen/releases/latest/download/Hisingen.dmg).
2. Open the disk image.
3. Drag **Hisingen.app** into **Applications**.
4. Open Hisingen.
5. Open **Settings** and connect your vehicle account.

Hisingen checks for signed updates daily by default. To check now, choose **Hisingen → Check for Updates…**.

### Code signing

The release workflow signs Hisingen.app and Hisingen.dmg with Developer ID, notarizes both and
staples Apple's tickets. Each release includes SHA-256 checksums and GitHub build attestations.
[Release process](operations/releases.md)

### Verify the download checksum

Every release publishes a `SHA256SUMS` file covering all artifacts. To verify:

```bash
shasum -a 256 -c SHA256SUMS
```

Run this in the folder containing the downloaded files. It should report `OK` for each one.

### Verify the signature

macOS checks the signature and notarization at first launch. To verify the installed app from Terminal, run:

```bash
spctl -a -t exec -vv /Applications/Hisingen.app
```

The expected result is `accepted` with `source=Notarized Developer ID`. If verification fails or
macOS reports a damaged app or unidentified developer, download a fresh copy and verify its checksum.

[View all releases](https://github.com/NicolasKheirallah/Hisingen/releases)

## Polestar setup

Hisingen supports three connection modes for Polestar vehicles:

### Polestar ID

1. Open **Settings** → **Polestar**.
2. Keep the mode set to **Polestar ID**.
3. Sign in with your Polestar account email and password.
4. If Polestar asks for another sign-in step, complete it in the window that opens.

### Developer Portal (EU Data Act M2M)

For developers and fleet managers with credentials from the official [Polestar Developer Portal](https://data-portal.polestar.com/):

1. Open **Settings** → **Polestar**.
2. Select **Developer Portal**.
3. Enter your **Account ID** (`x-client-id`), **Client ID**, and **Client Secret**.
4. Click **Test Connection** to verify OAuth token issuance and vehicle discovery.
5. Click **Save & Connect**.

Developer Portal mode gives you battery, charging, exterior status, health, odometer and location
readings. Remote controls need Polestar ID or Augmented mode. Use the client ID and secret from
the same application.

Polestar allows 10,000 API requests per day. Hisingen budgets up to 9,000 and shows the projected
count in Settings.

### Augmented

Select both **Developer Portal** and **Polestar ID** in the account form, enter both sets of
credentials and save. This enables Augmented mode. Hisingen reads telemetry from the portal
and uses the Polestar ID session for supported commands and the live stream.

Remote commands also need the extra authorization step described under
[Remote controls](remote-controls.md#authorizing-remote-commands-polestar).

## Volvo setup

### Sign in with Volvo ID

1. Open **Settings**.
2. Select **Volvo**.
3. Choose **Sign In with Volvo ID** and complete authentication in your browser.

Hisingen supplies the default developer credentials. The browser handles your Volvo ID password.
Hisingen saves persistent session credentials in the macOS Keychain.

### Use your own developer application

To use your own API quota, choose **Custom App** in the Volvo section of Settings.

1. Create an application in the [Volvo Developer Portal](https://developer.volvocars.com/). Enable Connected Vehicle and Energy, plus Location if you want to see where your car last parked.
2. Add this exact OAuth callback URL to your application:

   ```text
   https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html
   ```

   The GitHub Pages callback passes the authorization result back to the installed app through
   the `hisingen://` URL scheme.
3. Enter your **Client ID**, **Client Secret** and **VCC API Key** in Settings, then sign in.

You can switch back to the built-in credentials at any time with **Use Default Developer Keys**.

Some features, particularly location and remote operations, depend on the permissions approved for whichever developer application is in use.

For the technical details, see [Authentication](api/authentication.md).
