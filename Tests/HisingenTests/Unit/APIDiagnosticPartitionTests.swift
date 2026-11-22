import Foundation
import Testing
@testable import Hisingen

/// The diagnostic log used to be one ring shared by every car. These tests pin the partition
/// contract: a vehicle's traffic is filed under that vehicle, a busy car cannot evict another
/// car's evidence, and nothing on disk or in an export names the VIN.
@Suite(.serialized)
struct APIDiagnosticPartitionTests {
    private let vinA = "YV1XZEHR2R2371256"
    private let vinB = "LVSHCAMB0NE123456"

    private func entry(_ operation: String, at date: Date, payload: String? = nil) -> APILogEntry {
        APILogEntry(timestamp: date, provider: .polestar, method: "GET", endpoint: "https://example.test/x",
                    operation: operation, statusCode: 200,
                    responseBytes: payload?.utf8.count, responsePayloadJSON: payload,
                    durationMilliseconds: 5, errorType: nil)
    }

    @Test("Each vehicle's exchange lands in its own partition")
    func recordingFilesEachEntryUnderItsVehicle() async {
        let store = APIDiagnosticLogStore()
        let base = Date()
        await store.record(provider: .polestar, request: nil, operation: "vehicle A poll",
                           scope: .vehicle(vinA), startedAt: base)
        await store.record(provider: .polestar, request: nil, operation: "vehicle B poll",
                           scope: .vehicle(vinB), startedAt: base.addingTimeInterval(1))
        await store.record(provider: .polestar, request: nil, operation: "token grant",
                           scope: .account, startedAt: base.addingTimeInterval(2))

        let parts = await store.partitions()
        #expect(parts.count == 3)
        let keyA = APILogPartitionKey.vehicle(vinA)
        let keyB = APILogPartitionKey.vehicle(vinB)
        #expect(await store.snapshot(for: keyA).map(\.operation) == ["vehicle A poll"])
        #expect(await store.snapshot(for: keyB).map(\.operation) == ["vehicle B poll"])
        #expect(await store.snapshot(for: .account).map(\.operation) == ["token grant"])
    }

    @Test("Partition keys are stable, vehicle-specific, and never carry the VIN")
    func partitionKeysAreStableAndOpaque() {
        let first = APILogPartitionKey.vehicle(vinA)
        let second = APILogPartitionKey.vehicle("  \(vinA.lowercased())  ")
        #expect(first == second)
        #expect(first.rawValue.hasPrefix("vehicle-"))
        #expect(!first.rawValue.uppercased().contains(vinA))
        #expect(first != APILogPartitionKey.vehicle(vinB))
        #expect(first.isVehicle)
        #expect(APILogPartitionKey.account.isAccount)
    }

    @Test("A vehicle scope with no VIN is not a vehicle")
    func emptyVehicleScopeFallsBackToTheAccount() async {
        let store = APIDiagnosticLogStore()
        await store.record(provider: .polestar, request: nil, operation: "blank",
                           scope: .vehicle("   "), startedAt: Date())
        #expect(await store.snapshot(for: .account).count == 1)
        #expect(await store.partitions().map(\.key) == [.account])
    }

    @Test("The merged snapshot stays in timestamp order across partitions")
    func snapshotMergesPartitionsInTimestampOrder() async {
        let store = APIDiagnosticLogStore()
        let base = Date()
        await store.record(provider: .polestar, request: nil, operation: "a1",
                           scope: .vehicle(vinA), startedAt: base)
        await store.record(provider: .polestar, request: nil, operation: "b1",
                           scope: .vehicle(vinB), startedAt: base.addingTimeInterval(1))
        await store.record(provider: .polestar, request: nil, operation: "a2",
                           scope: .vehicle(vinA), startedAt: base.addingTimeInterval(2))
        #expect(await store.snapshot().map(\.operation) == ["a1", "b1", "a2"])
    }

    @Test("One vehicle's volume cannot evict another vehicle's rows")
    func oneVehiclesVolumeCannotEvictAnother() async {
        var limits = APIDiagnosticLogStore.Limits()
        limits.maximumEntriesPerPartition = 5
        limits.maximumEntriesTotal = 10_000
        let store = APIDiagnosticLogStore(limits: limits)
        let base = Date()
        for index in 0..<40 {
            await store.record(provider: .polestar, request: nil, operation: "noisy \(index)",
                               scope: .vehicle(vinA),
                               startedAt: base.addingTimeInterval(TimeInterval(index)))
        }
        await store.record(provider: .polestar, request: nil, operation: "quiet",
                           scope: .vehicle(vinB),
                           startedAt: base.addingTimeInterval(100))

        #expect(await store.snapshot(for: .vehicle(vinA)).count == 5)
        #expect(await store.snapshot(for: .vehicle(vinB)).map(\.operation) == ["quiet"])
    }

