import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct PolestarSessionHardeningTests {
    @Test(arguments: [
        #"{"access_token":"","expires_in":3600}"#,
        #"{"access_token":"valid","expires_in":0}"#,
        #"{"access_token":"valid","expires_in":-1}"#,
        #"{"access_token":"valid","expires_in":3600,"token_type":"mac"}"#
    ])
    func malformedSuccessfulTokenIsRejected(body: String) async throws {
        TokenFixtureProtocol.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://example.test/token")!)
        do {
            _ = try await PolestarAPI.requestToken(request: request, session: session,
                invalidReason: .callbackRejected, diagnosticLog: APIDiagnosticLogStore())
            Issue.record("Malformed grant was accepted")
        } catch {
            #expect(error is PolestarError)
        }
    }
    @Test func malformedGrantPreservesRotationWithoutAdoptingAccessToken() async throws {
        TokenFixtureProtocol.body = Data(#"{"access_token":"","refresh_token":"rotated","expires_in":3600}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let recorder = MalformedRotationRecorder()
        let request = URLRequest(url: URL(string: "https://example.test/token")!)
        do {
            _ = try await PolestarAPI.requestToken(request: request, session: session,
                invalidReason: .callbackRejected, diagnosticLog: APIDiagnosticLogStore(),
                malformedRotation: { await recorder.record($0) })
            Issue.record("Malformed grant was accepted")
        } catch { #expect(error is PolestarError) }
        #expect(await recorder.value == "rotated")
    }

    @Test func graphQLRetrySharesLogicalOperationWithoutLoggingCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphQLRetryFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let diagnostics = APIDiagnosticLogStore()
        let client = PolestarGraphQLClient(endpoint: URL(string: "https://example.test/graphql")!,
            session: session, diagnosticLog: diagnostics, appVersion: "test",
            refresh: { _ in "new-sensitive-token" })
        let result: GraphQLResponse<RetryFixturePayload> = try await client.query(
            "query { ok }", variables: NoVariables?.none, token: "old-sensitive-token", operation: "fixture")
        #expect(result.data?.ok == true)
        let entries = await diagnostics.snapshot()
        try #require(entries.count == 2)
        #expect(entries.map(\.attempt) == [1, 2])
        #expect(entries[0].logicalOperationID != nil)
        #expect(entries[0].logicalOperationID == entries[1].logicalOperationID)
        let encoded = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(!encoded.contains("old-sensitive-token"))
        #expect(!encoded.contains("new-sensitive-token"))
    }

    @Test func discoveryRejectsUntrustedTokenEndpoint() async throws {
        TokenFixtureProtocol.body = Data(#"{"issuer":"https://auth.polestar.com","token_endpoint":"https://evil.example/token","authorization_endpoint":"https://auth.polestar.com/authorize"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = PolestarOIDCClient(providerURL: URL(string: "https://auth.polestar.com")!,
                                        session: session, diagnosticLog: APIDiagnosticLogStore())
        do { _ = try await client.discover(); Issue.record("Untrusted endpoint accepted") }
        catch { #expect(error is PolestarError) }
    }

}

private final class TokenFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Artwork request ownership")
struct PolestarArtworkOwnershipTests {
    @Test func changingAngleDropsPriorImageAndStaleCompletion() {
        var artwork = PolestarArtworkLoader()
        let first = artwork.begin(vin: "VIN")
        let firstSelected = artwork.select(vin: "VIN", angle: 1, request: first, cached: Data([1]))
        #expect(firstSelected)
        let second = artwork.begin(vin: "VIN")
        let secondSelected = artwork.select(vin: "VIN", angle: 2, request: second, cached: nil)
        #expect(secondSelected)
        #expect(artwork.displayed["VIN"] == nil)
        #expect(artwork.needsImage(vin: "VIN", angle: 2))
        let staleAdopted = artwork.adopt(Data([1]), vin: "VIN", angle: 1, request: first)
        let currentAdopted = artwork.adopt(Data([2]), vin: "VIN", angle: 2, request: second)
        #expect(!staleAdopted)
        #expect(currentAdopted)
        #expect(artwork.displayed["VIN"] == Data([2]))
    }
}

@Suite("Token reset ownership")
struct TokenResetOwnershipTests {
    @Test func resetBetweenEpochCheckAndAdoptionRejectsOldGrant() async {
        let gate = EpochCheckGate()
        let lifecycle = TokenLifecycle(policy: .init(renewalMargin: { _ in 30 }),
            providerName: "test", persist: { _ in }, isDeadGrant: { _ in false })
        let grant = Task {
            try await lifecycle.refresh(.renewalWindow, epochIsCurrent: {
                await gate.wait()
                return true
            }, grant: {
                .init(accessToken: "old-access", refreshToken: "old-refresh", expiresIn: 3600)
            })
        }
        await gate.waitForArrival()
        lifecycle.reset()
        lifecycle.accessToken = "new-access"
        lifecycle.refreshToken = "new-refresh"
        await gate.release()
        do { _ = try await grant.value; Issue.record("Stale grant was adopted") }
        catch { }
        #expect(lifecycle.accessToken == "new-access")
        #expect(lifecycle.refreshToken == "new-refresh")
    }
}

private actor EpochCheckGate {
    private var arrived = false
    private var released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrived = true
        arrival.forEach { $0.resume() }
        arrival.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival.append($0) } }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite("Command operation ownership")
struct PolestarCommandOperationTests {
    @Test func oldCompletionCannotReleaseNewOperation() throws {
        var operations = PolestarCommandOperations()
        let first = operations.begin(vin: "VIN")
        let old = try #require(first)
        let blocked = operations.begin(vin: "VIN")
        #expect(blocked == nil)
        operations.reset()
        let second = operations.begin(vin: "VIN")
        let current = try #require(second)
        operations.finish(vin: "VIN", id: old)
        #expect(operations.owns(vin: "VIN", id: current))
        let stillBlocked = operations.begin(vin: "VIN")
        #expect(stillBlocked == nil)
        operations.finish(vin: "VIN", id: current)
        let third = operations.begin(vin: "VIN")
        #expect(third != nil)
    }
}

private actor MalformedRotationRecorder {
    private(set) var value: String?
    func record(_ token: String) { value = token }
}

private struct RetryFixturePayload: Decodable {
    let ok: Bool
}

private final class GraphQLRetryFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let refused = request.value(forHTTPHeaderField: "Authorization") == "Bearer old-sensitive-token"
        let response = HTTPURLResponse(url: request.url!, statusCode: refused ? 401 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((refused ? "{}" : #"{"data":{"ok":true}}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
