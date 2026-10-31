import Foundation
import Testing
@testable import Hisingen

private actor HTTP2Parts {
    private(set) var messages: [Data] = []
    private(set) var statuses: [PolestarGRPCFinalStatus] = []
    func add(_ part: PolestarGRPCResponsePart) -> Bool {
        switch part {
        case .message(let data): messages.append(data)
        case .status(let status): statuses.append(status)
        case .headers: break
        }
        return true
    }
}

struct PolestarHTTP2TrailerTests {
    private func request(port: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/test.Service/Method")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 0, 0, 0, 1, 1])
        return request
    }

    private func run(_ reply: PolestarHTTP2TestServer.Reply) async throws -> ([Data], [PolestarGRPCFinalStatus], Int) {
        let server = PolestarHTTP2TestServer(reply: reply)
        let port = try server.start()
        defer { try? server.stop() }
        let parts = HTTP2Parts()
        let transport = PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .seconds(2))
        try await transport.execute(for: request(port: port), live: false) { part in await parts.add(part) }
        return (await parts.messages, await parts.statuses, server.requestCount)
    }

    @Test func receivesActualSuccessfulTrailersAfterMessage() async throws {
        let (messages, statuses, count) = try await run(.success)
        #expect(messages == [Data([42])])
        #expect(statuses.count == 1)
        #expect(statuses.first?.code == 0)
        #expect(statuses.first?.metadata["fixture"] == "actual-trailer")
        #expect(count == 1)
    }

    @Test func receivesLateFailureAndDecodesMessage() async throws {
        let (messages, statuses, count) = try await run(.failure)
        #expect(messages == [Data([42])])
        #expect(statuses.first?.code == 7)
        #expect(statuses.first?.message == "permission denied")
        #expect(statuses.first?.metadata["fixture"] == "actual-trailer")
        #expect(count == 1)
    }

    @Test func receivesTrailersOnlyFailure() async throws {
        let (messages, statuses, count) = try await run(.trailersOnly)
        #expect(messages.isEmpty)
        #expect(statuses.first?.code == 7)
        #expect(statuses.first?.message == "permission denied")
        #expect(statuses.first?.metadata["fixture"] == "only")
        #expect(count == 1)
    }

    @Test(arguments: [PolestarHTTP2TestServer.Reply.missing, .malformed, .reset, .truncated])
    func invalidTerminalResponseNeverSucceeds(_ reply: PolestarHTTP2TestServer.Reply) async throws {
        let server = PolestarHTTP2TestServer(reply: reply)
        let port = try server.start()
        defer { try? server.stop() }
        let parts = HTTP2Parts()
        do {
            try await PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .seconds(2))
                .execute(for: request(port: port), live: false) { part in await parts.add(part) }
        } catch { }
        #expect(!(await parts.statuses).contains { $0.code == 0 })
        #expect(server.requestCount == 1)
    }

    @Test func deadlineDoesNotReplay() async throws {
        let server = PolestarHTTP2TestServer(reply: .hang)
        let port = try server.start()
        defer { try? server.stop() }
        let parts = HTTP2Parts()
        do {
            try await PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .milliseconds(500))
                .execute(for: request(port: port), live: false) { part in await parts.add(part) }
        } catch { }
        #expect(!(await parts.statuses).contains { $0.code == 0 })
        #expect(server.requestCount == 1)
    }

    @Test func cancellationDoesNotReplay() async throws {
        let server = PolestarHTTP2TestServer(reply: .hang)
        let port = try server.start()
        defer { try? server.stop() }
        let parts = HTTP2Parts()
        let request = request(port: port)
        let task = Task {
            try await PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .seconds(5))
                .execute(for: request, live: false) { part in await parts.add(part) }
        }
        for _ in 0..<100 where server.requestCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = try? await task.value
        #expect(server.requestCount == 1)
        #expect(!(await parts.statuses).contains { $0.code == 0 })
    }

    @Test func stoppingAfterMessageDoesNotInventStatus() async throws {
        let server = PolestarHTTP2TestServer(reply: .success)
        let port = try server.start()
        defer { try? server.stop() }
        let parts = HTTP2Parts()
        try await PolestarHTTP2Transport(allowLoopbackPlaintext: true, timeout: .seconds(2))
            .execute(for: request(port: port), live: false) { part in
                _ = await parts.add(part)
                if case .message = part { return false }
                return true
            }
        #expect(await parts.messages == [Data([42])])
        #expect(await parts.statuses.isEmpty)
        #expect(server.requestCount == 1)
    }
}

