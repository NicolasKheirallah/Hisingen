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

    /// The diagnostic-log form of the OAuth `error` code; see `OAuthErrorBody`.
    static func oauthErrorCode(in data: Data) -> String? {
        OAuthErrorBody.diagnosticCode(in: data)
    }
}
