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
}
