import Foundation
import Testing
@testable import Hisingen

/// The gRPC transport enriches diagnostic-store operation labels with the server's
/// grpc-status/grpc-message headers; these pin that enrichment without needing a
/// live endpoint.
struct PolestarGRPCDiagnosticsTests {
    @Test
    func operationWithoutGrpcDetailIsUnchanged() {
        #expect(PolestarGRPC.diagnosticOperation("gRPC /vehicle/BatteryService",
                                                 grpcStatus: nil, grpcMessage: nil)
                == "gRPC /vehicle/BatteryService")
        // An empty-string status is treated as absent, same as a missing header.
        #expect(PolestarGRPC.diagnosticOperation("gRPC x", grpcStatus: "", grpcMessage: "")
                == "gRPC x")
    }

    @Test
    func operationCarriesStatusAndDecodedMessage() {
        let label = PolestarGRPC.diagnosticOperation(
            "gRPC /vehicle/ChargingService",
            grpcStatus: "16",
            grpcMessage: "Command%20requires%20app%20pairing")
        #expect(label == "gRPC /vehicle/ChargingService (grpc-status=16, grpc-message=Command requires app pairing)")
    }

    @Test
    func undecodableMessageSurvivesVerbatim() {
        let label = PolestarGRPC.diagnosticOperation(
            "gRPC p", grpcStatus: "3", grpcMessage: "%E2%9C%93 invalid")
        #expect(label.contains("grpc-message=✓ invalid"))
    }

    @Test
    func longMessagesAreTruncated() throws {
        let label = PolestarGRPC.diagnosticOperation(
            "gRPC p", grpcStatus: "2",
            grpcMessage: String(repeating: "a", count: 500))
        let marker = try #require(label.range(of: "grpc-message="))
        // Drop the label's closing parenthesis before measuring.
        let messagePart = label[marker.upperBound...].dropLast()
        #expect(messagePart.count == 120)
        #expect(!label.contains(String(repeating: "a", count: 200)))
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
