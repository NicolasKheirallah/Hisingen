import Foundation
import Testing
@testable import Hisingen

/// Volvo is moving developer applications from the original Volvo ID server to a new one. The
/// client ID prefix picks the system, and a session saved by one is dead on the other.
@Suite("Volvo ID sign-in systems", .serialized)
struct VolvoIdentityProviderTests {
    private let newClient = "vid-dc-test-client"

    @Test("The client ID prefix picks the sign-in system")
    func prefixPicksTheSystem() {
        #expect(VolvoIdentityProvider(clientID: "vid-dc-abc") == .volvoID)
        #expect(VolvoIdentityProvider(clientID: "vid-dcr-abc") == .volvoID)
        #expect(VolvoIdentityProvider(clientID: "  vid-dc-abc\n") == .volvoID)
        #expect(VolvoIdentityProvider(clientID: "dc-abc") == .legacy)
        #expect(VolvoIdentityProvider(clientID: "test-client") == .legacy)
        #expect(VolvoIdentityProvider(clientID: nil) == .legacy)
        #expect(VolvoIdentityProvider.legacy.tokenURL.host == "volvoid.eu.volvocars.com")
        #expect(VolvoIdentityProvider.volvoID.tokenURL.host == "auth.volvocars.com")
        #expect(VolvoIdentityProvider.volvoID.authorizeURL.path.hasSuffix("/openid-connect/auth"))
        #expect(VolvoIdentityProvider.volvoID.revocationURL?.path.hasSuffix("/openid-connect/revoke") == true)
        #expect(VolvoIdentityProvider.legacy.revocationURL == nil)
    }

    @Test("A new-system client authorizes at the new server and asks for its extra scopes")
    @MainActor
    func newClientAuthorizesAtTheNewServer() async throws {
        let api = await makeAPI(clientID: newClient).api
        func query(_ tier: VolvoAPI.ScopeTier) async throws -> (host: String?, scopes: Set<String>) {
            let url = try await api.beginSignIn(tier: tier)
            let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value)
            return (url.host, Set(raw.split(separator: " ").map(String.init)))
        }

        let full = try await query(.full)
        #expect(full.host == "auth.volvocars.com")
        #expect(full.scopes.contains("conve:connectivity_status"))
        #expect(full.scopes.contains("conve:environment"))
        #expect(!full.scopes.contains("conve:navigation"))
        #expect(try await query(.standard).scopes.contains("conve:environment"))

