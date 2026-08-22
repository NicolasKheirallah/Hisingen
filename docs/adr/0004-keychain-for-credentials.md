# ADR-0004: Keychain for renewable credentials, not UserDefaults

Status: Accepted

## Context

Hisingen stores Polestar's password/session token and Volvo's client secret,
VCC API key, session token, and refresh token
(`Services/Persistence/Keychain.swift`). These are exactly the kind of
long-lived secret that grants access to a real vehicle if leaked.

## Decision

Store all of it in the macOS Keychain via `KeychainStore`, under a single
service (`io.kheirallah.hisingen`) with separate accounts per credential —
`passwordAccount`/`sessionAccount` for Polestar, a Volvo secret bundle
(client secret, API key, session token) for Volvo — rather than in
`UserDefaults` or a plain file. Items are stored
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — chosen over the stricter
`WhenUnlocked` variant so a background refresh can still read credentials
after the Mac has been unlocked once since boot, without requiring the
session to still be unlocked at read time. See
[security/keychain.md](../security/keychain.md) for the full rationale; this
ADR previously stated the stricter `WhenUnlockedThisDeviceOnly` value, which
never matched the implementation.

## Alternatives considered

- **`UserDefaults`** — backed by a plaintext `.plist` on disk, readable by
  anything with filesystem access to the user's account. Unacceptable for
  vehicle-access credentials.
- **A custom encrypted file** — would require Hisingen to implement its own
  key management, which the Keychain already provides, tested, for free.

## Consequences

Credentials survive an app reinstall unless explicitly cleared, since the
Keychain persists independent of the app bundle. `ThisDeviceOnly`
accessibility means these specific items are excluded from iCloud Keychain
sync — a deliberate choice, since syncing vehicle credentials across devices
widens who/what can access a vehicle. Credentials are keyed by brand
account, not by VIN — see [0007](0007-vin-scoped-state.md) for why that's the
one place VIN-scoping deliberately doesn't apply. Slightly more boilerplate
than `UserDefaults` for the storage plumbing itself; see
[security/keychain.md](../security/keychain.md) for the full item layout.
