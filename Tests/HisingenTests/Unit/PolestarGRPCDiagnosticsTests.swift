import Foundation
import Testing
@testable import Hisingen

/// The gRPC transport carries `grpc-status`/`grpc-message` as structured diagnostic fields
/// instead of folding them into the operation label, so one logical operation stays one
/// grouping key. These pin the status mapping that used to be asserted against label text.
struct PolestarGRPCDiagnosticsTests {
    @Test
    func unmappedStatusKeepsServiceAndServerMessage() {
        let path = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"
        guard case .invalidResponse(let operation) = PolestarGRPC.readStatusError(
            status: "3", message: "vin%20is%20required", path: path
        ) else {
            Issue.record("an unmapped status stays invalidResponse")
            return
        }
        // The server's own explanation is the only clue that explains INVALID_ARGUMENT.
        #expect(operation.contains("3"))
        #expect(operation.contains("services.vehiclestates.dashboard.DashboardService"))
        #expect(operation.contains("vin is required"))
    }

    /// Typed gRPC status mapping: unimplemented (12) is negative-cached, unavailable (14) is
    /// transient, and unauthenticated (16) triggers re-auth.
    @Test
    func readStatusMapsWellKnownCodes() {
        let path = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"

        if case .grpcUnimplemented(let service) = PolestarGRPC.readStatusError(status: "12", path: path) {
            #expect(service == "services.vehiclestates.dashboard.DashboardService")
        } else {
            Issue.record("status 12 must map to grpcUnimplemented")
        }
        if case .grpcUnavailable = PolestarGRPC.readStatusError(status: "14", path: path) {} else {
            Issue.record("status 14 must map to grpcUnavailable")
        }
        if case .permissionDenied = PolestarGRPC.readStatusError(
            status: "14", message: "Authorization%20failed", path: path
        ) {} else {
            Issue.record("a service-scoped authorization failure must be capability-gated")
        }
        if case .authenticationRequired = PolestarGRPC.readStatusError(status: "16", path: path) {} else {
            Issue.record("status 16 must map to authenticationRequired")
        }
        if case .invalidResponse = PolestarGRPC.readStatusError(status: "7", path: path) {} else {
            Issue.record("an unmapped status stays invalidResponse")
        }
    }

