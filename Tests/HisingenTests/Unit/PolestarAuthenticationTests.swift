import Foundation
import Security
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PolestarAuthenticationTests {
    private func makeAPI() async -> (PolestarAPI, KeychainStore) {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.auth.\(UUID())")
        let api = PolestarAPI(keychain: keychain)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationTransport.self]
        await api.installAuthenticationTestSession(URLSession(configuration: configuration))
        AuthenticationTransport.handler.set { request in
            if request.url?.path == "/userinfo" { return Data(#"{"sub":"account-a"}"#.utf8) }
            return Data(#"{"access_token":"command-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
        }
        return (api, keychain)
    }

    private func commandCallback(_ api: PolestarAPI) async throws -> URL {
        let url = try await api.beginCommandAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: url))
        return URL(string: "polestar-explore://explore.polestar.com?code=code&state=\(state)")!
    }

    @Test func supersededWebGrantCannotWriteTokens() async throws {
        let (api, keychain) = await makeAPI()
        let gate = AuthenticationGate()
        AuthenticationTransport.handler.set { _ in
            await gate.arriveAndWait()
            return Data(#"{"access_token":"old-access","refresh_token":"old-refresh","expires_in":3600}"#.utf8)
        }
        let exchange = Task { try await api.exchangeCodeForToken("old-code", verifier: "old-verifier") }
        await gate.waitForArrival()
        _ = try await api.beginWebAuthorization()
        await gate.release()
        do { try await exchange.value; Issue.record("Superseded grant was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.accessToken == nil)
        #expect(try keychain.readSessionToken() == nil)
    }

    @Test func supersededCommandGrantCannotWriteTokens() async throws {
        let (api, keychain) = await makeAPI()
        let callback = try await commandCallback(api)
        let gate = AuthenticationGate()
        AuthenticationTransport.handler.set { _ in
            await gate.arriveAndWait()
            return Data(#"{"access_token":"old-command","refresh_token":"old-refresh","expires_in":3600}"#.utf8)
        }
        let exchange = Task { try await api.completeCommandAuthorization(callbackURL: callback) }
        await gate.waitForArrival()
        _ = try await api.beginCommandAuthorization()
        await gate.release()
        do { try await exchange.value; Issue.record("Superseded command grant was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.commandAccessToken == nil)
        #expect(try keychain.readCommandSessionToken() == nil)
    }

    @Test func differentCommandAccountIsRejectedAndStoredSessionIsRemoved() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveCommandSessionToken("other-account-refresh")
        AuthenticationTransport.handler.set { request in
            if request.url?.path == "/userinfo" {
                let account = request.value(forHTTPHeaderField: "Authorization") == "Bearer base-access" ? "account-a" : "account-b"
                return Data("{\"sub\":\"\(account)\"}".utf8)
            }
            return Data(#"{"access_token":"other-account-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
        }
        #expect(await api.commandClientAuthorization() == .notAuthorized)
        #expect(await api.commandAccessToken == nil)
        #expect(try keychain.readCommandSessionToken() == nil)
    }

    @Test func matchingAccountCanAuthorizeAndPersistCommands() async throws {
        let (api, keychain) = await makeAPI()
        let callback = try await commandCallback(api)
        try await api.completeCommandAuthorization(callbackURL: callback)
        #expect(await api.commandClientAuthorization() == .authorized("command-access"))
        #expect(try keychain.readCommandSessionToken() == "rotated-refresh")
    }

    @Test func missingRefreshTokenCannotReuseAnOlderIndependentGrant() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveCommandSessionToken("old-refresh")
        let callback = try await commandCallback(api)
        AuthenticationTransport.handler.set { request in
            if request.url?.path == "/userinfo" { return Data(#"{"sub":"account-a"}"#.utf8) }
            return Data(#"{"access_token":"command-access","expires_in":3600}"#.utf8)
        }
        do { try await api.completeCommandAuthorization(callbackURL: callback); Issue.record("Missing refresh token accepted") }
        catch { #expect(error is PolestarError) }
        #expect(await api.commandAccessToken == nil)
    }

    @Test func initialStorageFailureDoesNotReportAuthorizationSuccess() async throws {
        let (api, keychain) = await makeAPI()
        await api.failCommandPersistence()
        let callback = try await commandCallback(api)
        do { try await api.completeCommandAuthorization(callbackURL: callback); Issue.record("Storage failure ignored") }
        catch { #expect(error is KeychainError) }
        #expect(await api.commandAccessToken == nil)
        #expect(try keychain.readCommandSessionToken() == nil)
    }

    @Test func rotatedTokenSurvivesStorageFailureForRetry() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveCommandSessionToken("old-refresh")
        await api.failCommandPersistence()
        #expect(await api.commandClientAuthorization() == .storageFailure)
        #expect(await api.commandRefreshToken == "rotated-refresh")
        #expect(await api.commandAccessToken == nil)
        await api.restoreCommandPersistence()
        #expect(await api.commandClientAuthorization() == .authorized("command-access"))
        #expect(try keychain.readCommandSessionToken() == "rotated-refresh")
    }

    @Test func temporaryIdentityFailureRetainsRotationWithoutAuthorizingCommands() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveCommandSessionToken("old-refresh")
        AuthenticationTransport.handler.set { request in
            if request.url?.path == "/userinfo" { return Data("invalid JSON".utf8) }
            return Data(#"{"access_token":"command-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
        }
        #expect(await api.commandClientAuthorization() == .unavailable)
        #expect(await api.commandRefreshToken == "rotated-refresh")
        #expect(await api.commandAccessToken == nil)
    }

    @Test func backgroundRestoreCannotReplaceAnInteractiveLogin() async throws {
        let (api, _) = await makeAPI()
        let (authorizeURL, _) = try await api.beginWebAuthorization()
        do {
            try await api.restoreSession(token: "old-refresh", preferredVIN: nil, features: .default)
            Issue.record("Background restore replaced the interactive request")
        } catch { #expect(error is CancellationError) }
        #expect(await api.webPendingState == PolestarAPI.queryValue("state", from: authorizeURL))
        await api.cancelAuthorization(state: PolestarAPI.queryValue("state", from: authorizeURL))
        #expect(await api.webAuthorizationInProgress == false)
    }

    @Test func signOutClearsLocallyBeforeRevocationAndCannotClearANewerSession() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveSessionToken("base-refresh")
        try keychain.saveCommandSessionToken("command-refresh")
        try keychain.savePassword("password")
        await api.enableTestRevocation()
        let gate = AuthenticationGate()
        AuthenticationTransport.handler.set { _ in await gate.arriveAndWait(); return Data() }
        let signOut = Task { try await api.signOut() }
        await gate.waitForArrival()
        #expect(await api.accessToken == nil)
        #expect(await api.commandAccessToken == nil)
        #expect(try keychain.readSessionToken() == nil)
        #expect(try keychain.readCommandSessionToken() == nil)
        #expect(try keychain.readPassword() == nil)
        await api.installNewTestSession()
        try keychain.saveSessionToken("new-refresh")
        await gate.release()
        try await signOut.value
        #expect(await api.accessToken == "new-access")
        #expect(try keychain.readSessionToken() == "new-refresh")
    }

    @Test func identityComparisonRequiresSameSubjectOrVerifiedEmail() {
        let a = PolestarAPI.AccountIdentity(sub: "a", email: "a@example.com", emailVerified: true)
        #expect(a.matches(.init(sub: "a", email: nil, emailVerified: nil)))
        #expect(a.matches(.init(sub: "pairwise-a", email: "a@example.com", emailVerified: true)))
        #expect(!a.matches(.init(sub: "b", email: "a@example.com", emailVerified: false)))
        #expect(!a.matches(.init(sub: "b", email: "b@example.com", emailVerified: true)))
    }
}

private extension PolestarAPI {
    func installAuthenticationTestSession(_ transport: URLSession) {
        session.invalidateAndCancel()
        session = transport
        authorizationEndpoint = URL(string: "https://auth.example/authorize")!
        tokenEndpoint = URL(string: "https://auth.example/token")!
        userinfoEndpoint = URL(string: "https://auth.example/userinfo")!
        accessToken = "base-access"
        refreshToken = "base-refresh"
        tokenExpiry = Date().addingTimeInterval(3600)
    }
    func failCommandPersistence() { saveCommandToken = { _ in throw KeychainError.status(errSecAuthFailed) } }
    func restoreCommandPersistence() { saveCommandToken = { [keychain] in try keychain.saveCommandSessionToken($0) } }
    func enableTestRevocation() { revocationEndpoint = URL(string: "https://auth.example/revoke")! }
    func installNewTestSession() { accessToken = "new-access"; refreshToken = "new-refresh" }
}

private actor AuthenticationGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

private final class AuthenticationHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) async -> Data = { _ in Data() }
    func set(_ handler: @escaping @Sendable (URLRequest) async -> Data) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler
    }
    func get() -> @Sendable (URLRequest) async -> Data {
        lock.lock(); defer { lock.unlock() }; return handler
    }
}

private final class AuthenticationTransport: URLProtocol, @unchecked Sendable {
    static let handler = AuthenticationHandler()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let respond = Self.handler.get()
        Task { @Sendable [self, respond] in
            let data = await respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
