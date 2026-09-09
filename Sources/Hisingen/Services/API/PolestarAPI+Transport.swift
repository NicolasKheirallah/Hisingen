import Foundation

extension PolestarAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        try await HTTPExchange.data(
            for: request, using: session, limit: limit, operation: operation, provider: .polestar
        )
    }

    func validateHTTP(_ response: HTTPURLResponse, operation: String = "request") throws {
        if let failure = PolestarError.httpFailure(
            statusCode: response.statusCode,
            retryAfter: Self.retryAfter(from: response),
            operation: operation
        ) { throw failure }
    }

    func postForm(to url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        return try await perform(request)
    }
}
