import Foundation
import Testing
@testable import Hisingen

struct PolestarSoftwareDeadlineTests {
    @Test(arguments: [false, true], [false, true])
    func softwareReadsBoundRefreshLatencyWithoutShorteningCommandVerification(
        requireComplete: Bool, firstRequestTimesOut: Bool
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SoftwareDiscoveryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = SoftwareDeadlineTransport(firstRequestTimesOut: firstRequestTimesOut)
        let suite = "software-deadline.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let client = PolestarGRPC(defaultsSuiteName: suite, session: session,
                                 diagnosticLog: APIDiagnosticLogStore(), transport: transport)
        do {
            _ = try await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en",
                                               requireComplete: requireComplete)
            Issue.record("Timed-out software must remain unavailable")
        } catch {
            #expect(error is PolestarError)
        }
        let timeouts = await transport.timeouts
        #expect(timeouts.count == (firstRequestTimesOut ? 1 : 2))
        #expect(timeouts.allSatisfy { $0 == (requireComplete ? 60 : 6) })
    }
}

private actor SoftwareDeadlineTransport: PolestarGRPCTransport {
    nonisolated let supportsTrailers = true
    private(set) var timeouts: [TimeInterval] = []
    let firstRequestTimesOut: Bool

    init(firstRequestTimesOut: Bool) { self.firstRequestTimesOut = firstRequestTimesOut }

    func execute(for request: URLRequest, live: Bool,
                 onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool) async throws {
        timeouts.append(request.timeoutInterval)
        guard try await onPart(.headers(.init(httpStatus: 200, metadata: [:]))) else { return }
        if !firstRequestTimesOut, timeouts.count == 1 {
            guard try await onPart(.message(Protobuf.messageField(1, Data()))) else { return }
            _ = try await onPart(.status(.init(code: 0, message: nil, metadata: [:])))
            return
        }
        _ = try await onPart(.status(.init(code: 4, message: "deadline exceeded", metadata: [:])))
    }
}

private final class SoftwareDiscoveryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
