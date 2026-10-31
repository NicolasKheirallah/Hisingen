import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    enum PolestarConnectionMode: String, Codable, Sendable, CaseIterable {
        case polestarID
        case dataPortal
        case augmented

        var displayName: String {
            switch self {
            case .polestarID: return L10n.text("Polestar ID")
            case .dataPortal: return L10n.text("Developer Portal")
            case .augmented: return L10n.text("Augmented")
            }
        }

        var detailDescription: String {
            switch self {
            case .polestarID:
                return L10n.text("Sign in with your Polestar ID for remote controls, climate commands, and lock status.")
            case .dataPortal:
                return L10n.text("Connect with official EU Data Act M2M credentials for direct telemetry without a password.")
            case .augmented:
                return L10n.text("Pairs Developer Portal telemetry with your Polestar ID for interactive remote controls and gRPC streaming.")
            }
        }
    }

    nonisolated static var currentPolestarConnectionMode: PolestarConnectionMode {
        guard let raw = UserDefaults.standard.string(forKey: "polestar_connection_mode"),
              let mode = PolestarConnectionMode(rawValue: raw) else {
            return .polestarID
        }
        return mode
    }

    var email: String {
        get {
            if let cached = cachedEmail { return cached }
            do {
                if let secure = try keychain.readEmail(), !secure.isEmpty {
                    d.removeObject(forKey: "polestar_email")
                    cachedEmail = secure
                    return secure
                }
            } catch KeychainError.interactionRequired {
                // An ACL consent is pending and may be unanswerable from this context (a
                // background launch). Leave the cache unset: once the owner approves access,
                // the next read must actually retry instead of replaying a cached empty.
                return ""
            } catch {
                logger.error("Reading the account email from the Keychain failed; falling back to the legacy value: \(String(describing: error), privacy: .public)")
            }
            let legacy = d.string(forKey: "polestar_email")
            if let legacy, !legacy.isEmpty {
                // The legacy UserDefaults copy is removed only once the Keychain write succeeds.
                if !legacyEmailMigrationAttempted {
                    legacyEmailMigrationAttempted = true
                    do {
                        try keychain.saveEmail(legacy)
                        d.removeObject(forKey: "polestar_email")
                    } catch {
                        logger.error("Migrating the account email to the Keychain failed; the legacy value stays in UserDefaults until the next launch: \(String(describing: error), privacy: .public)")
                    }
                }
                cachedEmail = legacy
                return legacy
            }
            cachedEmail = ""
            return ""
        }
        set {
            let previous = cachedEmail
            cachedEmail = newValue
            cachedHasResumableSession[.polestar] = nil
            if newValue.isEmpty {
                do {
                    try keychain.deleteEmail()
                } catch {
                    logger.error("Deleting the account email from the Keychain failed: \(String(describing: error), privacy: .public)")
                }
                d.removeObject(forKey: "polestar_email")
            } else {
                do {
                    try keychain.saveEmail(newValue)
                    d.removeObject(forKey: "polestar_email")
                } catch {
                    // Never write a new account identifier to UserDefaults. Revert the cached
                    // value too, so in-session consumers don't rely on an email that will not
                    // survive relaunch.
                    cachedEmail = previous
                    logger.error("Saving the account email to the Keychain failed; it will not persist across launches: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    var activeBrand: VehicleBrand {
        get { VehicleBrand(rawValue: d.string(forKey: "active_vehicle_brand") ?? "") ?? .polestar }
        set { d.set(newValue.rawValue, forKey: "active_vehicle_brand"); syncAppThemeStorageKey() }
    }
    var polestarConnectionMode: PolestarConnectionMode {
        get {
            guard let raw = d.string(forKey: "polestar_connection_mode"),
                  let mode = PolestarConnectionMode(rawValue: raw) else {
                return .polestarID
            }
            return mode
        }
        set {
            d.set(newValue.rawValue, forKey: "polestar_connection_mode")
            cachedHasResumableSession[.polestar] = nil
        }
    }
    var polestarDataPortalAccountID: String {
        get { d.string(forKey: "polestar_dataportal_account_id") ?? "" }
        set {
            d.set(newValue, forKey: "polestar_dataportal_account_id")
            cachedHasResumableSession[.polestar] = nil
        }
    }
    var polestarDataPortalClientID: String {
        get { d.string(forKey: "polestar_dataportal_client_id") ?? "" }
        set {
            d.set(newValue, forKey: "polestar_dataportal_client_id")
            cachedHasResumableSession[.polestar] = nil
        }
    }
    var volvoClientID: String {
        get { d.string(forKey: "volvo_client_id").flatMap { $0.isEmpty ? nil : $0 } ?? BuiltinVolvoSecrets.clientID }
        set { d.set(newValue, forKey: "volvo_client_id"); cachedHasResumableSession[.volvo] = nil }
    }
    var volvoRestrictedScopesEnabled: Bool {
        get { d.bool(forKey: "volvo_restricted_scopes_enabled") }
        set { d.set(newValue, forKey: "volvo_restricted_scopes_enabled") }
    }
    private func vinKey(for brand: VehicleBrand) -> String { brand == .volvo ? "volvo_vin" : "polestar_vin" }
    var vin: String { get { d.string(forKey: vinKey(for: activeBrand)) ?? "" } set { d.set(newValue, forKey: vinKey(for: activeBrand)); cachedHasResumableSession[activeBrand] = nil; syncAppThemeStorageKey() } }
    func vin(for brand: VehicleBrand) -> String { d.string(forKey: vinKey(for: brand)) ?? "" }
    func setVin(_ value: String, for brand: VehicleBrand) {
        d.set(value, forKey: vinKey(for: brand))
        cachedHasResumableSession[brand] = nil
        if brand == activeBrand { syncAppThemeStorageKey() }
    }

    /// Explicit sign-out suppression: after the user signs out, built-in developer
    /// credentials alone must not resurrect the session on the next launch. Set on
    /// sign-out, cleared on any explicit save or successful interactive sign-in.
    /// Without this, augmented/dataPortal modes report resumable from builtins even
    /// with no VIN and `discoverVehicles` re-discovers the server-side grant.
    private func explicitSignOutKey(for brand: VehicleBrand) -> String {
        brand == .volvo ? "volvo_explicit_signout" : "polestar_explicit_signout"
    }
    func hasExplicitSignOut(for brand: VehicleBrand) -> Bool {
        d.bool(forKey: explicitSignOutKey(for: brand))
    }
    func setExplicitSignOut(for brand: VehicleBrand) {
        d.set(true, forKey: explicitSignOutKey(for: brand))
        cachedHasResumableSession[brand] = nil
    }
    func clearExplicitSignOut(for brand: VehicleBrand) {
        d.removeObject(forKey: explicitSignOutKey(for: brand))
        cachedHasResumableSession[brand] = nil
    }

    func hasSessionToken(for brand: VehicleBrand) -> Bool {
        if hasExplicitSignOut(for: brand) { return false }
        if brand == .volvo { return keychain.hasStoredVolvoSession }
        if polestarConnectionMode == .dataPortal {
            return keychain.hasStoredPolestarDataPortalCredentials || !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
        }
        return keychain.hasStoredPolestarSession
    }

    func hasResumableSession(for brand: VehicleBrand) -> Bool {
        if let cached = cachedHasResumableSession[brand] { return cached }
        if hasExplicitSignOut(for: brand) {
            cachedHasResumableSession[brand] = false
            return false
        }
        let result: Bool
        switch brand {
        case .polestar:
            switch polestarConnectionMode {
            case .dataPortal:
                let hasID = !polestarDataPortalClientID.isEmpty || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
                let hasSecret = keychain.hasStoredPolestarDataPortalCredentials || !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
                result = hasID && hasSecret
            case .augmented:
                let hasPortalID = !polestarDataPortalClientID.isEmpty || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
                let hasPortalSecret = keychain.hasStoredPolestarDataPortalCredentials || !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
                let hasPortal = hasPortalID && hasPortalSecret
                let hasConsumer = keychain.hasStoredPolestarSession || keychain.hasStoredPolestarPassword
                result = hasPortal || hasConsumer
            case .polestarID:
                result = keychain.hasStoredPolestarSession || keychain.hasStoredPolestarPassword
            }
        case .volvo:
            result = !volvoClientID.isEmpty && keychain.hasStoredVolvoSession
        }
        cachedHasResumableSession[brand] = result
        return result
    }

    /// Whether the Polestar *command* client – remote locks, climate, windows, cabin cleaning,
    /// and locate – has a stored authorization. This is a separate OAuth grant from the account
    /// session (`hasResumableSession`), obtained via Settings → Remote Controls → "Authorize
    /// Remote Commands". Backed by the Keychain item `PolestarAPI` writes on success and clears
    /// (`clearCommandAuthorization()`) when the grant is rejected. Charging, timers and OTA
    /// commands do not need it.
    var hasPolestarCommandAuthorization: Bool {
        keychain.hasStoredCommandSession
    }

    /// Whether a consumer Polestar ID credential exists – a stored session token or the
    /// password Hisingen can sign in with. This is the half remote commands need: the command
    /// grant is verified against the consumer session and every invocation is dispatched with
    /// it, while augmented mode's Developer Portal credentials only carry telemetry. They
    /// satisfy `hasResumableSession(for: .polestar)`, so the command-authorization step gates on
    /// this too instead of offering a browser round-trip whose grant would be discarded.
    var hasPolestarIDCredentials: Bool {
        keychain.hasStoredPolestarSession || keychain.hasStoredPolestarPassword
    }
}
