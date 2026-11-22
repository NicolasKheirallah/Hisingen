import Foundation
import Testing
@testable import Hisingen

private let callbackVIN = "YV1CALLBACK0000001"
private let callbackCode = "authorization-code-that-must-never-be-logged"
private let callbackState = "state-that-must-never-be-logged"

/// C19. A crafted redirect must not be exchangeable for a token: the callback is checked against
/// the one registered scheme, host and path in both gates (the browser presenter and the token
/// exchange), and a refusal names what did not match without ever carrying the query.
@Suite("Volvo callback validation", .serialized)
@MainActor
struct VolvoCallbackValidationTests {

    // MARK: - Refusals

    @Test
    func aCallbackFromAnotherHostIsRefusedBeforeTheCodeIsExchanged() async throws {
        let api = try await makeAPI()
        let pending = try await beginPendingSignIn(api)
        let callback = try #require(URL(string: "hisingen://not-oauth/volvo/callback?code=\(callbackCode)&state=\(pending.state)"))

        let refused = await refuses(api, callback)
        #expect(refused, "A callback from another host must not be accepted")
        #expect(CallbackReplayTransport.requestPaths.isEmpty,
                "A refused callback must not reach the network at all")

        // The refusal must leave the pending attempt alone: the genuine callback still lands, so a
        // forged URL cannot wedge the sign-in it was aimed at.
        try await api.completeSignIn(callbackURL: pending.callback, preferredVIN: nil)
        #expect(CallbackReplayTransport.tokenRequestCount == 1)
    }

    @Test
    func aCallbackOnAnotherPathIsRefusedBeforeTheCodeIsExchanged() async throws {
        let api = try await makeAPI()
        let pending = try await beginPendingSignIn(api)
        // The path has to be the registered one, not merely start with it: a prefix check would
        // accept every one of these.
        for path in ["/volvo/callback/extra", "/volvo/callback-evil", "/polestar/callback", "/volvo/"] {
            let callback = try #require(URL(string: "hisingen://oauth\(path)?code=\(callbackCode)&state=\(pending.state)"))
            let refused = await refuses(api, callback)
            #expect(refused, "\(path) is not the registered callback path")
        }
        #expect(CallbackReplayTransport.requestPaths.isEmpty,
                "A refused callback must not reach the network at all")
    }

    @Test
    func aCallbackOnAnotherSchemeIsRefusedBeforeTheCodeIsExchanged() async throws {
        let api = try await makeAPI()
        let pending = try await beginPendingSignIn(api)
        for raw in [
            // A downgrade of either registered callback: right host and path, no TLS.
            "http://oauth/volvo/callback",
            "http://nicolaskheirallah.github.io/Hisingen/oauth-callback.html",
            "polestar-explore://oauth/volvo/callback",
            "hisingen-app://oauth/volvo/callback"
        ] {
            let callback = try #require(URL(string: "\(raw)?code=\(callbackCode)&state=\(pending.state)"))
            let refused = await refuses(api, callback)
            #expect(refused, "\(raw) is not the registered scheme")
        }
        #expect(CallbackReplayTransport.requestPaths.isEmpty,
                "A refused callback must not reach the network at all")
    }

    // MARK: - The registered callback

    @Test(arguments: [
        "hisingen://oauth/volvo/callback",
        "https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html"
    ])
    func theRegisteredCallbackStillCompletes(registeredURI: String) async throws {
        let api = try await makeAPI()
        let pending = try await beginPendingSignIn(api)
        var components = try #require(URLComponents(string: registeredURI))
        components.queryItems = [
            URLQueryItem(name: "code", value: callbackCode),
            URLQueryItem(name: "state", value: pending.state)
        ]
        let callback = try #require(components.url)

        try await api.completeSignIn(callbackURL: callback, preferredVIN: nil)
        #expect(CallbackReplayTransport.tokenRequestCount == 1,
                "The registered callback must exchange its code exactly once")
        let cars = await api.cars
        #expect(cars.map(\.vin) == [callbackVIN])
    }

    // MARK: - Logging

    @Test
    func aRefusalNamesTheComponentThatDidNotMatchAndNeverTheQuery() throws {
        let cases: [(uri: String, component: String)] = [
            ("hisingen://elsewhere/volvo/callback", "host"),
            ("hisingen://oauth/volvo/callback/extra", "path"),
            ("http://oauth/volvo/callback", "scheme"),
            ("hisingen://oauth:8443/volvo/callback", "port"),
            ("hisingen://user:pw@oauth/volvo/callback", "credentials")
        ]
        for entry in cases {
            let callback = try #require(URL(string: "\(entry.uri)?code=\(callbackCode)&state=\(callbackState)"))
            let refusal = try #require(VolvoCallback.refusal(for: callback),
                                       "\(entry.uri) must not be accepted")
            let message = refusal.logMessage
            #expect(message.contains(entry.component),
                    "\(entry.uri) should be reported as a \(entry.component) mismatch: \(message)")
            #expect(!message.contains(callbackCode), "the authorization code must never be logged")
            #expect(!message.contains(callbackState), "the state must never be logged")
        }
    }

    @Test
    func aCraftedComponentCannotFloodTheLogLine() throws {
        let long = String(repeating: "a", count: 4_000)
        let callback = try #require(URL(string: "hisingen://\(long)/volvo/callback"))
        let message = try #require(VolvoCallback.refusal(for: callback)).logMessage
        #expect(message.count < 200, "a crafted host must be bounded before it reaches the log")
    }

    // MARK: - The presenter gate

    @Test
    func thePresenterRefusesEveryMisroutedCallbackAndKeepsTheGenuineSignIn() async throws {
        let presenter = VolvoSignInPresenter(openInBrowser: { _ in true })
        let authorize = try #require(URL(string: "https://volvoid.eu.volvocars.com/as/authorization.oauth2"))
        let waiting = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        for _ in 0..<10_000 {
            if presenter.isWaitingForCallback { break }
            await Task.yield()
        }
        guard presenter.isWaitingForCallback else {
            waiting.cancel()
            Issue.record("The presenter never armed its wait for a callback")
            return
        }

        for misrouted in [
            "hisingen://not-oauth/volvo/callback?code=\(callbackCode)",
            "hisingen://oauth/volvo/callback/extra?code=\(callbackCode)",
            "http://oauth/volvo/callback?code=\(callbackCode)"
        ] {
            let callback = try #require(URL(string: misrouted))
            presenter.handleCallbackURL(callback)
            #expect(presenter.isWaitingForCallback, "\(misrouted) must not resume the sign-in")
        }

        let genuine = try #require(URL(string: "hisingen://oauth/volvo/callback?code=\(callbackCode)"))
        presenter.handleCallbackURL(genuine)
        let received = try await waiting.value
        #expect(received == genuine)
        #expect(!presenter.isWaitingForCallback)
    }

    // MARK: - Harness

    private struct PendingSignIn {
        let state: String
        let callback: URL
    }

    private func makeAPI() async throws -> VolvoAPI {
        let suite = "VolvoCallbackValidationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let api = VolvoAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"),
            preferences: PreferencesStore(defaults: defaults),
            backoffs: ProviderBackoffStore(database: VehicleDatabase.inMemory())
        )
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        await api.useCallbackReplayTransport()
        CallbackReplayTransport.reset()
        return api
    }

    private func beginPendingSignIn(_ api: VolvoAPI) async throws -> PendingSignIn {
        let authorize = try await api.beginSignIn(tier: .core)
        let state = try #require(OAuthCallback.queryValue("state", from: authorize))
        let callback = try #require(URL(string: "hisingen://oauth/volvo/callback?code=\(callbackCode)&state=\(state)"))
        return PendingSignIn(state: state, callback: callback)
    }

    private func refuses(_ api: VolvoAPI, _ callback: URL) async -> Bool {
        do {
            try await api.completeSignIn(callbackURL: callback, preferredVIN: nil)
            return false
        } catch VolvoError.authenticationRequired(.callbackRejected) {
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Replay transport

private extension VolvoAPI {
    /// Swaps in a transport that answers the token endpoint and vehicle discovery, so the
    /// exchange can run without a provider session or the network.
    func useCallbackReplayTransport() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallbackReplayTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }
}

private final class CallbackReplayTransport: URLProtocol {
    private static let log = CallbackReplayLog()

    /// The path of every request the app made through the replay session, in order. Empty means
    /// the code never left the process.
    static var requestPaths: [String] { log.paths }

    /// How many times the identity provider's token endpoint was called.
    static var tokenRequestCount: Int { log.paths.filter { $0.hasSuffix("token.oauth2") }.count }

    static func reset() { log.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.log.record(path)
        let reply = Self.reply(for: path)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func reply(for path: String) -> (status: Int, body: String) {
        if path.hasSuffix("token.oauth2") {
            return (200, #"{"access_token":"fake-access-token","refresh_token":"fake-refresh-token","expires_in":3600,"token_type":"Bearer"}"#)
        }
        if path == "/connected-vehicle/v2/vehicles" {
            return (200, #"{"data":[{"vin":"\#(callbackVIN)"}]}"#)
        }
        if path.hasPrefix("/connected-vehicle/v2/vehicles/") {
            return (200, #"{"vin":"\#(callbackVIN)","modelYear":2024}"#)
        }
        return (404, "{}")
    }
}

/// The transport runs on a URL loading thread, so the record it keeps is lock-guarded.
private final class CallbackReplayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(path)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