private final class StatusZeroURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["grpc-status": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0, 0, 0, 0, 1, 42]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct URLSessionGRPCAdapterTests {
    @Test func statusZeroHeaderDoesNotDiscardBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusZeroURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionPolestarGRPCTransport(requestSession: session, liveSession: session)
        let parts = HTTP2Parts()
        try await transport.execute(for: URLRequest(url: URL(string: "https://fixture.invalid/test")!), live: false) { part in
            await parts.add(part)
        }
        #expect(await parts.messages == [Data([42])])
        #expect(await parts.statuses.first?.code == 0)
    }
}

private struct EventFixtureTransport: PolestarGRPCTransport {
    let supportsTrailers = true
    let finalStatus: PolestarGRPCFinalStatus?

    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws {
        guard try await onPart(.headers(.init(httpStatus: 200, metadata: [:]))) else { return }
        guard try await onPart(.message(Data([8, 1]))) else { return }
        if let finalStatus { _ = try await onPart(.status(finalStatus)) }
    }
}

struct PolestarTrailerConsumerTests {
    private let path = "/test.Service/Method"

    @Test func lateFailureOverridesReadBody() async throws {
        let transport = EventFixtureTransport(finalStatus: .init(code: 7, message: "denied", metadata: [:]))
        let client = PolestarGRPC(diagnosticLog: APIDiagnosticLogStore(), transport: transport)
        do {
            _ = try await client.firstMessage(path: path, message: Data(), vin: "VIN", accessToken: "token", host: .pccs)
            Issue.record("read accepted a late permission failure")
        } catch PolestarError.invalidResponse(let operation) {
            #expect(operation.contains("gRPC 7"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func lateFailureOverridesCommandBody() async throws {
        let transport = EventFixtureTransport(finalStatus: .init(code: 7, message: "denied", metadata: [:]))
        let client = PolestarGRPC(diagnosticLog: APIDiagnosticLogStore(), transport: transport)
        do {
            _ = try await client.lastMessage(path: path, message: Data(), vin: "VIN", accessToken: "token", host: .pccs)
            Issue.record("command accepted a late permission failure")
        } catch let error as RemoteCommandError {
            #expect(error == .rejected("denied"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func missingTerminalStatusLeavesCommandOutcomeUnknown() async throws {
        let client = PolestarGRPC(diagnosticLog: APIDiagnosticLogStore(), transport: EventFixtureTransport(finalStatus: nil))
        do {
            _ = try await client.lastMessage(path: path, message: Data(), vin: "VIN", accessToken: "token", host: .pccs)
            Issue.record("command accepted an incomplete response")
        } catch PolestarError.commandOutcomeUnknown { } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private final class PartialTimeoutURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/grpc"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0, 0, 0, 0, 2, 8, 1, 0, 0, 0, 0, 2, 8]))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() {}
}

struct URLSessionPartialFrameTimeoutTests {
    @Test func commandWithCompleteThenPartialFrameIsOutcomeUnknown() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PartialTimeoutURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = PolestarGRPC(session: session, diagnosticLog: APIDiagnosticLogStore())
        do {
            _ = try await client.lastMessage(path: "/test.Service/Method", message: Data(), vin: "VIN",
                                             accessToken: "token", host: .pccs)
            Issue.record("partial next frame was treated as a complete command reply")
        } catch PolestarError.commandOutcomeUnknown { } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
