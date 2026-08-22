import Foundation
import Testing
@testable import Hisingen

struct APIDiagnosticLogTests {
    @Test
    func exportRedactsVehicleIdentifiersAndSecrets() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        var request = URLRequest(url: URL(string: "https://api.example.test/vehicles/YV1XZEHR2R2371256/state?token=secret")!)
        request.httpMethod = "POST"
        request.setValue("Bearer do-not-export", forHTTPHeaderField: "Authorization")

        await store.record(
            provider: .volvo, request: request,
            operation: "vehicle YV1XZEHR2R2371256 request 123e4567-e89b-12d3-a456-426614174000",
            statusCode: 200, responseBytes: 42,
            responseData: Data(#"{"batteryPercentage":82,"vin":"YV1XZEHR2R2371256","latitude":59.4,"model":"V60","endpoint":"https://api.example.test/vehicles/secret"}"#.utf8),
            startedAt: Date()
        )

        let data = try await store.exportData()
        let output = String(decoding: data, as: UTF8.self)
        #expect(!output.contains("YV1XZEHR2R2371256"))
        #expect(!output.contains("do-not-export"))
        #expect(!output.contains("ZCJ06G"))
        #expect(!output.contains("123e4567-e89b-12d3-a456-426614174000"))
        #expect(output.contains("batteryPercentage"))
        #expect(output.contains("82"))
        #expect(!output.contains("59.4"))
        #expect(!output.contains("api.example.test"))
        #expect(!output.contains("authorization_endpoint"))
        #expect(!output.contains("vehicle discovery"))
        #expect(!output.contains("entries"))
    }

    @Test
    func exportIsBounded() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        for _ in 0..<600 {
            await store.record(
                provider: .polestar,
                request: nil,
                operation: "poll",
                responseData: Data(#"{"battery":1}"#.utf8),
                startedAt: Date()
            )
        }
        let data = try await store.exportData()
        let payloads = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(payloads.count == 500)
    }
}
