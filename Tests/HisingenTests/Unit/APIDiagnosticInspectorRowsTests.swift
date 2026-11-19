import Foundation
import Testing
@testable import Hisingen

struct APIDiagnosticInspectorRowsTests {
    private let second = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ operation: String, at date: Date, status: Int = 200,
                       payload: String? = nil) -> APILogEntry {
        APILogEntry(timestamp: date, provider: .polestar, method: "POST", endpoint: "https://example.test/x",
                    operation: operation, statusCode: status, responseBytes: payload?.utf8.count,
                    responsePayloadJSON: payload, durationMilliseconds: 10, errorType: nil)
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
}
