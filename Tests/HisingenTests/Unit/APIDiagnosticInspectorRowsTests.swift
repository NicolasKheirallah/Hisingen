import Foundation
import Testing
@testable import Hisingen

struct APIDiagnosticInspectorRowsTests {
    private let second = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ operation: String, at date: Date, status: Int = 200,
                       payload: String? = nil, scope: VehicleLogScope? = nil) -> APILogEntry {
        APILogEntry(timestamp: date, provider: .polestar, method: "POST", endpoint: "https://example.test/x",
                    operation: operation, statusCode: status, responseBytes: payload?.utf8.count,
                    responsePayloadJSON: payload, durationMilliseconds: 10, errorType: nil,
                    scopePartition: scope?.logPartition)
    }

    @Test("Requests that share a timestamp get distinct row identities")
    func sharedTimestampsStayDistinct() {
        let entries = (0..<17).map { entry("call \($0)", at: second) }
        let rows = APIDiagnosticInspectorView.rows(from: entries, matching: .init())

        #expect(rows.count == 17)
        #expect(Set(rows.map(\.id)).count == 17)
    }

    @Test("Rows are newest first and keep their identity when a filter hides earlier entries")
    func identitySurvivesFiltering() {
        let entries = [entry("a", at: second), entry("b", at: second, status: 500), entry("c", at: second)]
        let all = APIDiagnosticInspectorView.rows(from: entries, matching: .init())
        let serverErrors = APIDiagnosticInspectorView.rows(
            from: entries, matching: .init(outcome: .serverError))

        #expect(all.map(\.entry.operation) == ["c", "b", "a"])
        #expect(serverErrors.map(\.entry.operation) == ["b"])
        #expect(serverErrors.first?.id == all.first { $0.entry.operation == "b" }?.id)
    }

    @Test("A search matches the short fields and the payload body, ignoring case")
    func searchMatchesFieldsAndPayload() {
        let entries = [
            entry("GetBattery", at: second),
            entry("GetOdometer", at: second.addingTimeInterval(1), payload: #"{"Value":"NeedleInBody"}"#),
        ]
        func found(_ query: String) -> [String] {
            APIDiagnosticInspectorView.rows(from: entries, matching: .init(query: query)).map(\.entry.operation)
        }

        #expect(found("getbattery") == ["GetBattery"])
        #expect(found("  needleinbody ") == ["GetOdometer"])
        #expect(found("post https://example.test/x getodometer") == ["GetOdometer"])
        #expect(found("absent").isEmpty)
    }

    @Test("The array filter and the per-entry predicate agree")
    func applyMatchesPredicate() {
        let entries = [entry("a", at: second), entry("b", at: second.addingTimeInterval(1), status: 404)]
        let filter = APIDiagnosticInspectorFilter(outcome: .clientError)

        #expect(filter.apply(to: entries).map(\.operation) == ["b"])
    }

    @Test("A search finds an exchange by its log partition, account or vehicle digest")
    func searchMatchesTheLogPartition() {
        let vin = "YV1XZEHR2R2371256"
        let entries = [
            entry("token grant", at: second, scope: .account),
            entry("GetBattery", at: second.addingTimeInterval(1), scope: .vehicle(vin)),
            entry("legacy row", at: second.addingTimeInterval(2)),
        ]
        func found(_ query: String) -> [String] {
            APIDiagnosticInspectorView.rows(from: entries, matching: .init(query: query)).map(\.entry.operation)
        }

        #expect(found("account") == ["token grant"])
        #expect(found(VehicleLogScope.vehicle(vin).logPartition) == ["GetBattery"])
        // The partition is a digest, so searching the raw VIN must not match it.
        #expect(found(vin).isEmpty)
    }

    @Test("The merged view keeps every vehicle in timestamp order and tags each row")
    func mergedViewTagsRowsWithTheirVehicle() {
        let keyA = APILogPartitionKey.vehicle("YV1XZEHR2R2371256")
        let keyB = APILogPartitionKey.vehicle("LVSHCAMB0NE123456")
        let partitions = [
            APILogPartition(key: keyB, entries: [
                entry("b1", at: second),
                entry("b2", at: second.addingTimeInterval(2)),
            ]),
            APILogPartition(key: keyA, entries: [entry("a1", at: second.addingTimeInterval(1))]),
        ]
        let tagged = APIDiagnosticInspectorView.taggedEntries(from: partitions, selection: .all)
        #expect(tagged.map(\.entry.operation) == ["b1", "a1", "b2"])
        #expect(tagged.map(\.partition) == [keyB, keyA, keyB])

        let rows = APIDiagnosticInspectorView.rows(from: tagged, matching: .init())
        #expect(rows.map(\.entry.operation) == ["b2", "a1", "b1"])
        #expect(rows.first?.partition == keyB)
    }

    @Test("A vehicle selection shows only that vehicle, in order")
    func partitionSelectionShowsOnlyThatVehicle() {
        let keyA = APILogPartitionKey.vehicle("YV1XZEHR2R2371256")
        let keyB = APILogPartitionKey.vehicle("LVSHCAMB0NE123456")
        let partitions = [
            APILogPartition(key: keyA, entries: [entry("a1", at: second)]),
            APILogPartition(key: keyB, entries: [entry("b1", at: second.addingTimeInterval(1))]),
        ]
        let tagged = APIDiagnosticInspectorView.taggedEntries(
            from: partitions, selection: .partition(keyA))
        #expect(tagged.map(\.entry.operation) == ["a1"])
        #expect(tagged.allSatisfy { $0.partition == keyA })
    }

    @Test("A vehicle with no partition yet reads as empty rather than missing")
    func partitionWithoutEntriesIsEmpty() {
        let key = APILogPartitionKey.vehicle("YV1XZEHR2R2371256")
        #expect(APIDiagnosticInspectorView.taggedEntries(from: [], selection: .partition(key)).isEmpty)
    }
}
