import Foundation

extension VolvoAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        try await HTTPExchange.data(
            for: request, using: session, limit: limit, operation: operation, provider: .volvo
        )
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        FormURLEncoding.body(fields)
    }
}
