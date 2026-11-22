import Foundation

/// One W3C Trace Context header plus the matching Volvo transaction id.
///
/// Volvo's support desk asks for `traceparent` before it can locate a request, and the API
/// declares `vcc-api-operationid` for the same job. Both go out, and the local diagnostic row
/// records the same id, so a request in `api-diagnostics.json` can be quoted to Volvo instead
/// of described to them.
struct VolvoTraceContext: Sendable {
    let traceparent: String
    let operationID: UUID

    init(operationID: UUID = UUID()) {
        self.operationID = operationID
        let traceID = operationID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parentID = String(traceID.prefix(16))
        self.traceparent = "00-\(traceID)-\(parentID)-01"
    }
}

extension VolvoAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request",
                 scope: VehicleLogScope,
                 semanticError: (@Sendable (Data, Int) -> String?)? = nil)
    async throws -> (Data, HTTPURLResponse) {
        let trace = VolvoTraceContext()
        var traced = request
        traced.setValue(trace.traceparent, forHTTPHeaderField: "traceparent")
        traced.setValue(trace.operationID.uuidString, forHTTPHeaderField: "vcc-api-operationid")
        return try await HTTPExchange.data(
            for: traced, using: session, limit: limit, operation: operation, provider: .volvo,
            scope: scope, logicalOperationID: trace.operationID, semanticError: semanticError
        )
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        FormURLEncoding.body(fields)
    }

    /// The diagnostic-log form of the OAuth `error` code; see `OAuthErrorBody`.
    static func oauthErrorCode(in data: Data) -> String? {
        OAuthErrorBody.diagnosticCode(in: data)
    }
}
