import Foundation

extension PolestarAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: limit, operation: operation
            )
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "HTTP request")
            }
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                statusCode: http.statusCode, responseBytes: data.count,
                responseData: data, startedAt: startedAt
            )
            return (data, http)
        } catch let error as URLError {
            let wrapped = PolestarError.network(error)
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                startedAt: startedAt, error: wrapped
            )
            throw wrapped
        } catch {
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: request, operation: operation,
                startedAt: startedAt, error: error
            )
            throw error
        }
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
