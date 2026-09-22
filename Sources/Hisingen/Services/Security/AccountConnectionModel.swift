import Combine
import Foundation
import SwiftUI

/// A live connectivity check's outcome, named so the sign-in surfaces can branch on the
/// typed failure kind instead of the message text.
struct ConnectionCheck: Equatable, Sendable {
    var success: Bool
    var message: String
    var failureKind: SignInFailureKind?
}

/// The decisions behind the account card: whether a brand is connected, whether its
/// session can be renewed with the credentials on file, and what saving a draft writes
/// and in which order. The form renders; this decides. It also owns the editing draft,
/// so plaintext credentials live with the sheet that is editing them instead of on a
/// process-wide store.
@MainActor
final class AccountConnectionModel: ObservableObject {
    private let preferences: PreferencesStore
    private let keychain: KeychainStore

    init(preferences: PreferencesStore, keychain: KeychainStore = .app) {
        self.preferences = preferences
        self.keychain = keychain
    }

    // MARK: - Connection facts

    enum ConnectionHealth: Equatable {
        case active, connectedInactive, sessionExpired, notConnected
    }

    func isConnected(_ brand: VehicleBrand) -> Bool {
        if brand == .polestar {
            switch preferences.polestarConnectionMode {
            case .dataPortal, .augmented:
                return preferences.hasResumableSession(for: .polestar)
            case .polestarID:
                return preferences.hasSessionToken(for: .polestar)
            }
        }
        return preferences.hasResumableSession(for: brand)
    }

    /// Whether the brand has enough on file (developer keys / account email, plus a
    /// previously-discovered VIN) to renew its session with a browser handshake alone —
    /// an *expired* session, not a brand that was never set up. Presence bits only:
    /// rendering reads the answer, so no secret value may be touched to compute it.
    func isRenewable(_ brand: VehicleBrand) -> Bool {
        guard !preferences.vin(for: brand).isEmpty else { return false }
        switch brand {
        case .polestar:
            switch preferences.polestarConnectionMode {
            case .dataPortal:
                return hasStoredPortalFacts
            case .augmented:
                return hasStoredPortalFacts || keychain.hasStoredPolestarEmail
            case .polestarID:
                return keychain.hasStoredPolestarEmail
            }
        case .volvo:
            let hasClientID = !preferences.volvoClientID.isEmpty || BuiltinVolvoSecrets.isConfigured
            let hasSecrets = BuiltinVolvoSecrets.isConfigured
                || keychain.hasStoredVolvoAppCredentials
            return hasClientID && hasSecrets
        }
    }

    private var hasStoredPortalFacts: Bool {
        let hasID = !preferences.polestarDataPortalClientID.isEmpty || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
        let hasSecret = keychain.hasStoredPolestarDataPortalCredentials || !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
        return hasID && hasSecret
    }

    func health(for brand: VehicleBrand, isActiveBrand: Bool, lastCheck: ConnectionCheck?) -> ConnectionHealth {
        // A live-check failure in an auth family is the strongest signal. The failure
        // kinds exist precisely so this decision reads the classifier rather than
        // pattern-matching localized message text.
        if isConnected(brand), let kind = lastCheck?.failureKind, isAuthFailure(kind) {
            return .sessionExpired
        }
        if isConnected(brand) {
            return isActiveBrand ? .active : .connectedInactive
        }
        // No resumable session, but the credentials to renew one are still on file.
        return isRenewable(brand) ? .sessionExpired : .notConnected
    }

    private func isAuthFailure(_ kind: SignInFailureKind) -> Bool {
        switch kind {
        case .invalidCredentials, .interactiveChallenge, .sessionExpired, .signingFlowChanged:
            return true
        case .transient, .unspecified:
            return false
        }
    }

    // MARK: - Draft

    struct Draft: Equatable {
        var polestarEmail = ""
        var polestarPassword = ""
        var polestarVIN = ""
        var polestarNickname = ""
        var polestarDataPortalAccountID = ""
        var polestarDataPortalClientID = ""
        var polestarDataPortalClientSecret = ""
        var volvoClientID = ""
        var volvoClientSecret = ""
        var volvoApiKey = ""
        var volvoVIN = ""
        var volvoNickname = ""
    }

    @Published var draft = Draft()

