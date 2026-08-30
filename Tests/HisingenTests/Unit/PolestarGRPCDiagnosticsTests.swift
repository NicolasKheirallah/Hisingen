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

    /// Read paths used to collapse every non-zero gRPC status into a generic
    /// `invalidResponse`; the typed mapping is what lets a permanently-unimplemented service
    /// be negative-cached and a `16` trigger re-auth.
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
        let grpc = PolestarGRPC(defaultsSuiteName: suite)
        let path = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"

        let first = await grpc.readStatusFailure(status: "12", path: path)
        #expect({ if case PolestarError.grpcUnimplemented = first { return true } else { return false } }())
        #expect(await grpc.unimplementedReadPaths.contains(path))

        // A transient status is not remembered.
        _ = await grpc.readStatusFailure(status: "14", path: "/x/Y")
        #expect(await !grpc.unimplementedReadPaths.contains("/x/Y"))

        // A fresh actor restores the bounded negative capability from disk.
        let restored = PolestarGRPC(defaultsSuiteName: suite)
        #expect(await restored.unimplementedReadPaths.contains(path))
        #expect(await restored.unimplementedReadPathExpirations[path] != nil)
    }
}
