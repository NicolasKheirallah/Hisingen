import Foundation
import Testing
@testable import Hisingen

struct DiagnosticLogExporterTests {
    private func makeEntry(vin: String = "YV1XZEHR2R2371256") -> APILogEntry {
        APILogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .volvo,
            method: "GET",
            endpoint: "https://api.example.test/vehicles/\(vin)/state",
            operation: "vehicle \(vin) poll 123e4567-e89b-12d3-a456-426614174000",
            statusCode: 200, responseBytes: 42,
            responsePayloadJSON: #"{"batteryPercentage":82}"#,
            durationMilliseconds: 120, errorType: nil)
    }

    @Test
    func reportRedactsIdentifiersAndKeepsUsefulMetadata() throws {
        let logEntry = DiagnosticLogExporter.UnifiedLogEntry(
            date: Date(timeIntervalSince1970: 1_700_000_001),
            level: "error", category: "refresh",
            message: "Refresh failed for YV1XZEHR2R2371256 (token=super-secret)")

        let data = try DiagnosticLogExporter.makeReport(
            meta: ["appVersion": "test"],
            unifiedLog: [logEntry],
            apiEntries: [makeEntry()])
        let output = String(decoding: data, as: UTF8.self)

        #expect(!output.contains("YV1XZEHR2R2371256"))
        #expect(!output.contains("super-secret"))
        #expect(!output.contains("123e4567-e89b-12d3-a456-426614174000"))
        #expect(output.contains("<vehicle>"))
        #expect(output.contains("<identifier>"))
        #expect(output.contains("<redacted>"))

        #expect(output.contains("\"appVersion\""))
        #expect(output.contains("\"unifiedLog\""))
        #expect(output.contains("\"refresh\""))
        #expect(output.contains("batteryPercentage"))
        #expect(output.contains("200"))
    }

    @Test
    func oversizedPayloadsAreOmittedWithoutDroppingRows() throws {
        let big = String(repeating: "x", count: 64)
        let entry = APILogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .polestar, method: "POST", endpoint: "<unavailable>",
            operation: "poll", statusCode: 500, responseBytes: nil,
            responsePayloadJSON: #"{"blob":"\#(big)"}"#,
            durationMilliseconds: 5, errorType: "URLError")
        let data = try DiagnosticLogExporter.makeReport(
            meta: [:], unifiedLog: [], apiEntries: [entry], apiPayloadBudgetBytes: 8)
        let output = String(decoding: data, as: UTF8.self)

        #expect(!output.contains(big))
        #expect(output.contains("poll"))
        #expect(output.contains("payloadOmitted"))
        #expect(output.contains("apiPayloadsTruncated"))
        #expect(output.contains("URLError"))
    }

    @Test
    func unifiedLogCollectorIsBoundedAndOrdered() {
        let entries = DiagnosticLogExporter.collectUnifiedLogEntries(lookback: 3_600, maxEntries: 50)
        #expect(entries.count <= 50)
        for pair in zip(entries, entries.dropFirst()) {
            #expect(pair.0.date <= pair.1.date)
        }
    }

    @Test
    func snapshotReturnsFullEntriesForBundle() async throws {
        let store = APIDiagnosticLogStore()
        await store.clear()
        await store.record(provider: .polestar, request: nil, operation: "poll",
                           statusCode: 200, responseBytes: 10,
                           responseData: Data(#"{"battery":1}"#.utf8), startedAt: Date())
        let entries = await store.snapshot()

        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.provider == .polestar)
        #expect(entry.operation == "poll")
        #expect(entry.statusCode == 200)
        #expect(entry.responsePayloadJSON != nil)
    }

    @Test
    func vinHeuristicRequiresTwoDigits() {
        // Ordinary 17-letter words must survive; a real VIN has digits.
        #expect(DiagnosticRedaction.redact("key batteryPercentage end").contains("batteryPercentage"))
        let oneDigit = String(repeating: "A", count: 16) + "7"
        #expect(DiagnosticRedaction.redact(oneDigit) == oneDigit)
        let twoDigits = String(repeating: "A", count: 15) + "77"
        #expect(DiagnosticRedaction.redact(twoDigits) == "<vehicle>")
        #expect(DiagnosticRedaction.redact("VIN YV1XZEHR2R2371256 ok").contains("<vehicle>"))
        #expect(!DiagnosticRedaction.redact("VIN YV1XZEHR2R2371256 ok").contains("YV1XZ"))
    }

    @Test
    func reportIncludesSchemaVersionAndOptionalSections() throws {
        let diagnostics = DiagnosticsSnapshot(
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            lastError: "rate limited for YV1XZEHR2R2371256",
            latency: 0.42,
            nextRefresh: Date(timeIntervalSince1970: 1_700_000_300),
            sessionValid: true, networkAvailable: true, refreshInProgress: false,
            refreshAttempts: 12, refreshSuccesses: 10, refreshFailures: 2)
        let audits: [[String: Any]] = [
            ["timestamp": "2023-11-14T22:00:00Z", "command": "lock",
             "status": "completed", "durationMilliseconds": 1200,
             "error": NSNull()]
        ]
        let data = try DiagnosticLogExporter.makeReport(
            meta: ["appVersion": "test"],
            unifiedLog: [],
            apiEntries: [],
            refreshDiagnostics: diagnostics,
            commandAudits: audits,
            databaseStats: ["sizeBytes": Int64(4096)])
        let output = String(decoding: data, as: UTF8.self)

        #expect(output.contains("\"schemaVersion\" : 2"))
        #expect(output.contains("\"refreshDiagnostics\""))
        #expect(output.contains("\"refreshAttempts\" : 12"))
        #expect(!output.contains("YV1XZEHR2R2371256"))
        #expect(output.contains("<vehicle>"))
        #expect(output.contains("\"commandAudit\""))
        #expect(output.contains("\"databaseStats\""))

        // Sections stay absent when no source was provided.
        let minimal = String(decoding: try DiagnosticLogExporter.makeReport(
            meta: [:], unifiedLog: [], apiEntries: []), as: UTF8.self)
        #expect(!minimal.contains("refreshDiagnostics"))
        #expect(!minimal.contains("commandAudit"))
    }
}