    /// Re-derives the fields the reader has not touched from what is already on file.
    /// Runs when the form appears; typed values survive it, and write-only secrets are
    /// never seeded from the Keychain.
    func seedDraftFromStore() {
        if draft.polestarEmail.isEmpty { draft.polestarEmail = preferences.email }
        if draft.polestarVIN.isEmpty { draft.polestarVIN = preferences.vin(for: .polestar) }
        if draft.polestarNickname.isEmpty { draft.polestarNickname = preferences.vehicleNickname(for: draft.polestarVIN) }
        if draft.polestarDataPortalAccountID.isEmpty { draft.polestarDataPortalAccountID = preferences.polestarDataPortalAccountID }
        if draft.polestarDataPortalClientID.isEmpty { draft.polestarDataPortalClientID = preferences.polestarDataPortalClientID }
        if draft.volvoClientID.isEmpty { draft.volvoClientID = preferences.volvoClientID }
        if draft.volvoVIN.isEmpty { draft.volvoVIN = preferences.vin(for: .volvo) }
        if draft.volvoNickname.isEmpty { draft.volvoNickname = preferences.vehicleNickname(for: draft.volvoVIN) }
    }

    func binding(_ keyPath: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.draft[keyPath: keyPath] ?? "" },
            set: { [weak self] in self?.draft[keyPath: keyPath] = $0 }
        )
    }

    /// Portal facts including what the reader has typed but not saved yet.
    var isDataPortalConfigured: Bool {
        let hasID = !draft.polestarDataPortalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
        let hasSecret = keychain.hasStoredPolestarDataPortalCredentials
            || !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
            || !draft.polestarDataPortalClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasID && hasSecret
    }

    /// Enough to attempt a portal-only connect: an ID from the reader or the built-ins,
    /// and a VIN that would not corrupt the vehicle map.
    var canConnectDataPortal: Bool {
        let hasID = !draft.polestarDataPortalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
        return hasID && SettingsValidation.isValidOptionalVIN(draft.polestarVIN)
    }

    var hasResumableVolvoSession: Bool {
        let trimmedClientID = draft.volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty, trimmedClientID == preferences.volvoClientID,
              draft.volvoClientSecret.isEmpty, draft.volvoApiKey.isEmpty else { return false }
        return preferences.hasResumableSession(for: .volvo)
    }

    // MARK: - Saving

    enum SaveEffect: Equatable {
        case credentialsChanged
        case presentationOnly
    }

    struct PolestarSaveOutcome: Equatable {
        /// Whether the primary save landed; drives the button's saved confirmation.
        var saved: Bool
        /// The Keychain denial to show, if any save in the sequence was denied. A denial
        /// survives a later save succeeding: a password that never reached the Keychain
        /// must not be hidden behind a portal save that did.
        var keychainError: String?
        /// What the shell should be told, or nil when the attempt died before changing
        /// anything a consumer could want to reload.
        var effect: SaveEffect?
    }

    /// Persists the draft per the selected connection mode. Returns nil when there was
    /// nothing to do: an unvalidated Polestar form or an empty portal client ID
    /// short-circuits without touching feedback or the shell.
    @discardableResult
    func savePolestar(mode: PolestarConnectionMode) -> PolestarSaveOutcome? {
        switch mode {
        case .augmented:
            preferences.polestarConnectionMode = .augmented
            let outcome = combining(savePolestarIDCredentials(savingAs: .augmented),
                                    saveDataPortalCredentials(savingAs: .augmented))
            preferences.polestarConnectionMode = .augmented
            return outcome
        case .dataPortal:
            return saveDataPortalCredentials(savingAs: .dataPortal)
        case .polestarID:
            return savePolestarIDCredentials(savingAs: .polestarID)
        }
    }

    private func combining(_ first: PolestarSaveOutcome?, _ second: PolestarSaveOutcome?) -> PolestarSaveOutcome? {
        switch (first, second) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return only
        case (let a?, let b?):
            return PolestarSaveOutcome(
                saved: b.saved,
                keychainError: a.keychainError ?? b.keychainError,
                effect: b.effect ?? a.effect)
        }
    }

    private func savePolestarIDCredentials(savingAs mode: PolestarConnectionMode) -> PolestarSaveOutcome? {
        guard SettingsValidation.isValidEmail(draft.polestarEmail),
              SettingsValidation.isValidOptionalVIN(draft.polestarVIN) else { return nil }
        let normalizedEmail = draft.polestarEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperVIN = draft.polestarVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let oldVIN = preferences.vin(for: .polestar)
        let nicknameVIN = upperVIN.isEmpty ? oldVIN : upperVIN
        let credentialsChanged = normalizedEmail != preferences.email || upperVIN != oldVIN || !draft.polestarPassword.isEmpty
        var keychainError: String?
        if !draft.polestarPassword.isEmpty {
            do {
                try keychain.savePassword(draft.polestarPassword)
                // The plaintext must not linger anywhere once the Keychain has it.
                draft.polestarPassword = ""
            } catch {
                keychainError = L10n.text("Couldn't save the password to the Keychain. Please try again.")
            }
        }
        guard keychainError == nil else {
            return PolestarSaveOutcome(saved: false, keychainError: keychainError, effect: nil)
        }
        // Persist identity only after a new password has reached the Keychain successfully.
        // A Keychain denial must not leave an email/VIN pointing at credentials that were
        // not actually saved.
        preferences.polestarConnectionMode = mode
        preferences.email = normalizedEmail
        preferences.setVin(upperVIN, for: .polestar)
        if !nicknameVIN.isEmpty {
            preferences.setVehicleNickname(draft.polestarNickname, for: nicknameVIN)
        }
        return PolestarSaveOutcome(saved: true, keychainError: nil,
                                   effect: credentialsChanged ? .credentialsChanged : .presentationOnly)
    }

    private func saveDataPortalCredentials(savingAs mode: PolestarConnectionMode) -> PolestarSaveOutcome? {
        let trimmedID = draft.polestarDataPortalClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = draft.polestarDataPortalClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountID = draft.polestarDataPortalAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }

        var keychainError: String?
        if !trimmedSecret.isEmpty {
            do {
                try keychain.savePolestarDataPortalCredentials(
                    accountID: trimmedAccountID.isEmpty ? nil : trimmedAccountID,
                    clientID: trimmedID,
                    clientSecret: trimmedSecret
                )
                draft.polestarDataPortalClientSecret = ""
            } catch {
                keychainError = L10n.text("Couldn't save credentials to the Keychain. Please try again.")
            }
        }
        guard keychainError == nil else {
            return PolestarSaveOutcome(saved: false, keychainError: keychainError, effect: nil)
        }
        if mode == .dataPortal || mode == .augmented {
            preferences.polestarConnectionMode = mode
        }
        preferences.polestarDataPortalAccountID = trimmedAccountID
        preferences.polestarDataPortalClientID = trimmedID
        let upperVIN = draft.polestarVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        preferences.setVin(upperVIN, for: .polestar)
        let nickVIN = !upperVIN.isEmpty ? upperVIN : preferences.vin(for: .polestar)
        if !nickVIN.isEmpty {
            preferences.setVehicleNickname(draft.polestarNickname, for: nickVIN)
        }
        return PolestarSaveOutcome(saved: true, keychainError: nil, effect: .credentialsChanged)
    }

    // MARK: - Volvo sign-in handoff

    struct VolvoSignInRequest: Equatable {
        var clientID: String
        var clientSecret: String
        var vccApiKey: String
        var nickname: String
    }

    /// Resolves what the browser sign-in needs (entered values, else the built-in
    /// developer keys), records the identity fields, and drops the plaintext secrets
    /// from the draft so they do not outlive the handoff. nil when the VIN does not
    /// pass validation.
    func beginVolvoSignIn() -> VolvoSignInRequest? {
        guard SettingsValidation.isValidOptionalVIN(draft.volvoVIN) else { return nil }
        let upperVIN = draft.volvoVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedClientID = draft.volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldVIN = preferences.vin(for: .volvo)
        preferences.volvoClientID = trimmedClientID
        preferences.setVin(upperVIN, for: .volvo)
        if !upperVIN.isEmpty {
            preferences.setVehicleNickname(draft.volvoNickname, for: upperVIN)
        } else if !oldVIN.isEmpty {
            preferences.setVehicleNickname(draft.volvoNickname, for: oldVIN)
        }
        let request = VolvoSignInRequest(
            clientID: !trimmedClientID.isEmpty ? trimmedClientID : BuiltinVolvoSecrets.clientID,
            clientSecret: !draft.volvoClientSecret.isEmpty ? draft.volvoClientSecret : BuiltinVolvoSecrets.clientSecret,
            vccApiKey: !draft.volvoApiKey.isEmpty ? draft.volvoApiKey : BuiltinVolvoSecrets.vccApiKey,
            nickname: draft.volvoNickname)
        draft.volvoClientSecret = ""
        draft.volvoApiKey = ""
        return request
    }
}
