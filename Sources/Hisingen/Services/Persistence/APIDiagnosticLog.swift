import Foundation

enum APILogProvider: String, Codable, Sendable {
    case volvo
    case polestar
}

struct APILogEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let provider: APILogProvider
    let method: String
    let endpoint: String
    let operation: String
    let statusCode: Int?
    let responseBytes: Int?
    let responsePayloadJSON: String?
    let durationMilliseconds: Int
    let errorType: String?
}

/// In-memory request metadata intended for user-initiated support exports.
/// Payloads, headers, credentials, and vehicle/account identifiers are never retained.
actor APIDiagnosticLogStore {
    static let shared = APIDiagnosticLogStore()
    private static let maximumEntries = 500
    private var entries: [APILogEntry] = []

    func record(provider: APILogProvider, request: URLRequest?, operation: String,
                statusCode: Int? = nil, responseBytes: Int? = nil, responseData: Data? = nil,
                startedAt: Date, error: Error? = nil) {
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let entry = APILogEntry(
            timestamp: Date(), provider: provider,
            method: (request?.httpMethod ?? "GET").uppercased(),
            endpoint: Self.redactURL(request?.url),
            operation: Self.redact(operation), statusCode: statusCode,
            responseBytes: responseBytes,
            responsePayloadJSON: Self.redactJSON(responseData),
            durationMilliseconds: duration,
            errorType: error.map { String(reflecting: type(of: $0)) }
        )
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    func exportData() throws -> Data {
        let payloads = entries.compactMap { entry -> Any? in
            guard let payload = entry.responsePayloadJSON,
                  let data = payload.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        guard JSONSerialization.isValidJSONObject(payloads) else {
            throw NSError(domain: "APIDiagnosticLogStore", code: 1)
        }
        return try JSONSerialization.data(withJSONObject: payloads, options: [.prettyPrinted, .sortedKeys])
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    private static func redactURL(_ url: URL?) -> String {
        guard let url else { return "<unavailable>" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return redact(components?.string ?? "<unavailable>")
    }

    private static func redact(_ value: String) -> String {
        var result = value
        result = replacingMatches(in: result, pattern: "(?i)[A-HJ-NPR-Z0-9]{17}", replacement: "<vehicle>")
        result = replacingMatches(in: result, pattern: "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", replacement: "<identifier>")
        result = replacingMatches(in: result, pattern: "(?i)(bearer|token|authorization|client_secret|password|api[_-]?key)[=:][^,; ]+", replacement: "$1=<redacted>")
        return result
    }

    private static func redactJSON(_ data: Data?) -> String? {
        guard let data, data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let sanitized = redactJSONValue(object, key: nil)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let output = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let bounded = output.prefix(256_000)
        return String(decoding: bounded, as: UTF8.self)
    }

    private static func redactJSONValue(_ value: Any, key: String?) -> Any {
        if let key {
            let normalizedKey = key.normalizedDiagnosticKey
            if sensitiveKeys.contains(normalizedKey)
                || normalizedKey.hasSuffix("_endpoint")
                || normalizedKey.hasSuffix("_uri") {
                return "<redacted>"
            }
        }
        if let string = value as? String,
           string.hasPrefix("http://") || string.hasPrefix("https://") {
            return "<redacted>"
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = redactJSONValue(item.value, key: item.key)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONValue($0, key: key) }
        }
        if let string = value as? String {
            return redact(string)
        }
        return value
    }

    private static let sensitiveKeys: Set<String> = [
        "access_token", "account_id", "address", "authorization", "authorization_endpoint", "base_url",
        "client_id", "client_secret",
        "email", "image_url", "internal_vehicle_identifier", "latitude", "license_plate",
        "id", "identifier", "endpoint", "location", "longitude", "path", "phone", "pno34", "refresh_token", "registration",
        "registration_no",
        "registration_number", "revocation_endpoint", "token", "token_endpoint", "uri", "url",
        "userinfo_endpoint", "vehicle_id", "vehicle_identifier", "vin", "vehicle_identification_number",
        "vehicle_relation"
    ]

    private static func replacingMatches(in value: String, pattern: String, replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

private extension String {
    var normalizedDiagnosticKey: String {
        let camelCase = unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar) {
                result.append("_")
            }
            result.append(String(scalar))
        }
        return camelCase
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}