    @Test("The fleet payload budget drops the oldest bodies across every partition")
    func fleetPayloadBudgetDropsOldestBodiesAcrossPartitions() async {
        var limits = APIDiagnosticLogStore.Limits()
        limits.maximumPayloadBytesTotal = 1_000
        limits.maximumPayloadBytesPerPartition = 1_000
        let store = APIDiagnosticLogStore(limits: limits)
        let base = Date()
        let body = String(repeating: "x", count: 400)
        let payload = Data(#"{"blob":"\#(body)"}"#.utf8)
        await store.record(provider: .polestar, request: nil, operation: "old A",
                           scope: .vehicle(vinA), responseBytes: 400,
                           responseData: payload, startedAt: base)
        await store.record(provider: .polestar, request: nil, operation: "new B",
                           scope: .vehicle(vinB), responseBytes: 400,
                           responseData: payload, startedAt: base.addingTimeInterval(1))

        // Both bodies fit (about 840 redacted bytes), so neither is dropped yet.
        #expect(await store.snapshot(for: .vehicle(vinA)).first?.responsePayloadJSON != nil)

        await store.record(provider: .polestar, request: nil, operation: "newest B",
                           scope: .vehicle(vinB), responseBytes: 400,
                           responseData: payload, startedAt: base.addingTimeInterval(2))
        // Metadata rows always survive; the oldest body goes first.
        #expect(await store.snapshot(for: .vehicle(vinA)).count == 1)
        #expect(await store.snapshot(for: .vehicle(vinA)).first?.responsePayloadJSON == nil)
        #expect(await store.snapshot(for: .vehicle(vinA)).first?.payloadOmitted == true)
        #expect(await store.snapshot(for: .vehicle(vinB)).last?.responsePayloadJSON != nil)
    }

    @Test("The partition ceiling retires the least recently active vehicle")
    func partitionCeilingDropsTheLeastRecentlyActiveVehicle() async {
        var limits = APIDiagnosticLogStore.Limits()
        limits.maximumPartitions = 2
        let store = APIDiagnosticLogStore(limits: limits)
        let base = Date()
        for (index, vin) in [vinA, vinB, "YV1XZEHR2R2379999"].enumerated() {
            await store.record(provider: .polestar, request: nil, operation: "poll",
                               scope: .vehicle(vin),
                               startedAt: base.addingTimeInterval(TimeInterval(index)))
        }
        let keys = await store.partitions().map(\.key)
        #expect(keys.count == 2)
        #expect(!keys.contains(.vehicle(vinA)))
        #expect(keys.contains(.vehicle(vinB)))
    }

    @Test("Clearing one partition keeps the rest")
    func clearingOnePartitionKeepsTheRest() async {
        let store = APIDiagnosticLogStore()
        let base = Date()
        await store.record(provider: .polestar, request: nil, operation: "a",
                           scope: .vehicle(vinA), startedAt: base)
        await store.record(provider: .polestar, request: nil, operation: "b",
                           scope: .vehicle(vinB), startedAt: base.addingTimeInterval(1))
        await store.clear(.vehicle(vinA))
        #expect(await store.snapshot(for: .vehicle(vinA)).isEmpty)
        #expect(await store.snapshot(for: .vehicle(vinB)).count == 1)
    }

    @Test("Erasing one vehicle leaves every other log intact")
    func erasingOneVehicleLeavesTheOther() async {
        let store = APIDiagnosticLogStore()
        await store.record(provider: .polestar, request: nil, operation: "a",
                           scope: .vehicle(vinA), startedAt: Date())
        await store.record(provider: .polestar, request: nil, operation: "b",
                           scope: .vehicle(vinB), startedAt: Date())
        store.eraseVehicleLogsSynchronously(vin: vinA)
        #expect(await store.snapshot(for: .vehicle(vinA)).isEmpty)
        #expect(await store.snapshot(for: .vehicle(vinB)).count == 1)
    }

    @Test("The fleet-wide erase clears account rows too")
    func erasingEverythingClearsAccountRowsToo() async {
        let store = APIDiagnosticLogStore()
        await store.record(provider: .polestar, request: nil, operation: "a",
                           scope: .vehicle(vinA), startedAt: Date())
        await store.record(provider: .polestar, request: nil, operation: "token",
                           scope: .account, startedAt: Date())
        store.eraseAllLogsSynchronously()
        #expect(await store.isEmpty())
    }

    @Test("A partitioned archive round-trips through disk")
    func partitionedArchiveRoundTripsThroughDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = APIDiagnosticLogStore(persistsToDisk: true, archiveURL: url)
        await writer.record(provider: .polestar, request: nil, operation: "a",
                            scope: .vehicle(vinA), startedAt: Date())
        await writer.record(provider: .polestar, request: nil, operation: "token",
                            scope: .account, startedAt: Date())
        await writer.flushPendingWrites()

        let reader = APIDiagnosticLogStore(persistsToDisk: true, archiveURL: url)
        #expect(await reader.snapshot(for: .vehicle(vinA)).map(\.operation) == ["a"])
        #expect(await reader.snapshot(for: .account).count == 1)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.uppercased().contains(vinA))
        #expect(contents.contains("\"version\":2") || contents.contains("\"version\" : 2"))
    }

    @Test("The single-log archive is migrated without guessing a vehicle")
    func legacyArchiveIsMigratedWithoutGuessingAVehicle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = [entry("old call", at: Date())]
        try encoder.encode(legacy).write(to: url)

        let store = APIDiagnosticLogStore(persistsToDisk: true, archiveURL: url)
        #expect(await store.snapshot(for: .legacy).map(\.operation) == ["old call"])
        #expect(await store.partitions().map(\.key) == [.legacy])
    }

    @Test("An HTTP exchange is filed under the vehicle it declared")
    func httpExchangeAttributesTheExchangeToTheDeclaredVehicle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PartitionExchangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PartitionExchangeProtocol.body = Data(#"{"ok":true}"#.utf8)
        let store = APIDiagnosticLogStore()

        _ = try await HTTPExchange.data(
            for: URLRequest(url: URL(string: "https://example.test/vehicles/state")!),
            using: session, limit: 1_024, operation: "vehicle state",
            provider: .polestar, scope: .vehicle(vinA), diagnosticLog: store)

        #expect(await store.snapshot(for: .vehicle(vinA)).map(\.operation) == ["vehicle state"])
        #expect(await store.snapshot(for: .account).isEmpty)
    }
}

private final class PartitionExchangeResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    var body: Data {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class PartitionExchangeProtocol: URLProtocol {
    static let response = PartitionExchangeResponse()

    static var body: Data {
        get { response.body }
        set { response.body = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.response.body
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
