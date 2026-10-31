import Foundation
import Testing
@testable import Hisingen

/// Climate and charge-target commands get a complete reply and then no closing status: the stream
/// stays open until the client's own deadline fires (logged successes ended at 10-15 s). The reply
/// message carries the command status, so that deadline must not turn a delivered command into
/// "outcome unknown", while a deadline with no reply at all still must.
struct PolestarCommandDeadlineTests {
    private static let path = "/pccs.chronos.services.v1.TargetSocService/SetTargetSoc"
    private static let reply = Protobuf.intField(3, 2)

    private static func head() -> PolestarGRPCResponsePart {
        .headers(.init(httpStatus: 200, metadata: [:]))
    }

    private static func status(_ code: Int, _ message: String? = nil) -> PolestarGRPCResponsePart {
        .status(.init(code: code, message: message, metadata: [:]))
    }

    private func send(_ parts: [PolestarGRPCResponsePart], trailers: Bool = true) async throws -> Data {
        let suite = "HisingenPolestarCommandDeadline.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: APIDiagnosticLogStore(),
                                transport: ScriptedTransport(supportsTrailers: trailers, parts: parts))
        return try await grpc.lastMessage(path: Self.path, message: Data(), vin: "LPSVSEDEKML000001",
                                          accessToken: "token", host: .pccs)
    }

    @Test
    func replyFollowedByDeadlineIsTheCommandAnswer() async throws {
        let body = try await send([Self.head(), .message(Self.reply), Self.status(4, "Deadline expired")])
        #expect(body == Self.reply)
        #expect(try PolestarGRPC.chronosResult(body, statusField: 3).outcome == .delivered)
    }

    @Test
    func replyFollowedByOkStatusIsTheCommandAnswer() async throws {
        let body = try await send([Self.head(), .message(Self.reply), Self.status(0)])
        #expect(body == Self.reply)
    }

    @Test
    func deadlineWithoutAReplyIsAnUnknownOutcome() async {
        await #expect(throws: PolestarError.self) {
            _ = try await send([Self.head(), Self.status(4, "Deadline expired")])
        }
    }

    @Test
    func replyWithoutAnyClosingStatusIsAnUnknownOutcome() async {
        await #expect(throws: PolestarError.self) {
            _ = try await send([Self.head(), .message(Self.reply)])
        }
    }

    @Test
    func laterRefusalStillWinsOverTheReply() async {
        await #expect(throws: RemoteCommandError.self) {
            _ = try await send([Self.head(), .message(Self.reply), Self.status(7, "permission denied")])
        }
    }

    @Test
    func commandsDoNotWaitSixtySeconds() {
        #expect(PolestarGRPC.commandDeadline <= 20)
    }

    /// What the real HTTP/2 transport emits for "reply, then silence", the shape `lastMessage`
    /// relies on above: the message first, then a deadline-exceeded status.
    @Test
    func httpTwoTransportReportsTheDeadlineAfterTheReply() async throws {
        let server = PolestarHTTP2TestServer(reply: .replyThenHang)
        let port = try server.start()
        defer { try? server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/test.Service/Method")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 0, 0, 0, 1, 1])
        let seen = SeenParts()
        let transport = PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .milliseconds(600))
        do {
            try await transport.execute(for: request, live: false) { part in await seen.add(part) }
        } catch {
            Issue.record("the transport threw instead of reporting a status: \(error)")
        }
        #expect(await seen.messages == [Data([42])])
        #expect(await seen.codes == [PolestarGRPC.deadlineExceededStatus])
        #expect(server.requestCount == 1)
    }
}

private struct ScriptedTransport: PolestarGRPCTransport {
    let supportsTrailers: Bool
    let parts: [PolestarGRPCResponsePart]

    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws {
        for part in parts {
            if try await !onPart(part) { return }
        }
    }
}

private actor SeenParts {
    private(set) var messages: [Data] = []
    private(set) var codes: [Int] = []
    func add(_ part: PolestarGRPCResponsePart) -> Bool {
        switch part {
        case .message(let data): messages.append(data)
        case .status(let status): codes.append(status.code)
        case .headers: break
        }
        return true
    }
}
