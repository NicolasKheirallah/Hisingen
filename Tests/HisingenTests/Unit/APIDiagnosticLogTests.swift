import Foundation
import Testing
@testable import Hisingen

struct APIDiagnosticLogTests {
    @Test
    func recordRedactsVehicleIdentifiersAndSecrets() async throws {
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

        let entries = await store.snapshot()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(!entry.endpoint.contains("YV1XZEHR2R2371256"))
        #expect(!entry.operation.contains("YV1XZEHR2R2371256"))
        #expect(!entry.operation.contains("123e4567-e89b-12d3-a456-426614174000"))
        #expect(!entry.endpoint.contains("token=secret"))
        let payload = try #require(entry.responsePayloadJSON)
        #expect(!payload.contains("YV1XZEHR2R2371256"))
        #expect(!payload.contains("59.4"))
        #expect(!payload.contains("api.example.test"))
        #expect(payload.contains("batteryPercentage"))
    }

    @Test
    func errorTypeCarriesEnumPayloadsAndCodes() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        let startedAt = Date().addingTimeInterval(-0.05)
        await store.record(provider: .volvo, request: nil, operation: "poll",
                           startedAt: startedAt,
                           error: URLError(.timedOut))
        let entries = await store.snapshot()
        let entry = try #require(entries.first)

        // The type name alone cannot distinguish `server(statusCode: 503)` from 429 —
        // the description must carry payload/codes.
        #expect(entry.errorType?.contains("URLError") == true)
        #expect(entry.durationMilliseconds >= 0)
        // Timestamp is the request start, not completion, for unified-log correlation.
        #expect(abs(entry.timestamp.timeIntervalSince(startedAt)) < 0.001)
    }

    @Test
    func exportIsBoundedByCountAndAge() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        // Span ends before the retention cutoff so *every* entry is too old.
        let old = Date().addingTimeInterval(-APIDiagnosticLogStore.retentionInterval - 700)
        for index in 0..<600 {
            await store.record(
                provider: .polestar,
                request: nil,
                operation: "poll",
                responseData: Data(#"{"battery":1}"#.utf8),
                startedAt: old.addingTimeInterval(TimeInterval(index)),
                timestamp: old.addingTimeInterval(TimeInterval(index))
            )
        }
        #expect(await store.snapshot().isEmpty)
    }

    @Test
    func totalPayloadBudgetDropsOldestBodies() async throws {
        let store = APIDiagnosticLogStore(totalPayloadBudget: 5_000)
        await store.clear()
        let base = Date()
        let body = Data(#"{"blob":"\#(String(repeating: "x", count: 900))"}"#.utf8)
        for index in 0..<10 {
            await store.record(provider: .polestar, request: nil, operation: "poll \(index)",
                               responseBytes: 1_000, responseData: body,
                               startedAt: base.addingTimeInterval(TimeInterval(index)),
                               timestamp: base.addingTimeInterval(TimeInterval(index)))
        }
        let entries = await store.snapshot()
        #expect(entries.count == 10)
        // Metadata rows all survive; bodies are kept newest-first.
        #expect(entries.last?.responsePayloadJSON != nil)
        #expect(entries.first?.responsePayloadJSON == nil)
        #expect(entries.first?.operation.hasSuffix("poll 0") == true)
    }

    @Test
    func countCapTrimsOldestFirst() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        // Recent timestamps: this exercises the count cap, not the age window.
        let base = Date()
        for index in 0..<(APIDiagnosticLogStore.maximumEntries + 100) {
            await store.record(provider: .polestar, request: nil, operation: "poll \(index)",
                               startedAt: base.addingTimeInterval(TimeInterval(index)),
                               timestamp: base.addingTimeInterval(TimeInterval(index)))
        }
        let entries = await store.snapshot()
        #expect(entries.count == APIDiagnosticLogStore.maximumEntries)
        #expect(entries.first?.operation.hasSuffix("poll 100") == true)
        #expect(entries.last?.operation.hasSuffix("poll \(APIDiagnosticLogStore.maximumEntries + 99)") == true)
    }
}
