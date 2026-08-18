# Keychain

`Services/Persistence/Keychain.swift`.

## What's stored, and where

| Item | Keychain account | Service |
|---|---|---|
| Polestar password | `polestar-password` | `io.kheirallah.hisingen` |
| Polestar refresh token | `polestar-refresh-token` | `io.kheirallah.hisingen` |
| Volvo client secret, VCC API key, refresh token | `volvo-credentials-bundle` (one JSON blob: `{clientSecret, apiKey, sessionToken}`) | `io.kheirallah.hisingen` |

All items live under one `kSecAttrService` (`KeychainStore.app`). Isolation between Polestar and Volvo, and between the different Volvo secrets, is achieved by using distinct `kSecAttrAccount` values — not by using separate Keychain services. `Tests/HisingenTests/Unit/VolvoKeychainIsolationTests.swift` verifies this directly: deleting Polestar's session token leaves Volvo's untouched, and deleting Volvo's client secret leaves its API key untouched within the same bundle.

## Legacy migration

- **Polestar password:** `Preferences.migrateLegacyPassword()`, run once at every launch before anything else, reads an old plaintext `polestar_password` `UserDefaults` key; if present and Keychain doesn't already have a password, it's moved into Keychain. The `UserDefaults` key is deleted afterward regardless of whether the migration succeeded — so a Keychain write failure during migration silently loses the password (the user would need to re-enter it), rather than leaving a plaintext copy behind.
- **Volvo bundle:** `readVolvoBundle()` self-heals from three older single-purpose accounts (`volvo-client-secret`, `volvo-vcc-api-key`, `volvo-refresh-token`) into the current bundle format on first read, if the bundle account is empty but any legacy value exists.

## Accessibility level

Every write uses `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

**This is deliberate, and README.md/TERMS.md now say so.** `AfterFirstUnlockThisDeviceOnly` is weaker than `WhenUnlockedThisDeviceOnly` in one specific way: it only requires the device to have been unlocked *once since the last restart*, not that it be unlocked *at the moment of access* — so a background refresh can read these items while the screen is locked. That is precisely why it is used: a menu-bar app whose whole job is polling vehicle state on a timer cannot do that under `WhenUnlocked`, which would fail every refresh with the screen locked and force a re-authentication prompt on every wake. Both levels are `ThisDeviceOnly` (excluded from iCloud Keychain sync, never leaves the device via Apple's sync). The public-facing docs previously claimed the stricter level; they were corrected to match the code rather than the code tightened to match them.

## In-memory cache

`InMemorySecretCache` — a process-global singleton guarded by an `NSLock`, caching every secret after first read, invalidated on save/delete. It exists purely to avoid repeated `SecItemCopyMatching` calls (which have real, if small, per-call overhead) on every actor method that needs a token. It's keyed only by Keychain *account* name, not by `service` — see [architecture/technical-debt.md](../architecture/technical-debt.md#inmemorysecretcache-keyed-by-account-only-not-serviceaccount) for the collision risk this creates across `KeychainStore` instances with different services but the same account constants (currently latent, not triggered by any live code path).

## Draft credentials

`savePasswordDraft`/`readPasswordDraft`/`deletePasswordDraft` (and Volvo equivalents) exist in the API surface and are exercised by tests, but are currently no-op stubs that never actually persist anything. See [architecture/technical-debt.md](../architecture/technical-debt.md#keychain-draft-methods-are-dead-code).

## Error handling

`KeychainError.status(OSStatus)` wraps any Security-framework failure other than "item not found" (`errSecItemNotFound`, which is treated as a normal empty-read, not an error). `VehicleServiceError.map` converts any `KeychainError` into the generic `.secureStorage` case, surfaced to the user as "Hisingen couldn't update its protected Keychain session."

## What's deliberately *not* in the Keychain

- Vehicle telemetry, capability observations, charging history — all in `UserDefaults` via `VehicleStateStore`, never Keychain (they aren't secrets).
- The Volvo Client ID — a public OAuth client identifier, stored in `Preferences`/`UserDefaults`.
- Anything shared between the two brands — there is no cross-brand Keychain item; see [architecture/providers.md](../architecture/providers.md).
