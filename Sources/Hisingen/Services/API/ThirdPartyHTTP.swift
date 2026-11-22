import Foundation

/// A small first-party JSON fetch for the two optional energy feeds. Unlike `HTTPExchange`, it
/// logs under the `hisingen` provider instead of borrowing a vehicle brand, and it returns nil
/// for every failure so a missing answer can never become a guessed line.
struct ThirdPartyHTTP: Sendable {
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore

    func json(
        _ url: URL,
        headers: [String: String] = [:],
        operation: String,
        limit: Int = 256_000
    ) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200, data.count <= limit else {
                await diagnosticLog.record(
                    provider: .hisingen, request: request, operation: operation, scope: .account,
                    statusCode: http.statusCode, responseBytes: data.count, startedAt: startedAt
                )
                return nil
            }
            await diagnosticLog.record(
                provider: .hisingen, request: request, operation: operation, scope: .account,
                statusCode: http.statusCode, responseBytes: data.count,
                responseData: data, startedAt: startedAt
            )
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            await diagnosticLog.record(
                provider: .hisingen, request: request, operation: operation, scope: .account,
                startedAt: startedAt, error: error
            )
            return nil
        }
    }
}
