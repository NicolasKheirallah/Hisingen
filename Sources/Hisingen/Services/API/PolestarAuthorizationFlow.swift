import Foundation
import OSLog

// MARK: - Authorization seam
//
// Hisingen obtains an OAuth code for Polestar's primary (web) client by driving PingFederate's
// HTML sign-in form — scraping provider markup that can change without notice. Everything that
// knows about that page lives behind `PolestarAuthorizationCodeSource`; `PolestarAPI` only sees
// "give me a code". If the form is ever redesigned or step-up/MFA appears, a browser-based
// implementation (the pattern already used for remote commands via
// `PolestarCommandSignInPresenter`) can replace the production conformer without touching
// token exchange, discovery, or session logic.

/// Endpoint/client parameters for one authorization attempt.
struct PolestarAuthorizationContext: Sendable {
    let clientID: String
    let redirectURI: URL
    let scope: String
    let authorizationEndpoint: URL
    /// Host the PingFederate resume path is resolved against.
    let identityHost: URL
}

/// Transport surface an authorization flow may use: the cookie-carrying ephemeral session
/// (PingFederate requires cookies) and the redirect interceptor that captures callback URLs
/// URLSession cannot load itself.
struct PolestarAuthorizationTransport: Sendable {
    let session: URLSession
    let redirectDelegate: OAuthRedirectDelegate

    func perform(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: 2_000_000, operation: operation, provider: .polestar
            )
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: operation)
            }
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                statusCode: http.statusCode, responseBytes: data.count,
                responseData: data, startedAt: startedAt
            )
            return (data, http)
        } catch let error as URLError {
            let wrapped = PolestarError.network(error)
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                startedAt: startedAt, error: wrapped
            )
            throw wrapped
        } catch {
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                startedAt: startedAt, error: error
            )
            throw error
        }
    }

    func postForm(to url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PolestarAPI.formBody(fields)
        return try await perform(request, operation: "authorization form submit")
    }
}

protocol PolestarAuthorizationCodeSource: Sendable {
    func obtainAuthorizationCode(
        email: String,
        password: String,
        context: PolestarAuthorizationContext,
        http: PolestarAuthorizationTransport
    ) async throws -> (code: String, verifier: String)
}

// MARK: - Shared OAuth URL helpers

enum PolestarOAuthSupport {
    /// The app-scheme callback (`polestar-explore://explore.polestar.com`) carries no path,
    /// which URL reports as "" here and "/" in some redirect forms — treat those as equal.
    static func normalizedPath(_ url: URL) -> String {
        url.path == "/" ? "" : url.path
    }

    static func queryValue(_ name: String, from url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    static func authorizationQueryItems(clientID: String, redirectURI: String,
                                        scope: String, state: String,
                                        challenge: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
    }

    /// Wraps `PKCE.randomURLSafeString()`, translating its `URLError` into the Polestar error
    /// domain.
    static func randomURLSafeString() throws -> String {
        do { return try PKCE.randomURLSafeString() }
        catch { throw PolestarError.invalidResponse(operation: "secure random generator") }
    }

    static func codeChallenge(for verifier: String) -> String {
        PKCE.codeChallenge(for: verifier)
    }

    /// Extracts PingFederate's resume path from the sign-in page. Multiple patterns because
    /// the page embeds the path differently across deployments; the bare `/as/…` catch-all is
    /// intentionally last and rejects `..` to avoid path traversal into the IDP host.
    static func extractResumePath(from html: String) -> String? {
        let patterns = [
            #"(?:url|action):\s*"([^"]+)""#,
            #"(?:resumePath|pf\.resumePath)\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"action="([^"]+)""#,
            #"action:\s*'([^']+)'"#,
            #"url:\s*'([^']+)'"#,
            #"/as/[a-zA-Z0-9\-_./]+"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range) else { continue }
            let group = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: group), in: html) else { continue }
            let value = String(html[matchRange])
            if (index == patterns.count - 1 || value.hasPrefix("/")), !value.contains("..") {
                return value
            }
        }
        return nil
    }
}

// MARK: - Production flow: scripted PingFederate form-fill

