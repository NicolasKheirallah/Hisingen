import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct SpotPriceServiceTests {
    @Test
    func successfulDayIsFetchedOnlyOncePerCacheLifetime() async throws {
        let transport = SpotPriceTransport(status: 200)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [transport.protocolType]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        SpotPriceTransport.handler = transport
        let service = SpotPriceService(session: session, cache: SpotPriceResponseCache())
        let date = Date()

        let first = try await service.fetch(date: date, area: .se3)
        let second = try await service.fetch(date: date, area: .se3)

        #expect(first == second)
        #expect(transport.requestCount == 1)
    }

    @Test
    func unpublishedDayIsNegativeCached() async {
        let transport = SpotPriceTransport(status: 404)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [transport.protocolType]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        SpotPriceTransport.handler = transport
        let service = SpotPriceService(session: session, cache: SpotPriceResponseCache())
        let date = Date().addingTimeInterval(86_400)

        for _ in 0..<2 {
            do {
                _ = try await service.fetch(date: date, area: .se3)
                Issue.record("An unpublished day unexpectedly succeeded")
            } catch SpotPriceServiceError.httpStatus(let status) {
                #expect(status == 404)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(transport.requestCount == 1)
    }
}

private final class SpotPriceTransport: @unchecked Sendable {
    nonisolated(unsafe) static var handler: SpotPriceTransport?
    private let lock = NSLock()
    private let status: Int
    private var count = 0

    init(status: Int) { self.status = status }
    var protocolType: AnyClass { TestURLProtocol.self }
    var requestCount: Int { lock.withLock { count } }

    private func respond(to protocolInstance: URLProtocol) {
        lock.withLock { count += 1 }
        let request = protocolInstance.request
        let data = status == 200
            ? Data(#"[{"SEK_per_kWh":1.25,"EUR_per_kWh":0.1,"EXR":11.0,"time_start":"2026-09-09T00:00:00+02:00","time_end":"2026-09-09T01:00:00+02:00"}]"#.utf8)
            : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response,
                                              cacheStoragePolicy: .notAllowed)
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() { SpotPriceTransport.handler?.respond(to: self) }
    }
}
