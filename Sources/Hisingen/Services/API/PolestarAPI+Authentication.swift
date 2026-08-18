import AppKit
import Foundation

extension PolestarAPI {
    func validAccessToken() async throws -> String? {
        try await refreshTokenIfNeeded()
        return accessToken
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        clearAccountState()
        _ = redirectDelegate.takeCallback()
        try await discoverOIDCConfiguration()
        let authorization = try await obtainAuthorizationCode(email: email, password: password)
        try await exchangeCodeForToken(authorization.code, verifier: authorization.verifier)
        await acquireCommandToken(email: email, password: password)
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage) { await fetchCarImage() }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
    }

    private func acquireCommandToken(email: String, password: String) async {
        do {
            let authorization = try await obtainAuthorizationCode(
                email: email, password: password,
                clientID: commandClientID, redirectURI: commandRedirectURL, scope: oidcScope
            )
            let token = try await exchangeCode(authorization.code, verifier: authorization.verifier,
                                               clientID: commandClientID, redirectURI: commandRedirectURL)
            commandAccessToken = token.accessToken
            commandRefreshToken = token.refreshToken
            commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
            if let refresh = token.refreshToken { try? keychain.saveCommandSessionToken(refresh) }
            logger.info("Polestar command-client token acquired")
        } catch {
            logger.warning("Polestar command-client sign-in failed: \(error, privacy: .public); remote commands unavailable")
        }
    }

    @MainActor
    private static func promptForCredentials(prefilledEmail: String, preferences: PreferencesStore) -> (email: String, password: String)? {
        NSRunningApplication.current.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("Polestar ID Password Required")
        alert.informativeText = L10n.text(
            "Enter your Polestar ID password to authorize remote vehicle controls. Hisingen will securely save your mobile command session in macOS Keychain."
        )
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: prefilledEmail.isEmpty ? 56 : 26))
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading

        let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        emailField.placeholderString = L10n.text("Polestar ID (Email)")
        emailField.stringValue = prefilledEmail
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        passwordField.placeholderString = L10n.text("Password")
        if prefilledEmail.isEmpty { stack.addArrangedSubview(emailField) }
        stack.addArrangedSubview(passwordField)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("Authorize"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = prefilledEmail.isEmpty ? emailField : passwordField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let email = (prefilledEmail.isEmpty ? emailField.stringValue : prefilledEmail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !pass.isEmpty else { return nil }
        if preferences.email.isEmpty { preferences.email = email }
        return (email, pass)
    }

    func validCommandToken() async -> String? {
        if let expiry = commandTokenExpiry, expiry.timeIntervalSinceNow > 300,
           let token = commandAccessToken { return token }
        let stored = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        if let refresh = stored, let tokenEndpoint {
            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                "grant_type": "refresh_token", "client_id": commandClientID, "refresh_token": refresh
            ])
            if let token = try? await Self.requestToken(request: request, session: session,
                                                        invalidReason: .expiredSession) {
                commandAccessToken = token.accessToken
                commandRefreshToken = token.refreshToken ?? refresh
                commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
                if let refreshed = token.refreshToken { try? keychain.saveCommandSessionToken(refreshed) }
                return token.accessToken
            }
        }
        let savedEmail = (await MainActor.run { preferences.email }).trimmingCharacters(in: .whitespacesAndNewlines)
        var emailToUse = savedEmail
        var passwordToUse = (try? keychain.readPassword()) ?? nil
        if passwordToUse == nil || passwordToUse?.isEmpty == true {
            if let creds = await MainActor.run(body: { Self.promptForCredentials(prefilledEmail: savedEmail, preferences: preferences) }) {
                emailToUse = creds.email
                passwordToUse = creds.password
            }
        }
        if !emailToUse.isEmpty, let password = passwordToUse, !password.isEmpty {
            await acquireCommandToken(email: emailToUse, password: password)
            return commandAccessToken
        }
        return nil
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else { throw PolestarError.authenticationRequired(.noStoredSession) }
        clearAccountState(keepRefreshToken: true)
        if let commandRefresh = (try? keychain.readCommandSessionToken()) ?? nil, !commandRefresh.isEmpty {
            commandRefreshToken = commandRefresh
        }
        try await discoverOIDCConfiguration()
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as PolestarError where error.requiresAuthentication {
            try? keychain.deleteSessionToken()
            refreshToken = nil
            throw error
        }
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage) { await fetchCarImage() }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        logger.info("Stored Polestar session restored")
    }

    func resetSession() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        commandAccessToken = nil
        commandRefreshToken = nil
        commandTokenExpiry = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelImageDownloads()
        clearAccountState()
        session.invalidateAndCancel()
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
        await grpc.invalidateDiscoveredHost()
    }

    func signOut() async throws {
        let commandToRevoke = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        if let commandToRevoke, let endpoint = revocationEndpoint {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                "client_id": commandClientID, "token": commandToRevoke, "token_type_hint": "refresh_token"
            ])
            _ = try? await perform(request, limit: 64_000, operation: "command session revocation")
        }
        try? keychain.deleteCommandSessionToken()
        if let tokenToRevoke = refreshToken, let endpoint = revocationEndpoint {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody([
                    "client_id": oidcClientID, "token": tokenToRevoke, "token_type_hint": "refresh_token"
                ])
                let (_, response) = try await perform(request, limit: 64_000, operation: "session revocation")
                try validateHTTP(response, operation: "session revocation")
            } catch {
                logger.warning("Polestar session revocation failed; clearing local credentials")
            }
        }
        await resetSession()
        do {
            try keychain.deleteSessionToken()
        } catch {
            try? keychain.deletePassword()
            throw error
        }
        try keychain.deletePassword()
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, cars.contains(where: { $0.vin == preferred }) { return preferred }
        return cars.first?.vin
    }

    func selectCar(vin: String, features: FeatureSelection) async throws {
        guard cars.contains(where: { $0.vin == vin }) else { throw PolestarError.notConfigured }
        try await applyCarInfo(vin: vin)
        if features.contains(.vehicleImage) { await fetchCarImage() }
        if features.contains(.ownerGreeting), ownerFirstName == nil { await fetchOwnerInfo() }
    }
}
