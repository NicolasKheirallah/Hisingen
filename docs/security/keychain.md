# Keychain

`Services/Persistence/Keychain.swift`.

## What's stored, and where

| Item | Keychain account | Service |
|---|---|---|
| Polestar account email | `polestar-email` | `io.kheirallah.hisingen` |
| Polestar password | `polestar-password` | `io.kheirallah.hisingen` |
| Polestar refresh token | `polestar-refresh-token` | `io.kheirallah.hisingen` |
| Volvo client secret, VCC API key, refresh token | `volvo-credentials-bundle` (one JSON blob: `{clientSecret, apiKey, sessionToken}`) | `io.kheirallah.hisingen` |

All items live under one `kSecAttrService` (`KeychainStore.app`). Isolation between Polestar and Volvo, and between the different Volvo secrets, is achieved by using distinct `kSecAttrAccount` values — not by using separate Keychain services. `Tests/HisingenTests/Unit/VolvoKeychainIsolationTests.swift` verifies this directly: deleting Polestar's session token leaves Volvo's untouched, and deleting Volvo's client secret leaves its API key untouched within the same bundle.

## Legacy migration

- **Polestar password:** `Preferences.migrateLegacyPassword()`, run once at every launch before anything else, reads an old plaintext `polestar_password` `UserDefaults` key; if present and Keychain doesn't already have a password, it's moved into Keychain. The `UserDefaults` key is removed only after the Keychain read/write path succeeds; a Keychain failure retains the legacy value so migration can be retried.
- **Polestar email:** the `Preferences.email` and `PreferencesStore.email`
  getters migrate the legacy `polestar_email` `UserDefaults` value into the
  `polestar-email` Keychain account. The cleartext value is removed only after a
  successful Keychain write; new email values are never written to
  `UserDefaults`.
- **Volvo bundle:** `readVolvoBundle()` self-heals from three older single-purpose accounts (`volvo-client-secret`, `volvo-vcc-api-key`, `volvo-refresh-token`) into the current bundle format on first read, if the bundle account is empty but any legacy value exists.

## Accessibility level

Every write uses `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

**This is deliberate, and README.md/TERMS.md now say so.** `AfterFirstUnlockThisDeviceOnly` is weaker than `WhenUnlockedThisDeviceOnly` in one specific way: it only requires the device to have been unlocked *once since the last restart*, not that it be unlocked *at the moment of access* — so a background refresh can read these items while the screen is locked. That is precisely why it is used: a menu-bar app whose whole job is polling vehicle state on a timer cannot do that under `WhenUnlocked`, which would fail every refresh with the screen locked and force a re-authentication prompt on every wake. Both levels are `ThisDeviceOnly` (excluded from iCloud Keychain sync, never leaves the device via Apple's sync). The public-facing docs previously claimed the stricter level; they were corrected to match the code rather than the code tightened to match them.

## In-memory cache

`InMemorySecretCache` — a process-global singleton guarded by an `NSLock`,
caching every secret after first read and invalidated on save/delete. Cache keys
combine the Keychain service and account, so isolated test services cannot
collide with production items.

## Draft credentials

`savePasswordDraft`/`readPasswordDraft`/`deletePasswordDraft` and the Volvo
equivalents use separate Keychain accounts from committed credentials. Tests
verify that deleting a draft cannot delete or replace its committed value.

## Error handling

`KeychainError.status(OSStatus)` wraps any Security-framework failure other than "item not found" (`errSecItemNotFound`, which is treated as a normal empty-read, not an error). `VehicleServiceError.map` converts any `KeychainError` into the generic `.secureStorage` case, surfaced to the user as "Hisingen couldn't update its protected Keychain session."

## What's deliberately *not* in the Keychain

- Vehicle telemetry, capability observations, and charging history — stored in the local SQLite database via `VehicleStateStore`, never Keychain (they aren't credentials).
- The Volvo Client ID — a public OAuth client identifier, stored in `Preferences`/`UserDefaults`.
- Anything shared between the two brands — there is no cross-brand Keychain item; see [architecture/providers.md](../architecture/providers.md).
