import Foundation
import OSLog
import SwiftUI

/// A vehicle the reader signed out of a multi-vehicle account. The account session is still
/// live, so this records what to hide and how to label it in Settings → Garage.
struct DetachedVehicle: Codable, Equatable, Sendable {
    let vin: String
    let brand: VehicleBrand
    /// The label as it read when the vehicle was signed out. Empty when privacy redaction was
    /// on at that moment; the row then falls back to the brand name.
    let title: String
}

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
    /// Local sample data for screenshots and a network-free look at the UI. It never changes
    /// accounts and never writes provider credentials; the session controller serves the seeded
    /// snapshot while this is on.
    var isDemoMode: Bool {
        get { d.bool(forKey: "demo_mode_v1") }
        set { d.set(newValue, forKey: "demo_mode_v1") }
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
    /// The Volvo ID system that issued the stored session. Absent means the original one: every
    /// session saved before the new system was supported came from it.
    var volvoSessionIdentity: VolvoIdentityProvider {
        get { d.string(forKey: "volvo_session_identity").flatMap(VolvoIdentityProvider.init(rawValue:)) ?? .legacy }
        set { d.set(newValue.rawValue, forKey: "volvo_session_identity") }
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

    // MARK: - Vehicles signed out of a connected account

    private var detachedVehiclesByVIN: [String: DetachedVehicle] {
        guard let data = d.data(forKey: Self.detachedVehiclesKey),
              let decoded = try? JSONDecoder().decode([String: DetachedVehicle].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func storeDetachedVehicles(_ values: [String: DetachedVehicle]) {
        if values.isEmpty {
            d.removeObject(forKey: Self.detachedVehiclesKey)
        } else if let data = try? JSONEncoder().encode(values) {
            d.set(data, forKey: Self.detachedVehiclesKey)
        } else {
            d.removeObject(forKey: Self.detachedVehiclesKey)
        }
    }

    func detachedVehicles(for brand: VehicleBrand) -> [DetachedVehicle] {
        detachedVehiclesByVIN.values
            .filter { $0.brand == brand }
            .sorted { $0.vin.normalizedVIN < $1.vin.normalizedVIN }
    }

    func detachedVehicle(for vin: String) -> DetachedVehicle? {
        detachedVehiclesByVIN[vin.normalizedVIN]
    }

    func isVehicleDetached(_ vin: String) -> Bool {
        let key = vin.normalizedVIN
        return !key.isEmpty && detachedVehiclesByVIN[key] != nil
    }

    func detachedVehicleVINs(for brand: VehicleBrand) -> Set<String> {
        Set(detachedVehicles(for: brand).map { $0.vin.normalizedVIN })
    }

    func detachVehicle(vin: String, brand: VehicleBrand, title: String) {
        let key = vin.normalizedVIN
        guard !key.isEmpty else { return }
        var values = detachedVehiclesByVIN
        values[key] = DetachedVehicle(vin: key, brand: brand, title: title)
        storeDetachedVehicles(values)
    }

    func reconnectVehicle(vin: String) {
        let key = vin.normalizedVIN
        guard !key.isEmpty else { return }
        var values = detachedVehiclesByVIN
        values.removeValue(forKey: key)
        storeDetachedVehicles(values)
    }

    /// Clears the whole brand: a full account sign-out, a fresh credential save, or a successful
    /// interactive sign-in all mean the account's vehicles are registered again.
    func clearDetachedVehicles(for brand: VehicleBrand) {
        let values = detachedVehiclesByVIN.filter { $0.value.brand != brand }
        storeDetachedVehicles(values)
    }

    // MARK: - Known vehicles per account

    private func knownVINsKey(for brand: VehicleBrand) -> String {
        brand == .volvo ? "volvo_known_vins_v1" : "polestar_known_vins_v1"
    }

    /// The VINs this Mac has discovered for the account, persisted across launches. The selected
    /// VIN alone is not enough: a second car is discovered only after a session restore or a
    /// garage scan, and a sign-out before either would otherwise look like a single-car account.
    func knownVINs(for brand: VehicleBrand) -> [String] {
        var stored = d.stringArray(forKey: knownVINsKey(for: brand)) ?? []
        let selected = vin(for: brand)
        if !selected.isEmpty { stored.append(selected) }
        let detached = detachedVehicleVINs(for: brand)
        var seen = Set<String>()
        return stored
            .map { $0.normalizedVIN }
            .filter { !$0.isEmpty && !detached.contains($0) && seen.insert($0).inserted }
    }

    /// Adds to the account's known set. Union, not replacement: a dormant scan can add a car
    /// while the foreground discovery is still reporting an older list.
    func rememberKnownVINs(_ vins: [String], for brand: VehicleBrand) {
        let detached = detachedVehicleVINs(for: brand)
        var seen = Set<String>()
        var values = (d.stringArray(forKey: knownVINsKey(for: brand)) ?? [])
            .map { $0.normalizedVIN }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        for vin in vins.map({ $0.normalizedVIN }) where !vin.isEmpty && !detached.contains(vin) {
            if seen.insert(vin).inserted { values.append(vin) }
        }
        d.set(values, forKey: knownVINsKey(for: brand))
    }

    func clearKnownVINs(for brand: VehicleBrand) {
        d.removeObject(forKey: knownVINsKey(for: brand))
    }
}
