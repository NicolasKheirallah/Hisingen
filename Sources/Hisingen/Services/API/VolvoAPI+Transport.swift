import Foundation

extension VolvoAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: limit, operation: operation
            )
            guard let http = response as? HTTPURLResponse else {
                throw VolvoError.invalidResponse(operation: operation)
            }
            await APIDiagnosticLogStore.shared.record(
                provider: .volvo, request: request, operation: operation,
                statusCode: http.statusCode, responseBytes: data.count, startedAt: startedAt
            )
            return (data, http)
        } catch {
            await APIDiagnosticLogStore.shared.record(
                provider: .volvo, request: request, operation: operation,
                startedAt: startedAt, error: error
            )
            throw error
        }
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = fields.sorted(by: { $0.key < $1.key })
            .compactMap { key, value in
                guard let k = key.addingPercentEncoding(withAllowedCharacters: allowed),
                      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
