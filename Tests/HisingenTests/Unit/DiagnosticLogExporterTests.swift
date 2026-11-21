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
            apiPartitions: [APILogPartition(key: .account, entries: [makeEntry()])])
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
            meta: [:], unifiedLog: [], apiPartitions: [APILogPartition(key: .account, entries: [entry])],
            apiPayloadBudgetBytes: 8)
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
        await store.clearAll()
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
            refreshAttempts: 12, refreshSuccesses: 10, refreshFailures: 2,
            commandConfirmationIdentifier: "set-charge-target-80",
            commandConfirmationStatus: .awaiting,
            commandConfirmationDeadline: Date(timeIntervalSince1970: 1_700_000_120),
            commandConfirmationFeatures: [.remoteCharging],
            commandReceiptVisible: true)
        let audits: [[String: Any]] = [
            ["timestamp": "2023-11-14T22:00:00Z", "command": "lock",
             "status": "completed", "durationMilliseconds": 1200,
             "error": NSNull()]
        ]
        let data = try DiagnosticLogExporter.makeReport(
            meta: ["appVersion": "test"],
            unifiedLog: [],
            apiPartitions: [],
            refreshDiagnostics: diagnostics,
            vdmsDiscovery: VDMSDiscoveryDiagnostics(
                blockedUntil: Date(timeIntervalSince1970: 1_700_086_400),
                reason: "client-426"
            ),
            commandAudits: audits,
            databaseStats: ["sizeBytes": Int64(4096)])
        let output = String(decoding: data, as: UTF8.self)

        #expect(output.contains("\"schemaVersion\" : 5"))
        #expect(output.contains("\"refreshDiagnostics\""))
        #expect(output.contains("\"refreshAttempts\" : 12"))
        #expect(output.contains("\"commandConfirmation\""))
        #expect(output.contains("\"identifier\" : \"set-charge-target-80\""))
        #expect(output.contains("\"status\" : \"awaiting\""))
        #expect(output.contains("\"polestarVDMS\""))
        #expect(output.contains("\"reason\" : \"client-426\""))
        #expect(!output.contains("YV1XZEHR2R2371256"))
        #expect(output.contains("<vehicle>"))
        #expect(output.contains("\"commandAudit\""))
        #expect(output.contains("\"databaseStats\""))

        // Sections stay absent when no source was provided.
        let minimal = String(decoding: try DiagnosticLogExporter.makeReport(
            meta: [:], unifiedLog: [], apiPartitions: []), as: UTF8.self)
        #expect(!minimal.contains("refreshDiagnostics"))
        #expect(!minimal.contains("commandAudit"))
    }

    @Test
    func activeVDMSBackoffIsAvailableToTheDiagnosticExporter() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let blockedUntil = now.addingTimeInterval(3_600)
        let backoffs = ProviderBackoffStore(database: .inMemory())
        backoffs.block(PolestarAPI.discoveryBackoff, until: blockedUntil, reason: "client-426")

        let diagnostics = try #require(
            PolestarAPI.vdmsDiscoveryDiagnostics(backoffs: backoffs, now: now)
        )
        #expect(diagnostics.blockedUntil == blockedUntil)
        #expect(diagnostics.reason == "client-426")
        #expect(PolestarAPI.vdmsDiscoveryDiagnostics(backoffs: backoffs, now: blockedUntil) == nil)
    }

    @Test
    func requestsAreGroupedByOpaquePartitionAndNeverNameTheVIN() throws {
        let vin = "YV1XZEHR2R2371256"
        let older = APILogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), provider: .polestar,
            method: "GET", endpoint: "https://example.test/vehicles/state",
            operation: "vehicle state", statusCode: 200, responseBytes: 8,
            responsePayloadJSON: #"{"battery":82}"#, durationMilliseconds: 40, errorType: nil)
        let newer = APILogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_050), provider: .polestar,
            method: "POST", endpoint: "https://example.test/token",
            operation: "Polestar token request", statusCode: 200, responseBytes: nil,
            responsePayloadJSON: nil, durationMilliseconds: 90, errorType: nil)
        let vehicleKey = APILogPartitionKey.vehicle(vin)

        let data = try DiagnosticLogExporter.makeReport(
            meta: [:], unifiedLog: [],
            apiPartitions: [
                APILogPartition(key: vehicleKey, entries: [older]),
                APILogPartition(key: .account, entries: [newer]),
            ])
        let output = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try #require(output["apiRequests"] as? [String: Any])
        #expect(requests.keys.sorted() == [APILogPartitionKey.account.rawValue,
                                           vehicleKey.rawValue].sorted())
        #expect((requests[vehicleKey.rawValue] as? [[String: Any]])?.count == 1)
        #expect((requests["account"] as? [[String: Any]])?.count == 1)

        let summaries = try #require(output["apiRequestPartitions"] as? [[String: Any]])
        #expect(summaries.count == 2)
        #expect(summaries.compactMap { $0["requests"] as? Int } == [1, 1])

        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(vin))
        #expect(text.contains("\"schemaVersion\" : 5"))
    }

    @Test
    func exportPayloadBudgetIsSpentNewestFirstAcrossPartitions() throws {
        let body = { String(repeating: "x", count: 80) }
        func entry(_ operation: String, at seconds: TimeInterval) -> APILogEntry {
            APILogEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
                provider: .polestar, method: "GET", endpoint: "<unavailable>",
                operation: operation, statusCode: 200, responseBytes: 80,
                responsePayloadJSON: #"{"blob":"\#(body())"}"#,
                durationMilliseconds: 5, errorType: nil)
        }
        let older = APILogPartition(key: .vehicle("YV1XZEHR2R2371256"),
                                    entries: [entry("older vehicle", at: 0)])
        let newer = APILogPartition(key: .account, entries: [entry("newer account", at: 1)])
        // One body fits exactly; the ceiling then falls on the older one because the budget is
        // spent newest-first.
        let oneBody = try #require(newer.entries.first?.responsePayloadJSON?.utf8.count)

        let data = try DiagnosticLogExporter.makeReport(
            meta: [:], unifiedLog: [], apiPartitions: [older, newer],
            apiPayloadBudgetBytes: oneBody + 10)
        let output = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try #require(output["apiRequests"] as? [String: Any])
        let vehicleRows = try #require(requests[APILogPartitionKey.vehicle("YV1XZEHR2R2371256").rawValue] as? [[String: Any]])
        let accountRows = try #require(requests["account"] as? [[String: Any]])
        #expect(vehicleRows.first?["payload"] == nil)
        #expect(vehicleRows.first?["payloadOmissionReason"] as? String == "exportBudget")
        #expect(accountRows.first?["payload"] != nil)
        #expect(output["apiPayloadsTruncated"] as? Bool == true)
    }
}
