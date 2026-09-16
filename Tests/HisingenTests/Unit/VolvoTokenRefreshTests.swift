import Foundation
import Testing
@testable import Hisingen

/// The provider-side half of the token lifecycle: what Volvo's refresh path does with the
/// lifecycle's outcome. A grant the identity provider declares permanently dead must clear the
/// stored credential and surface Volvo's own error; a transient rejection must leave the
/// credential alone. This classification previously had no test at all, and getting it wrong is
/// how a per-client lockout happens.
@Suite("Volvo token refresh classification", .serialized)
struct VolvoTokenRefreshTests {

    @Test func aDeadGrantClearsTheStoredRefreshTokenAndReportsInvalidCredentials() async throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("stored-refresh")
        let api = await makeAPI(keychain: keychain)
        await api.installTransport { _ in
            (400, Data(#"{"error":"invalid_grant","error_description":"rotated out"}"#.utf8))
        }
        await api.seedExpiredSession(refreshToken: "stored-refresh")

        do {
            try await api.refreshAccessToken(force: true)
            Issue.record("expected the dead grant to fail the refresh")
        } catch let error as VolvoError {
            guard case .authenticationRequired(.invalidCredentials) = error else {
                Issue.record("unexpected Volvo error: \(error)")
                return
            }
        }

        // Both copies are gone: replaying a dead grant is a failed login against the account.
        #expect(await api.refreshToken == nil)
        #expect(try keychain.readVolvoSessionToken() == nil)
    }

    @Test func aTransientRejectionLeavesTheStoredRefreshTokenIntact() async throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("stored-refresh")
        let api = await makeAPI(keychain: keychain)
        await api.installTransport { _ in (500, Data()) }
        await api.seedExpiredSession(refreshToken: "stored-refresh")

        do {
            try await api.refreshAccessToken(force: true)
            Issue.record("expected the server error to fail the refresh")
        } catch let error as VolvoError {
            guard case .server(statusCode: 500) = error else {
                Issue.record("unexpected Volvo error: \(error)")
                return
            }
        }

        // A 5xx says nothing about the grant, so destroying a still-valid credential here would
        // be the over-eager failure mode the fleet-switching tests guard against.
        #expect(await api.refreshToken == "stored-refresh")
        #expect(try keychain.readVolvoSessionToken() == "stored-refresh")
    }

    @Test func aSuccessfulRefreshRotatesAndPersistsTheToken() async throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("stored-refresh")
        let api = await makeAPI(keychain: keychain)
        await api.installTransport { _ in
            (200, Data(#"{"access_token":"fresh-access","refresh_token":"rotated","expires_in":1800}"#.utf8))
        }
        await api.seedExpiredSession(refreshToken: "stored-refresh")

        try await api.refreshAccessToken(force: true)

        #expect(await api.accessToken == "fresh-access")
        #expect(await api.refreshToken == "rotated")
        #expect(try keychain.readVolvoSessionToken() == "rotated")
    }

    @Test func aSecondCallerInsideTheGrantCooldownReusesTheToken() async throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteVolvoSessionToken() }
        try keychain.saveVolvoSessionToken("stored-refresh")
        let api = await makeAPI(keychain: keychain)
        let requests = RequestCounter()
        await api.installTransport { request in
            requests.record(request)
            return (200, Data(#"{"access_token":"fresh-access","refresh_token":"rotated","expires_in":1800}"#.utf8))
        }
        await api.seedExpiredSession(refreshToken: "stored-refresh")

        try await api.refreshAccessToken(force: true)
        // The telemetry fan-out's next caller lands immediately: the grant that just completed is
        // the freshest token obtainable, so no second grant is started.
        try await api.refreshAccessToken(force: true)

        #expect(requests.value == 1)
        #expect(await api.accessToken == "fresh-access")
    }

    // MARK: - Harness

    private func makeKeychain() -> KeychainStore {
        KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
    }

    @MainActor
    private func makeAPI(keychain: KeychainStore) async -> VolvoAPI {
        let suite = "VolvoTokenRefreshTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let api = VolvoAPI(keychain: keychain, preferences: PreferencesStore(defaults: defaults))
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        return api
    }
}

private extension VolvoAPI {
    func installTransport(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        TokenTransport.handler.set(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }

    /// Seeds a stored refresh token and an access token the server has already rejected. The
    /// refresh calls below are forced, so no renewal-window state needs seeding.
    func seedExpiredSession(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class TokenTransportHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }

    func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func get() -> @Sendable (URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class TokenTransport: URLProtocol {
    static let handler = TokenTransportHandler()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, data) = Self.handler.get()(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
