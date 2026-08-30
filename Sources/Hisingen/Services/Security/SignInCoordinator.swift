import AppKit
import Foundation
import OSLog

/// What the sign-in flows need back from the app shell. Everything brand- and
/// session-state related (adopting the newly authorized brand, resuming its session,
/// closing Settings) stays in `AppDelegate`; the coordinator only drives the OAuth
/// handshakes and reports their outcomes.
@MainActor
protocol SignInCoordinatorContext: AnyObject {
    /// Adopt `brand` as the active brand (past the normal idempotence guards) and resume its
    /// stored session — the pair every successful interactive sign-in ends with.
    func activateBrandAfterSignIn(_ brand: VehicleBrand)
    /// Close the Settings surface after a flow succeeds.
    func dismissSettingsAfterSignIn()
    /// Re-render the Settings surface in place (without closing it) so a card reflects state
    /// that changed out from under it — e.g. the Polestar command-authorization status after
    /// the browser round-trip completes.
    func refreshSettingsSurface()
    /// A persistent, notification-backed confirmation. Used where a transient banner that
    /// self-cleans after 5 s would read as "did that actually go through?".
    func presentSignInNotice(title: String, body: String, subtitle: String?)
}

/// Owns Hisingen's three interactive OAuth handshakes and the routing of their callback URLs:
///
/// - **Volvo sign-in** — full OAuth through the system browser, plus the builtin-secret /
///   Keychain fallback chain and the "already configured, just re-adopt the brand" fast path.
/// - **Polestar command authorization** — a separate, explicit browser step that unlocks
///   remote commands; stays unavailable until the user completes it (and again once the
///   resulting session expires).
/// - **Polestar interactive web sign-in** — an in-app `WKWebView` fallback for when headless
///   PingFederate login is met with an interactive challenge (2FA, CAPTCHA, ToS update).
///
/// Extracted from `AppDelegate`, where the three flows were ~40 near-duplicate lines each and
/// the callback-routing rules were smeared across the URL handler.
@MainActor
final class SignInCoordinator {
    private let logger = AppLog.logger("sign-in")
    private let preferences: PreferencesStore
    private let polestarAPI: PolestarAPI
    private let volvoAPI: VolvoAPI
    private let volvoPresenter = VolvoSignInPresenter()
    private let polestarCommandPresenter = PolestarCommandSignInPresenter()
    private let polestarWebPresenter = PolestarWebSignInPresenter()
    private let resultPresenter: RemoteResultPresenter
    private weak var context: (any SignInCoordinatorContext)?

    init(context: any SignInCoordinatorContext,
         preferences: PreferencesStore,
         polestarAPI: PolestarAPI,
         volvoAPI: VolvoAPI,
         resultPresenter: RemoteResultPresenter = RemoteResultPresenter()) {
        self.context = context
        self.preferences = preferences
        self.polestarAPI = polestarAPI
        self.volvoAPI = volvoAPI
        self.resultPresenter = resultPresenter
    }

    // MARK: - Callback routing

    /// Routes an inbound OAuth callback URL to the flow awaiting it. Volvo's redirect comes
    /// back on the `hisingen://` scheme, the Polestar command client's on `polestar-explore://`;
    /// the interactive Polestar web flow intercepts its own redirect inside its `WKWebView`
    /// and never reaches here.
    func handleCallbackURL(_ url: URL) {
        if url.scheme?.lowercased() == "polestar-explore" {
            polestarCommandPresenter.handleCallbackURL(url)
        } else {
            volvoPresenter.handleCallbackURL(url)
        }
    }

    // MARK: - Volvo

    /// `forceInteractive` bypasses the "already configured, nothing to do" fast path — used by
    /// the explicit "Re-sign in" affordance, where the user wants a fresh browser handshake
    /// even if a (possibly stale) session token is still on file.
    func beginVolvoSignIn(clientID: String, clientSecret: String, vccApiKey: String,
                          nickname: String, forceInteractive: Bool = false) {
        var trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClientID.isEmpty && BuiltinVolvoSecrets.isConfigured {
            trimmedClientID = BuiltinVolvoSecrets.clientID
        }
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            presentVolvoUnavailable()
            return
        }

        var effectiveSecret = !clientSecret.isEmpty ? clientSecret : ((try? Keychain.readVolvoClientSecret()) ?? "")
        if effectiveSecret.isEmpty && BuiltinVolvoSecrets.isConfigured {
            effectiveSecret = BuiltinVolvoSecrets.clientSecret
        }