    @Test
    func unimplementedReadPathIsRememberedAndSkipped() async {
        let suite = "HisingenPolestarGRPCDiagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: APIDiagnosticLogStore())
        let path = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"

        let base = URL(string: "https://backend.example")!
        let otherBase = URL(string: "https://other.example")!
        let key = PolestarGRPC.readCapabilityKey(path: path, vin: "VIN-A", base: base)
        let first = await grpc.readStatusFailure(status: "12", path: path, vin: "VIN-A", base: base)
        #expect({ if case PolestarError.grpcUnimplemented = first { return true } else { return false } }())
        #expect(await grpc.unimplementedReadPaths.contains(key))

        #expect(await grpc.isReadPathUnimplemented(path, vin: "VIN-A", base: base))
        #expect(await !grpc.isReadPathUnimplemented(path, vin: "VIN-B", base: base))
        #expect(await !grpc.isReadPathUnimplemented(path, vin: "VIN-A", base: otherBase))

        // A transient status is not remembered.
        _ = await grpc.readStatusFailure(status: "14", path: "/x/Y", vin: "VIN-A", base: base)
        #expect(await !grpc.unimplementedReadPaths.contains("/x/Y"))

        // A fresh actor restores the bounded negative capability from disk.
        let restored = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: APIDiagnosticLogStore())
        #expect(await restored.unimplementedReadPaths.contains(key))
        #expect(await restored.unimplementedReadPathExpirations[key] != nil)
    }
    @Test
    func endpointFallbackRejectsAuthenticationRateLimitingAndCancellation() {
        for error: Error in [PolestarError.authenticationRequired(.expiredSession),
                             PolestarError.rateLimited(retryAfter: 60),
                             PolestarError.server(statusCode: 503),
                             PolestarError.network(URLError(.notConnectedToInternet)),
                             CancellationError(), URLError(.cancelled)] {
            #expect(!PolestarGRPC.canTryAlternativeEndpoint(after: error))
        }
        #expect(PolestarGRPC.canTryAlternativeEndpoint(after: PolestarError.grpcUnimplemented(service: "test")))
        #expect(PolestarGRPC.canTryAlternativeEndpoint(after: PolestarError.client(statusCode: 404)))
    }

    @Test
    func legacyUnscopedFailuresDoNotSuppressVehicles() async {
        let suite = "HisingenPolestarGRPCDiagnostics.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/test/Read": Date().addingTimeInterval(3600).timeIntervalSince1970],
                     forKey: "polestar_unimplemented_grpc_paths_v2")
        let grpc = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: APIDiagnosticLogStore())
        #expect(await grpc.unimplementedReadPaths.isEmpty)
    }

    @Test(arguments: [401, 429])
    func locationAndWeatherStopAfterRequestLevelFailure(status: Int) async {
        for weather in [false, true] {
            let token = "\(status)-\(UUID())"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CapabilityFailureTransport.self]
            let transport = URLSession(configuration: config)
            defer { transport.invalidateAndCancel() }
            let grpc = PolestarGRPC(
                defaultsSuiteName: "HisingenPolestarGRPCDiagnostics.\(UUID())",
                session: transport,
                diagnosticLog: APIDiagnosticLogStore())
            do {
                if weather { _ = try await grpc.fetchWeather(vin: "VIN-A", accessToken: token) }
                else { _ = try await grpc.fetchLocation(vin: "VIN-A", accessToken: token) }
                Issue.record("Request-level failure was swallowed")
            } catch let error as PolestarError {
                if status == 401 { #expect(error.requiresAuthentication) }
                else if case .rateLimited(let retryAfter) = error { #expect(retryAfter == 60) }
                else { Issue.record("429 did not preserve rate limiting") }
            } catch { Issue.record("Unexpected error: \(error)") }
            #expect(CapabilityFailureTransport.counts.value(token) == 1)
        }
    }

    /// Discovery hardening: the v2 Accept header is tried first, and a version-shape
    /// rejection (406) falls back to the v1 document in the same session.
    @Test func discoveryFallsBackFromV2ToV1() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryV2FallbackTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "io.kheirallah.hisingen.tests.discovery-fallback.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session)
        let host = try await grpc.resolvedHost(.c3, accessToken: "token")
        #expect(host.host == "grpc-v1.example")
        let seen = DiscoveryV2FallbackTransport.acceptsSeen()
        #expect(seen == ["v2", "v1"], "expected one v2 request followed by one v1 request, saw \(seen)")
    }

    @Test func discoveryPrefersV2DocumentWhenServed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryV2PrimaryTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "io.kheirallah.hisingen.tests.discovery-v2.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session)
        let host = try await grpc.resolvedHost(.c3, accessToken: "token")
        #expect(host.host == "grpc-v2.example")
        #expect(DiscoveryV2PrimaryTransport.v1Requests() == 0, "v1 must not be requested when v2 serves a valid document")
    }

    /// A telemetry sweep resolves the C3 host from a dozen concurrent readers, and they must share
    /// one discovery request. An `await` between the single-flight check and publishing the task
    /// let every caller pass the check before any published one, so each started its own request
    /// and all but the last surfaced as a spurious `CancellationError` — which failed the whole
    /// state fetch while the diagnostic log showed a clean run.
    @Test func concurrentReadersShareOneDiscoveryRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingDiscoveryTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "io.kheirallah.hisingen.tests.discovery-single-flight.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session)
        // A non-nil second grant makes the old window suspend for certain rather than only when
        // the optional await happened to.
        await grpc.setAlternateAccessTokenProvider { "command-token" as String? }

        let hosts = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let url = try await grpc.resolvedHost(.c3, accessToken: "session-token")
                    return try #require(url.host)
                }
            }
            var seen: [String] = []
            for try await host in group { seen.append(host) }
            return seen
        }

        #expect(hosts.count == 10)
        #expect(Set(hosts) == ["grpc.example"])
        #expect(CountingDiscoveryTransport.requestCount() == 1,
                "concurrent readers must share one discovery request, saw \(CountingDiscoveryTransport.requestCount())")
    }

    /// The rejection the ladder retries is the fallback working, not a fault. It must carry the
    /// expected classification so a support export does not report one error per launch for a
    /// request that then succeeds.
    @Test func retriedDiscoveryRejectionIsClassifiedNotFailed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClassifiedRejectionDiscoveryTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "io.kheirallah.hisingen.tests.discovery-classification.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let log = APIDiagnosticLogStore()
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session, diagnosticLog: log)

        let host = try await grpc.resolvedHost(.c3, accessToken: "token")
        #expect(host.host == "grpc-classified.example")

        let rows = await log.snapshot().filter { $0.operation == "C3 discovery" }
        #expect(rows.count == 2, "expected one rejected v2 attempt and one accepted v1 attempt")
        #expect(rows.first?.statusCode == 406)
        #expect(rows.first?.semanticErrorType == "expected:discovery-retry")
        #expect(rows.last?.statusCode == 200)
        #expect(rows.last?.semanticErrorType == nil)
    }

}

