import Foundation
import Testing
@testable import Hisingen

/// A Volvo command POST that fails after it left the Mac may still have run. A timeout, a lost
/// connection, a 5xx or an unreadable 2xx used to surface as a plain network or decoding error,
/// so the banner said "failed" and, for a timeout, "Retrying automatically". Polestar already
/// reports these as an unknown outcome; Volvo now does the same, and a failure that provably
/// happened before the request left stays an ordinary error.
@Suite("Volvo command outcome", .serialized)
struct VolvoCommandOutcomeTests {
    private let vin = "YV1OUTCOME000001"

    @Test("A timeout after the request was sent is an unknown outcome")
    func timeoutIsUnknown() async {
        await expectUnknown(.failure(.timedOut))
    }

    @Test("A connection lost mid-request is an unknown outcome")
    func lostConnectionIsUnknown() async {
        await expectUnknown(.failure(.networkConnectionLost))
    }

    @Test("A cancelled request is an unknown outcome")
    func cancelledRequestIsUnknown() async {
        await expectUnknown(.failure(.cancelled))
    }

    @Test("A 5xx is an unknown outcome")
    func serverErrorIsUnknown() async {
        await expectUnknown(.response(503, Data()))
        await expectUnknown(.response(500, Data("{}".utf8)))
    }

    @Test("A 2xx whose body cannot be read is an unknown outcome")
    func unreadableSuccessIsUnknown() async {
        await expectUnknown(.response(200, Data("not json".utf8)))
    }

    @Test("A request that never left the Mac stays a plain network error")
    func offlineIsNotUnknown() async {
        let error = await dispatchFailure(.failure(.notConnectedToInternet))
        guard case .network(let urlError)? = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(urlError.code == .notConnectedToInternet)
    }

    @Test("A refusal keeps its own error and is never reported as unknown")
    func refusalsKeepTheirErrors() async {
        if case .authenticationRequired? = await dispatchFailure(.response(401, Data())) {} else {
            Issue.record("a 401 must still ask for sign-in")
        }
        if case .permissionDenied? = await dispatchFailure(.response(403, Data())) {} else {
            Issue.record("a 403 must still be a permission error")
        }
        if case .rateLimited? = await dispatchFailure(.response(429, Data())) {} else {
            Issue.record("a 429 must still be a rate limit")
        }
    }

    @Test("A readable success is returned")
    func successIsReturned() async throws {
        let api = await makeAPI(reply: .response(200, Data(#"{"data":{"invokeStatus":"COMPLETED"}}"#.utf8)))
        let result = try await api.dispatchCommand(.lock, vin: vin, accessToken: "token")
        #expect(result.outcome == .completed)
    }

    @Test("The unknown outcome carries the existing may-have-reached-the-vehicle text")
    func unknownOutcomeCopyMatchesPolestar() {
        let volvo = VolvoError.commandOutcomeUnknown(operation: "lock").errorDescription
        let polestar = PolestarError.commandOutcomeUnknown(operation: "lock").errorDescription
        #expect(volvo == polestar)
        #expect(volvo?.isEmpty == false)
        guard case .commandOutcomeUnknown(let operation) = VolvoError.commandOutcomeUnknown(operation: "lock")
            .asVehicleServiceError else {
            Issue.record("the unknown outcome must survive the mapping to VehicleServiceError")
            return
        }
        #expect(operation == "lock")
    }

    // MARK: - Harness

    private func expectUnknown(_ reply: CommandTransport.Reply, sourceLocation: SourceLocation = #_sourceLocation) async {
        let error = await dispatchFailure(reply)
        if case .commandOutcomeUnknown? = error { return }
        Issue.record("expected an unknown outcome, got \(String(describing: error))", sourceLocation: sourceLocation)
    }

    private func dispatchFailure(_ reply: CommandTransport.Reply) async -> VolvoError? {
        let api = await makeAPI(reply: reply)
        do {
            _ = try await api.dispatchCommand(.lock, vin: vin, accessToken: "token")
            return nil
        } catch let error as VolvoError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }

    @MainActor
    private func makeAPI(reply: CommandTransport.Reply) async -> VolvoAPI {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "VolvoCommandOutcomeTests.\(UUID())")!
        let api = VolvoAPI(keychain: keychain, preferences: PreferencesStore(defaults: defaults))
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        CommandTransport.reply.set(reply)
        await api.useCommandTransport()
        return api
    }
}

private extension VolvoAPI {
    func useCommandTransport() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }
}

private final class CommandTransport: URLProtocol {
    enum Reply: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Reply = .response(500, Data())
        func set(_ reply: Reply) { lock.lock(); value = reply; lock.unlock() }
        func get() -> Reply { lock.lock(); defer { lock.unlock() }; return value }
    }

    static let reply = Box()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch Self.reply.get() {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
