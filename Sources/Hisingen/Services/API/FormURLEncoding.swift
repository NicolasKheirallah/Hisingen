import Foundation

/// Builds `application/x-www-form-urlencoded` request bodies. Values are percent-encoded
/// explicitly: `URLComponents.percentEncodedQuery` leaves `+` intact, which a form decoder
/// reads as a space — silently corrupting credentials that contain one.
enum FormURLEncoding {
    static func body(_ fields: [String: String]) -> Data? {
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
