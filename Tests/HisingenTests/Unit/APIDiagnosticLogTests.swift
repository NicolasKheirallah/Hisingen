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
            statusCode: 200, responseBytes: 42, startedAt: Date()
        )

        let data = try await store.exportData()
        let output = String(decoding: data, as: UTF8.self)
        #expect(!output.contains("YV1XZEHR2R2371256"))
        #expect(!output.contains("do-not-export"))
        #expect(!output.contains("123e4567-e89b-12d3-a456-426614174000"))
        #expect(output.contains("<vehicle>"))
        #expect(output.contains("<identifier>"))
        #expect(output.contains("responseBytes"))
    }

    @Test
    func exportIsBounded() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        for _ in 0..<600 {
            await store.record(provider: .polestar, request: nil, operation: "poll", startedAt: Date())
        }
        let data = try await store.exportData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.count == 500)
    }
}
