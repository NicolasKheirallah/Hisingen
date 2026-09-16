import Foundation

extension VolvoAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request",
                 semanticError: (@Sendable (Data, Int) -> String?)? = nil)
    async throws -> (Data, HTTPURLResponse) {
        try await HTTPExchange.data(
            for: request, using: session, limit: limit, operation: operation, provider: .volvo,
            semanticError: semanticError
        )
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        FormURLEncoding.body(fields)
    }

    /// The OAuth `error` code classifies a rejected grant without carrying any credential, so
    /// the diagnostic log can record it even though the token body itself is never retained.
    static func oauthErrorCode(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = body["error"] as? String, !code.isEmpty else { return nil }
        return "oauth:\(code)"
    }
}
