import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct HTTPExchangeBoundaryTests {
    @Test func exactMaximumSizeIsAccepted() async throws {
        BoundaryProtocol.body = Data(repeating: 1, count: 16_384)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await HTTPExchange.data(
            for: URLRequest(url: URL(string: "https://pc-api.polestar.com/test")!),
            using: session, limit: 16_384, operation: "boundary test", provider: .polestar,
            diagnosticLog: APIDiagnosticLogStore()
        )
        #expect(bytes.count == 16_384)
        #expect(response.statusCode == 200)
    }

    @Test func oversizedBodyRetainsResponseStatusAndAttemptMetadata() async throws {
        BoundaryProtocol.body = Data(repeating: 1, count: 17)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let log = APIDiagnosticLogStore()
        let id = UUID()
        do {
            _ = try await HTTPExchange.data(
                for: URLRequest(url: URL(string: "https://pc-api.polestar.com/test")!),
                using: session, limit: 16, operation: "boundary test", provider: .polestar,
                diagnosticLog: log, logicalOperationID: id, attempt: 2
            )
            Issue.record("An oversized response must fail")
        } catch PolestarError.responseTooLarge { }
        let entry = try #require(await log.snapshot().first)
        #expect(entry.statusCode == 200)
        #expect(entry.transportError != true)
        #expect(entry.logicalOperationID == id.uuidString)
        #expect(entry.attempt == 2)
        #expect(entry.omittingPayload().logicalOperationID == id.uuidString)
    }
}

private final class BoundaryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedBody = Data()
    static var body: Data {
        get { lock.withLock { storedBody } }
        set { lock.withLock { storedBody = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