        // The floor must stay something the application is always granted.
        let core = try await query(.core).scopes
        #expect(!core.contains("conve:environment"))
        #expect(!core.contains("conve:navigation"))
        #expect(core.contains("conve:vehicle_relation"))
    }

    @Test("An original-system client never asks for scopes only the new system knows")
    @MainActor
    func legacyClientKeepsItsScopes() async throws {
        let api = await makeAPI(clientID: "dc-test-client").api
        let url = try await api.beginSignIn(tier: .full)
        #expect(url.host == "volvoid.eu.volvocars.com")
        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "scope" })?.value)
        #expect(!raw.contains("conve:environment"))
        #expect(!raw.contains("conve:navigation"))
        #expect(!raw.contains("conve:connectivity_status"))
    }

    @Test("A session saved by the original system is dropped for a new-system client, with no request sent")
    @MainActor
    func legacySessionIsDroppedForANewClient() async throws {
        let (api, keychain) = await makeAPI(clientID: newClient, sessionIssuedBy: .legacy)
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("legacy-refresh")
        let requests = await IdentityTransport.install(on: api) { _ in (500, Data()) }

        do {
            try await api.restoreSession(preferredVIN: nil, features: FeatureSelection(enabled: []))
            Issue.record("expected a fresh sign-in to be required")
        } catch VolvoError.authenticationRequired(.signInSystemChanged) {
            // Expected: the user is asked to sign in again, and the stale token is gone.
        }
        #expect(try keychain.readVolvoSessionToken() == nil)
        #expect(requests.count == 0)
    }

    @Test("Signing out revokes the refresh token at the new Volvo ID server")
    @MainActor
    func signOutRevokesTheRefreshToken() async throws {
        let (api, keychain) = await makeAPI(clientID: newClient)
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("new-refresh")
        await api.setRefreshToken("new-refresh")
        let requests = await IdentityTransport.install(on: api) { _ in (200, Data()) }

        try await api.signOut()

        #expect(try keychain.readVolvoSessionToken() == nil)
        await awaitRequests(requests, atLeast: 1)
        #expect(requests.count == 1)
        let revoke = try #require(requests.all.first)
        #expect(revoke.url.host == "auth.volvocars.com")
        #expect(revoke.url.path.hasSuffix("/revoke"))
        #expect(revoke.body.contains("token_type_hint=refresh_token"))
        #expect(revoke.body.contains("token=new-refresh"))
    }

    @Test("A failed revocation does not fail sign-out")
    @MainActor
    func failedRevocationStillSignsOut() async throws {
        let (api, keychain) = await makeAPI(clientID: newClient)
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("new-refresh")
        await api.setRefreshToken("new-refresh")
        let requests = await IdentityTransport.install(on: api) { _ in (500, Data()) }

        try await api.signOut()

        #expect(try keychain.readVolvoSessionToken() == nil)
        await awaitRequests(requests, atLeast: 1)
        #expect(requests.hosts == ["auth.volvocars.com"])
    }

    @Test("The original system has no revocation endpoint, so signing out sends nothing")
    @MainActor
    func legacySignOutSendsNoRequest() async throws {
        let (api, keychain) = await makeAPI(clientID: "dc-test-client")
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("legacy-refresh")
        await api.setRefreshToken("legacy-refresh")
        let requests = await IdentityTransport.install(on: api) { _ in (200, Data()) }

        try await api.signOut()

        #expect(try keychain.readVolvoSessionToken() == nil)
        // Give a background request time to show up if one was wrongly scheduled.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(requests.count == 0)
    }

    @Test("HTTP 410 from an optional endpoint stands it down for the long window, like a 404")
    @MainActor
    func goneEndpointIsNotReprobed() async throws {
        let vin = "YV1IDENTITY00002"
        let backoffs = ProviderBackoffStore(database: .inMemory())
        let (api, _) = await makeAPI(clientID: newClient, backoffs: backoffs)
        let gone = try #require(VolvoError.httpFailure(statusCode: 410))
        guard case .client(statusCode: 410) = gone else {
            Issue.record("HTTP 410 should map to a client failure, got \(gone)")
            return
        }

        let first = try await api.optional(enabled: true, key: "environment", vin: vin) { () async throws -> Int in
            throw gone
        }
        #expect(first == nil)

        // A stood-down endpoint is not probed again, so this operation must never run.
        let second = try await api.optional(enabled: true, key: "environment", vin: vin) { () async throws -> Int in
            1
        }
        #expect(second == nil)

        let until = try #require(backoffs.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin)))
        #expect(until.timeIntervalSinceNow > 3_000)
    }

    @Test("A session the new system issued refreshes at the new token endpoint")
    @MainActor
    func newSessionRefreshesAtTheNewServer() async throws {
        let (api, keychain) = await makeAPI(clientID: newClient)
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("new-refresh")
        let requests = await IdentityTransport.install(on: api) { _ in
            (200, Data(#"{"access_token":"a","refresh_token":"r","expires_in":600}"#.utf8))
        }
        await api.setRefreshToken("new-refresh")

        try await api.refreshAccessToken(force: true)

        #expect(requests.hosts == ["auth.volvocars.com"])
    }

    @Test("A 422 on a command surfaces Volvo's own reason as a rejection")
    @MainActor
    func unprocessableCommandSurfacesTheReason() async throws {
        let api = await makeAPI(clientID: newClient).api
        _ = await IdentityTransport.install(on: api) { _ in
            (422, Data(#"{"error":{"message":"Invalid state","description":"The car is already locked."}}"#.utf8))
        }
        do {
            _ = try await api.dispatchCommand(.lock, vin: "YV1IDENTITY00001", accessToken: "token")
            Issue.record("expected a rejection")
        } catch let error as RemoteCommandError {
            #expect(error == .rejected("The car is already locked."))
        }
    }

    // MARK: - Harness

    /// Sign-out starts the revocation in the background, so a test waits for the request to land.
    private func awaitRequests(_ log: RequestLog, atLeast count: Int) async {
        for _ in 0..<100 {
            if log.count >= count { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func makeAPI(clientID: String, sessionIssuedBy: VolvoIdentityProvider? = nil,
                         backoffs: ProviderBackoffStore? = nil) async -> (api: VolvoAPI, keychain: KeychainStore) {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "VolvoIdentityProviderTests.\(UUID())")!
        let preferences = PreferencesStore(defaults: defaults)
        preferences.volvoRestrictedScopesEnabled = false
        // Defaults to a session from the client's own system, the usual case after sign-in.
        preferences.volvoSessionIdentity = sessionIssuedBy ?? VolvoIdentityProvider(clientID: clientID)
        let api = VolvoAPI(keychain: keychain, preferences: preferences,
                           backoffs: backoffs ?? ProviderBackoffStore(database: .inMemory()))
        await api.configure(clientID: clientID, clientSecret: "secret", vccApiKey: "key")
        return (api, keychain)
    }
}

private extension VolvoAPI {
    func setRefreshToken(_ token: String) { refreshToken = token }
}

private final class RequestLog: @unchecked Sendable {
    struct Entry: Sendable {
        let url: URL
        let body: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        // URLSession hands a URLProtocol the body as a stream, not as `httpBody`.
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        let body = String(decoding: data, as: UTF8.self)
        lock.lock()
        entries.append(Entry(url: url, body: body))
        lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    var hosts: [String] { all.compactMap { $0.url.host } }
}

private final class IdentityTransport: URLProtocol {
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    nonisolated(unsafe) static var log = RequestLog()

    static func install(on api: VolvoAPI,
                        handler: @escaping @Sendable (URLRequest) -> (Int, Data)) async -> RequestLog {
        Self.handler = handler
        Self.log = RequestLog()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityTransport.self]
        await api.replaceSession(URLSession(configuration: configuration))
        return Self.log
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.log.record(request)
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension VolvoAPI {
    func replaceSession(_ replacement: URLSession) {
        session.invalidateAndCancel()
        session = replacement
    }
}