/// 406s the v2 discovery request, serves a valid v1 document, and records each Accept version.
private final class DiscoveryV2FallbackTransport: URLProtocol, @unchecked Sendable {
    private static let recorder = DiscoveryAcceptRecorder()
    static func acceptsSeen() -> [String] { recorder.acceptsByVersion() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        Self.recorder.record(accept)
        let status = accept.contains("v2") ? 406 : 200
        let data = accept.contains("v2")
            ? Data()
            : Data(#"{"c3":{"grpcHost":"grpc-v1.example","grpcPort":443}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Serves a valid v2 document; any v1 request would mean the fallback fired wrongly.
private final class DiscoveryV2PrimaryTransport: URLProtocol, @unchecked Sendable {
    private static let recorder = DiscoveryAcceptRecorder()
    static func v1Requests() -> Int { recorder.v1Count() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        let isV1 = !accept.contains("v2")
        if isV1 { Self.recorder.record(accept) }
        let data = Data(#"{"c3":{"grpcHost":"grpc-v2.example","grpcPort":443},"vca-api-gateway":{"grpcHost":"vca.example","grpcPort":443}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DiscoveryAcceptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var accepts: [String] = []
    func record(_ accept: String) {
        lock.lock(); defer { lock.unlock() }
        accepts.append(accept)
    }
    func acceptsByVersion() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return accepts.map { $0.contains("v2") ? "v2" : "v1" }
    }
    func v1Count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return accepts.filter { !$0.contains("v2") }.count
    }
}

private final class CapabilityFailureCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func increment(_ token: String) { lock.lock(); defer { lock.unlock() }; counts[token, default: 0] += 1 }
    func value(_ token: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[token, default: 0] }
}

private final class CapabilityFailureTransport: URLProtocol, @unchecked Sendable {
    static let counts = CapabilityFailureCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        let discovery = request.url?.host == "cnepmob.volvocars.com"
        let status = discovery ? 200 : (token.hasPrefix("401-") ? 401 : 429)
        if !discovery { Self.counts.increment(token) }
        let data = discovery ? Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8) : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Retry-After": "60"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Counts discovery requests so the single-flight can be asserted. Holds the first response open
/// briefly so the concurrent callers are genuinely in flight together.
private final class CountingDiscoveryTransport: URLProtocol, @unchecked Sendable {
    private static let recorder = DiscoveryRequestCounter()
    static func requestCount() -> Int { recorder.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.recorder.increment()
        Thread.sleep(forTimeInterval: 0.05)
        let data = Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DiscoveryRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

/// 406s the v2 document and serves a valid v1 one, with no shared recorder so it cannot interfere
/// with the other discovery transports when tests run in parallel.
private final class ClassifiedRejectionDiscoveryTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let rejecting = (request.value(forHTTPHeaderField: "Accept") ?? "").contains("v2")
        let data = rejecting
            ? Data()
            : Data(#"{"c3":{"grpcHost":"grpc-classified.example","grpcPort":443}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: rejecting ? 406 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
