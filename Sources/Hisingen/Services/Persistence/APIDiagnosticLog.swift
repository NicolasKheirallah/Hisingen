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
                statusCode: Int? = nil, responseBytes: Int? = nil,
                startedAt: Date, error: Error? = nil) {
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let entry = APILogEntry(
            timestamp: Date(), provider: provider,
            method: (request?.httpMethod ?? "GET").uppercased(),
            endpoint: Self.redactURL(request?.url),
            operation: Self.redact(operation), statusCode: statusCode,
            responseBytes: responseBytes, durationMilliseconds: duration,
            errorType: error.map { String(reflecting: type(of: $0)) }
        )
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    func exportData() throws -> Data {
        struct Export: Codable {
            let format: String
            let generatedAt: Date
            let entries: [APILogEntry]
        }
        let export = Export(format: "hisingen-api-diagnostics-v1", generatedAt: Date(), entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
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

    private static func replacingMatches(in value: String, pattern: String, replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
