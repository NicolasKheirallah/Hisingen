import Foundation
import Testing
@testable import Hisingen

/// The refresh-and-retry rule in `PolestarAPI.graphQL`: a rejected token is refreshed once and
/// the request sent again with the new token; a second rejection is final.
@Suite(.serialized)
@MainActor
struct PolestarGraphQLRetryTests {
    private func makeAPI() async -> PolestarAPI {
        RetryTransport.reset()
        let grpcConfiguration = URLSessionConfiguration.ephemeral
        grpcConfiguration.protocolClasses = [RetryTransport.self]
        let api = PolestarAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.GraphQLRetry.\(UUID())"),
            grpcSession: URLSession(configuration: grpcConfiguration))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryTransport.self]
        await api.installRetryTestSession(URLSession(configuration: configuration))
        return api
    }

    private func discover(_ api: PolestarAPI, token: String) async throws {
        try await api.probeGraphQL(token: token)
    }

    @Test func rejectedTokenIsRefreshedOnceAndTheRequestRepeated() async throws {
        let api = await makeAPI()
        RetryTransport.script(graphQL: [401, 200])
        try await discover(api, token: "stale-token")
        #expect(RetryTransport.refreshCount() == 1)
        #expect(RetryTransport.graphQLAuthorizations() == ["Bearer stale-token", "Bearer fresh-token"])
    }

    @Test func authenticationErrorBodyIsRetriedTheSameWay() async throws {
        let api = await makeAPI()
        RetryTransport.script(graphQL: [210, 200])
        try await discover(api, token: "stale-token")
        #expect(RetryTransport.refreshCount() == 1)
        #expect(RetryTransport.graphQLAuthorizations().last == "Bearer fresh-token")
    }

    @Test func aSecondRejectionIsFinalAndDoesNotRefreshAgain() async throws {
        let api = await makeAPI()
        RetryTransport.script(graphQL: [401, 401, 200])
        await #expect(throws: PolestarError.self) {
            try await discover(api, token: "stale-token")
        }
        #expect(RetryTransport.refreshCount() == 1)
        #expect(RetryTransport.graphQLAuthorizations().count == 2)
    }

    @Test func aHealthyTokenIsNotRefreshed() async throws {
        let api = await makeAPI()
        RetryTransport.script(graphQL: [200])
        try await discover(api, token: "good-token")
        #expect(RetryTransport.refreshCount() == 0)
        #expect(RetryTransport.graphQLAuthorizations() == ["Bearer good-token"])
    }
}

private extension PolestarAPI {
    /// Runs inside the actor so the non-Sendable response never crosses an isolation boundary.
    func probeGraphQL(token: String) async throws {
        let _: GraphQLResponse<ConsumerCarsPayloadDTO> = try await graphQL(
            query: "query GetConsumerCarsV2 { getConsumerCarsV2 { vin } }",
            token: token, operation: "test discovery")
    }

    func installRetryTestSession(_ testSession: URLSession) {
        session.invalidateAndCancel()
        session = testSession
        accessToken = "stale-token"
        refreshToken = "refresh-token"
        tokenExpiry = Date().addingTimeInterval(3600)
        tokenEndpoint = URL(string: "https://idp.test/token")
    }
}

/// Scripted responses: `200` is a data answer, `401` an HTTP rejection, and `210` stands for an
/// HTTP 200 whose body carries a GraphQL `UNAUTHENTICATED` error.
private final class RetryTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statuses: [Int] = []
    nonisolated(unsafe) private static var refreshes = 0
    nonisolated(unsafe) private static var authorizations: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        statuses = []; refreshes = 0; authorizations = []
    }
    static func script(graphQL values: [Int]) {
        lock.lock(); defer { lock.unlock() }
        statuses = values
    }
    static func refreshCount() -> Int { lock.lock(); defer { lock.unlock() }; return refreshes }
    static func graphQLAuthorizations() -> [String] { lock.lock(); defer { lock.unlock() }; return authorizations }

    private static func next(authorization: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        authorizations.append(authorization)
        return statuses.isEmpty ? 200 : statuses.removeFirst()
    }
    private static func countRefresh() { lock.lock(); defer { lock.unlock() }; refreshes += 1 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return fail(URLError(.badURL)) }
        if url.host == "idp.test" {
            Self.countRefresh()
            let body = #"{"access_token":"fresh-token","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#
            return respond(status: 200, body: body)
        }
        let status = Self.next(authorization: request.value(forHTTPHeaderField: "Authorization") ?? "")
        switch status {
        case 401:
            respond(status: 401, body: "{}")
        case 210:
            respond(status: 200, body: #"{"data":null,"errors":[{"message":"x","path":[],"extensions":{"code":"UNAUTHENTICATED"}}]}"#)
        default:
            respond(status: 200, body: #"{"data":{"getConsumerCarsV2":[]}}"#)
        }
    }

    private func respond(status: Int, body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            return fail(URLError(.badServerResponse))
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

struct GraphQLRequestBodyTests {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func variablesAreOmittedWhenThereAreNone() throws {
        let body = try object(GraphQLRequestBody(query: "query Q { q }", variables: NoVariables?.none))
        #expect(body["query"] as? String == "query Q { q }")
        #expect(body["variables"] == nil)
    }

    @Test func telematicsVariablesCarryTheVINList() throws {
        let body = try object(GraphQLRequestBody(query: "q", variables: VINListVariables(vins: ["A", "B"])))
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["vins"] as? [String] == ["A", "B"])
    }

    @Test func appBackendRequestMatchesTheAppsApolloShape() throws {
        let body = try object(AppBackendRequest(
            operationName: "GetVDMSCars", query: "query GetVDMSCars { vdms { x } }",
            extensions: .init(clientLibrary: .init(
                name: PolestarAppIdentity.graphQLClientLibrary.name,
                version: PolestarAppIdentity.graphQLClientLibrary.version))))
        #expect(body["operationName"] as? String == "GetVDMSCars")
        #expect((body["variables"] as? [String: Any])?.isEmpty == true)
        let library = try #require((body["extensions"] as? [String: Any])?["clientLibrary"] as? [String: String])
        #expect(library == ["name": "apollo-kotlin", "version": "4.4.1"])
    }

    @Test func configKeepsTheTwoOAuthClientsApart() {
        #expect(PolestarConfig.webClientID != PolestarConfig.commandClientID)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 300) == 30)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 10) == 5)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 3600) == 60)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 0) == 60)
    }
}