        var effectiveApiKey = !vccApiKey.isEmpty ? vccApiKey : ((try? Keychain.readVolvoApiKey()) ?? "")
        if effectiveApiKey.isEmpty && BuiltinVolvoSecrets.isConfigured {
            effectiveApiKey = BuiltinVolvoSecrets.vccApiKey
        }

        let sessionToken = (try? Keychain.readVolvoSessionToken()) ?? nil

        // Already fully configured and the form came back blank: there is nothing to
        // re-authorize — just re-adopt the Volvo brand and resume from the stored token.
        if !forceInteractive,
           !effectiveSecret.isEmpty, !effectiveApiKey.isEmpty, let sessionToken, !sessionToken.isEmpty,
           trimmedClientID == preferences.volvoClientID, clientSecret.isEmpty, vccApiKey.isEmpty {
            // Fire-and-forget: this branch is synchronous, and the VIN is already resolvable
            // from the warm provider.
            Task { [weak self] in await self?.assignVolvoNickname(trimmedNickname) }
            context?.activateBrandAfterSignIn(.volvo)
            context?.dismissSettingsAfterSignIn()
            return
        }

        guard !effectiveSecret.isEmpty, !effectiveApiKey.isEmpty else {
            presentVolvoUnavailable()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await volvoAPI.configure(clientID: trimmedClientID, clientSecret: effectiveSecret, vccApiKey: effectiveApiKey)
            do {
                try await self.runVolvoInteractiveSignIn(
                    clientID: trimmedClientID, clientSecret: effectiveSecret,
                    vccApiKey: effectiveApiKey, nickname: trimmedNickname, readOnlyScopes: false
                )
            } catch let error as VolvoError where Self.isInvalidScope(error) {
                // The developer application is not approved for the gated scopes (lock /
                // unlock / engine-start / honk-flash / vehicle location). Volvo rejects the
                // whole request, not just the extra scopes — so stop asking for them and
                // retry with data-access scopes only.
                logger.warning("Volvo rejected the scope request; retrying without restricted scopes")
                preferences.volvoRestrictedScopesEnabled = false
                do {
                    try await self.runVolvoInteractiveSignIn(
                        clientID: trimmedClientID, clientSecret: effectiveSecret,
                        vccApiKey: effectiveApiKey, nickname: trimmedNickname, readOnlyScopes: true
                    )
                    context?.presentSignInNotice(
                        title: L10n.text("Volvo connected — data access only"),
                        body: L10n.text("Your Volvo developer application isn't approved for lock, unlock, engine start, locate, or vehicle location, so it was reconnected with vehicle data only. Request those permissions for your application on developer.volvocars.com to enable remote controls."),
                        subtitle: L10n.text("Volvo")
                    )
                } catch {
                    presentVolvoSignInFailure(error)
                }
            } catch {
                presentVolvoSignInFailure(error)
            }
        }
    }

    /// One full browser OAuth round trip: authorize → callback → token exchange → discovery,
    /// then persist the credentials and adopt the brand. `readOnlyScopes` forces the request
    /// to omit the approval-gated `restrictedScopes`.
    private func runVolvoInteractiveSignIn(clientID: String, clientSecret: String, vccApiKey: String,
                                           nickname: String, readOnlyScopes: Bool) async throws {
        let authorizeURL = try await volvoAPI.beginSignIn(forceReadOnlyScopes: readOnlyScopes)
        let callbackURL = try await volvoPresenter.signIn(
            authorizeURL: authorizeURL, callbackScheme: "hisingen"
        )
        try await volvoAPI.completeSignIn(callbackURL: callbackURL, preferredVIN: nil, features: preferences.features)
        preferences.volvoClientID = clientID
        try Keychain.saveVolvoClientSecret(clientSecret)
        try Keychain.saveVolvoApiKey(vccApiKey)
        // Awaited inline, before the brand switch, so the first `CarSummary` the switch builds
        // already carries the user's nickname.
        await assignVolvoNickname(nickname)
        context?.activateBrandAfterSignIn(.volvo)
        context?.dismissSettingsAfterSignIn()
        resultPresenter.present(
            title: L10n.text("Volvo sign-in successful"),
            message: L10n.text("Successfully connected to your Volvo account! Fetching telemetry…"),
            success: true
        )
    }

    private static func isInvalidScope(_ error: VolvoError) -> Bool {
        if case .permissionDenied(let operation) = error { return operation == "invalid_scope" }
        return false
    }

    private func presentVolvoSignInFailure(_ error: Error) {
        let mapped = error as? LocalizedError
        logger.error("Volvo sign-in failed: \(String(describing: error), privacy: .public)")
        resultPresenter.present(
            title: L10n.text("Volvo sign-in failed"),
            message: mapped?.errorDescription ?? error.localizedDescription, success: false
        )
    }

    /// Resolves the freshly signed-in Volvo VIN and stores the user's nickname for it. No-op
    /// when the sign-in form left the nickname blank.
    private func assignVolvoNickname(_ nickname: String) async {
        guard !nickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) else { return }
        preferences.setVehicleNickname(nickname, for: vin)
    }

    private func presentVolvoUnavailable() {
        resultPresenter.present(
            title: L10n.text("Volvo sign-in unavailable"),
            message: VolvoError.appNotConfigured.localizedDescription, success: false
        )
    }

    // MARK: - Polestar command authorization

    /// Authorizes the Polestar command client (remote commands) through a real browser window
    /// instead of Hisingen scripting the login form itself — see `PolestarAPI.beginCommandAuthorization()`/
    /// `completeCommandAuthorization(callbackURL:)` and `PolestarCommandSignInPresenter`. This
    /// is a separate, explicit step from the base Polestar sign-in; remote commands stay
    /// unavailable until the user completes it (and again whenever the resulting session
    /// eventually expires).
    func beginPolestarCommandAuthorization() {
        guard preferences.activeBrand == .polestar, preferences.hasResumableSession(for: .polestar) else {
            resultPresenter.present(
                title: L10n.text("Sign in to Polestar first"),
                message: L10n.text("Connect your Polestar account before authorizing remote commands."),
                success: false
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let authorizeURL = try await polestarAPI.beginCommandAuthorization()
                let callbackURL = try await polestarCommandPresenter.signIn(authorizeURL: authorizeURL)
                try await polestarAPI.completeCommandAuthorization(callbackURL: callbackURL)
                // Persistent banner through the Notifier pipeline — the transient
                // `RemoteResultPresenter` variant self-cleans after 5 s, which reads as
                // "did it actually go through?" for a step this easy to miss.
                context?.presentSignInNotice(
                    title: L10n.text("Remote commands authorized"),
                    body: L10n.text("Polestar remote commands are now available."),
                    subtitle: L10n.text("Polestar")
                )
                // The Remote Controls card reads the authorization state synchronously; nudge
                // it so "Authorize…" becomes "Re-authorize…" without the user reopening Settings.
                context?.refreshSettingsSurface()
            } catch {
                let mapped = error as? LocalizedError
                logger.error("Polestar command authorization failed: \(String(describing: error), privacy: .public)")
                resultPresenter.present(
                    title: L10n.text("Authorization failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription, success: false
                )
                context?.refreshSettingsSurface()
            }
        }
    }

    // MARK: - Polestar interactive web sign-in

    /// Authorizes the Polestar web client (vehicle discovery & telemetry) through an in-app
    /// `WKWebView` window when headless PingFederate login is rejected with an interactive
    /// challenge (such as 2FA, CAPTCHA, or a Terms of Service update).
    func beginPolestarWebSignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (authorizeURL, redirectURI) = try await polestarAPI.beginWebAuthorization()
                let callbackURL = try await polestarWebPresenter.signIn(
                    authorizeURL: authorizeURL,
                    redirectURI: redirectURI
                )
                let vin = preferences.vin(for: .polestar)
                try await polestarAPI.completeWebAuthorization(
                    callbackURL: callbackURL,
                    preferredVIN: vin.isEmpty ? nil : vin,
                    features: preferences.features
                )
                context?.activateBrandAfterSignIn(.polestar)
                context?.dismissSettingsAfterSignIn()
                resultPresenter.present(
                    title: L10n.text("Polestar sign-in successful"),
                    message: L10n.text("Successfully connected to your Polestar account! Fetching telemetry…"),
                    success: true
                )
            } catch {
                let mapped = error as? LocalizedError
                logger.error("Polestar interactive web sign-in failed: \(String(describing: error), privacy: .public)")
                resultPresenter.present(
                    title: L10n.text("Sign-in failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription,
                    success: false
                )
            }
        }
    }
}