/// Drives PingFederate's HTML login with the user's credentials. Isolated here (rather than
/// living inside `PolestarAPI`) so provider-markup changes are contained to this one type and
/// an alternate conformer can be swapped in at the call site.
struct ScriptedPolestarAuthorization: PolestarAuthorizationCodeSource {
    func obtainAuthorizationCode(
        email: String,
        password: String,
        context: PolestarAuthorizationContext,
        http: PolestarAuthorizationTransport
    ) async throws -> (code: String, verifier: String) {
        let verifier = try PolestarOAuthSupport.randomURLSafeString()
        let state = try PolestarOAuthSupport.randomURLSafeString()
        let queryItems = PolestarOAuthSupport.authorizationQueryItems(
            clientID: context.clientID,
            redirectURI: context.redirectURI.absoluteString,
            scope: context.scope,
            state: state,
            challenge: PolestarOAuthSupport.codeChallenge(for: verifier)
        )
        guard var components = URLComponents(url: context.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw PolestarError.incompatibleAPI(operation: "authorization endpoint")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw PolestarError.incompatibleAPI(operation: "authorization request")
        }
        var request = URLRequest(url: url)
        request.setValue("Hisingen/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.perform(request, operation: "authorization page")
        Self.logPageStatus(response.statusCode)

        let authorizationCallback = http.redirectDelegate.takeCallback() ?? response.url
        if let code = try Self.validatedCode(from: authorizationCallback, expectedState: state,
                                             callbackURL: context.redirectURI) {
            return (code, verifier)
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let resumePath = PolestarOAuthSupport.extractResumePath(from: html) else {
            throw PolestarError.incompatibleAPI(operation: "Polestar sign-in form")
        }
        let code = try await performLogin(
            resumePath: resumePath,
            queryItems: queryItems,
            email: email,
            password: password,
            expectedState: state,
            callbackURL: context.redirectURI,
            identityHost: context.identityHost,
            http: http
        )
        return (code, verifier)
    }

    private func performLogin(resumePath: String, queryItems: [URLQueryItem],
                              email: String, password: String,
                              expectedState: String,
                              callbackURL: URL,
                              identityHost: URL,
                              http: PolestarAuthorizationTransport) async throws -> String {
        guard resumePath.hasPrefix("/"),
              var components = URLComponents(url: identityHost.appendingPathComponent(resumePath),
                                             resolvingAgainstBaseURL: false) else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let loginURL = components.url else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }

        // The credentials transit only through this form POST to the identity provider;
        // they are never logged, persisted, or included in error payloads.
        let (data, response) = try await http.postForm(
            to: loginURL,
            fields: ["pf.username": email, "pf.pass": password]
        )
        Self.logPageStatus(response.statusCode)
        let loginCallback = http.redirectDelegate.takeCallback() ?? response.url
        if let code = try Self.validatedCode(from: loginCallback, expectedState: expectedState,
                                             callbackURL: callbackURL) { return code }

        if let uid = PolestarOAuthSupport.queryValue("uid", from: response.url) {
            let (_, confirmation) = try await http.postForm(
                to: loginURL,
                fields: ["pf.submit": "true", "subject": uid]
            )
            let confirmationCallback = http.redirectDelegate.takeCallback() ?? confirmation.url
            if let code = try Self.validatedCode(from: confirmationCallback, expectedState: expectedState,
                                                 callbackURL: callbackURL) {
                return code
            }
        }

        let html = String(decoding: data, as: UTF8.self)
        if html.contains("ERR001") {
            throw PolestarError.authenticationRequired(.invalidCredentials)
        }
        throw PolestarError.authenticationRequired(.callbackRejected)
    }

    private static func validatedCode(from url: URL?, expectedState: String,
                                      callbackURL: URL) throws -> String? {
        guard let url else { return nil }
        guard url.scheme == callbackURL.scheme,
              url.host == callbackURL.host,
              PolestarOAuthSupport.normalizedPath(url) == PolestarOAuthSupport.normalizedPath(callbackURL) else { return nil }
        guard PolestarOAuthSupport.queryValue("state", from: url) == expectedState else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        return PolestarOAuthSupport.queryValue("code", from: url)
    }

    private static func logPageStatus(_ status: Int) {
        Task { @MainActor in
            Logger(subsystem: "io.kheirallah.hisingen", category: "api")
                .info("Polestar authorization page returned status \(status, privacy: .public)")
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
