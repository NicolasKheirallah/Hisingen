import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PolestarMetadataRetryTests {
    @Test func transientOwnerFailureRetriesAfterBackoff() async throws {
        let clock = MetadataRetryClock()
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.metadata.\(UUID())")
        let api = PolestarAPI(keychain: keychain, now: { clock.date })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataRetryProtocol.self]
        await api.seedMetadataRetry(session: URLSession(configuration: configuration), now: clock.date)
        MetadataRetryProtocol.reset()
        let features = FeatureSelection(enabled: [.ownerGreeting])
        try await api.prepareVehicle(vin: "VIN-A", features: features)
        #expect(await api.ownerFirstName == nil)
        try await api.prepareVehicle(vin: "VIN-A", features: features)
        #expect(MetadataRetryProtocol.count == 1)
        clock.advance(301)
        try await api.prepareVehicle(vin: "VIN-A", features: features)
        #expect(await api.ownerFirstName == "Ada")
        #expect(MetadataRetryProtocol.count == 2)
    }
}

private extension PolestarAPI {
    func seedMetadataRetry(session: URLSession, now: Date) {
        self.session = session
        accessToken = "token"
        refreshToken = "refresh"
        tokenExpiry = now.addingTimeInterval(3_600)
        tokenLifetime = 3_600
        userinfoEndpoint = URL(string: "https://idp.test/userinfo")
        restoreDiscovery(cars: [.init(vin: "VIN-A", title: "Polestar")], identities: ["VIN-A": .empty])
    }
}

private final class MetadataRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private final class MetadataRetryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let index = Self.lock.withLock { Self.requests += 1; return Self.requests }
        let response = HTTPURLResponse(url: request.url!, statusCode: index == 1 ? 503 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"given_name":"Ada","market":"SE"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
