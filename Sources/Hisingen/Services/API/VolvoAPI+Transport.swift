import Foundation

extension VolvoAPI {
    func perform(_ request: URLRequest, limit: Int = 2_000_000,
                 operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        try await HTTPExchange.data(
            for: request, using: session, limit: limit, operation: operation, provider: .volvo
        )
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
