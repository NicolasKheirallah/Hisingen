import Foundation
import Testing
@testable import Hisingen

/// Polestar holds the response stream of climate and charge-target commands open after it has
/// sent its answer, so the 10 s idle timeout fires with a complete reply already read. Logged
/// history shows those commands succeeding after 10-15 s; reporting them as "outcome unknown"
/// made every such command look failed and invited a duplicate retry.
@Suite(.serialized)
struct PolestarCommandStreamTimeoutTests {
    private static let vin = "LPSVSEDEKML000001"
    private static let path = "/pccs.chronos.services.v1.TargetSocService/SetTargetSoc"

    private static func frame(_ message: Data) -> Data {
        var data = Data([0])
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(message)
        return data
    }

    private func send(_ wire: Data) async throws -> Data {
        StalledCommandStream.wire = wire
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledCommandStream.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "HisingenPolestarCommandTimeout.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session,
                                diagnosticLog: APIDiagnosticLogStore())
        return try await grpc.lastMessage(path: Self.path, message: Data(), vin: Self.vin,
                                          accessToken: "token", host: .pccs)
    }

    @Test
    func completeReplyIsUsedWhenTheStreamThenStallsUntilTimeout() async throws {
        let reply = Protobuf.intField(3, 2)
        let body = try await send(Self.frame(reply))
        #expect(body == reply)
        #expect(try PolestarGRPC.chronosResult(body, statusField: 3).outcome == .delivered)
    }

    @Test
    func timeoutInsideAFrameStaysOutcomeUnknown() async {
        let reply = Protobuf.intField(3, 2)
        let truncated = Self.frame(reply).dropLast()
        await #expect(throws: PolestarError.self) { _ = try await send(Data(truncated)) }
    }

    @Test
    func timeoutBeforeAnyFrameStaysOutcomeUnknown() async {
        await #expect(throws: PolestarError.self) { _ = try await send(Data()) }
    }
}

/// Answers 200, delivers `wire`, then fails like the request session's idle timeout does: after a
/// pause, so the reader has consumed the bytes first.
private final class StalledCommandStream: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var wire = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/grpc"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.wire.isEmpty { client?.urlProtocol(self, didLoad: Self.wire) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
}
