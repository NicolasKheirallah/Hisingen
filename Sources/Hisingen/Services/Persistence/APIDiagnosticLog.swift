import Foundation

enum APILogProvider: String, Codable, Sendable {
    case volvo
    case polestar
    /// Hisingen's own first-party requests (update checks). Deliberately not used for
    /// vehicle APIs so provider-scoped analysis stays clean.
    case hisingen
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

    var payloadOmitted: Bool { responsePayloadJSON == nil && responseBytes != nil }

    /// Same record without the payload body (used when the cumulative payload budget
    /// is exhausted). Distinguished in exports by `payloadOmitted`.
    func omittingPayload() -> APILogEntry {
        APILogEntry(
            timestamp: timestamp, provider: provider, method: method, endpoint: endpoint,
            operation: operation, statusCode: statusCode, responseBytes: responseBytes,
            responsePayloadJSON: nil, durationMilliseconds: durationMilliseconds,
            errorType: errorType)
    }
}

/// Redacted request metadata intended for user-initiated support exports. Payloads,
/// headers, credentials, and vehicle/account identifiers are never retained raw.
///
/// Retention is bounded both by count and by age (24 h), and the `shared` instance
/// persists its redacted entries to Application Support (debounced) so a crash or
/// relaunch no longer wipes the evidence — direct initializations (tests) stay
/// memory-only to remain hermetic.
actor APIDiagnosticLogStore {
    static let shared = APIDiagnosticLogStore(persistsToDisk: true)
    static let maximumEntries = 2_000
    /// Matches the diagnostic bundle's unified-log lookback window.
    static let retentionInterval: TimeInterval = 24 * 3_600
    private static let persistDebounce: Duration = .seconds(3)
    /// Cumulative cap on retained payload bodies (metadata rows are tiny). Without it,
    /// 2,000 entries x 256 KB each could produce a half-gigabyte archive in a worst case.
    /// Rows past the budget keep their metadata and lose only their payload body,
    /// oldest first — mirroring the export bundle's own budgeting.
    static let maximumTotalPayloadBytes = 32 * 1024 * 1024

    private let persistsToDisk: Bool
    private let totalPayloadBudgetOverride: Int?
    private var entries: [APILogEntry] = []
    private var loadedFromDisk = false
    private var saveScheduled = false

    init(persistsToDisk: Bool = false, totalPayloadBudget: Int? = nil) {
        self.persistsToDisk = persistsToDisk
        self.totalPayloadBudgetOverride = totalPayloadBudget
    }

    func record(provider: APILogProvider, request: URLRequest?, operation: String,
                statusCode: Int? = nil, responseBytes: Int? = nil, responseData: Data? = nil,
                startedAt: Date, error: Error? = nil, timestamp overrideTimestamp: Date? = nil) {
        ensureLoaded()
        let completedAt = Date()
        let entry = APILogEntry(
            // Request start, not completion — keeps exports correlatable with the
            // unified log's timestamps for the same request.
            timestamp: overrideTimestamp ?? startedAt,
            provider: provider,
            method: (request?.httpMethod ?? "GET").uppercased(),
            endpoint: Self.redactURL(request?.url),
            operation: DiagnosticRedaction.redact(operation),
            statusCode: statusCode,
            responseBytes: responseBytes,
            responsePayloadJSON: Self.redactJSON(responseData),
            durationMilliseconds: max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000)),
            errorType: error.map { Self.describeError($0) }
        )
        entries.append(entry)
        trimIfNeeded()
        persistSoon()
    }

    /// Complete redacted records (metadata plus sanitized payload) for the troubleshooting
    /// bundle. Payloads were redacted at record time; nothing here is raw network data.
    func snapshot() -> [APILogEntry] {
        ensureLoaded()
        return entries
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        if persistsToDisk { flushToDisk() }
    }

    /// Public wrapper for the termination path: the app shell bridges this onto a
    /// semaphore in `applicationWillTerminate` so debounced-but-unsaved records are
    /// not lost on quit.
    func flushPendingWrites() {
        guard persistsToDisk else { return }
        flushToDisk()
    }

    // MARK: - Retention

    private func trimIfNeeded() {
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        if let firstKeptIndex = entries.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstKeptIndex > 0 { entries.removeFirst(firstKeptIndex) }
        } else if entries.first.map({ $0.timestamp < cutoff }) == true {
            entries.removeAll(keepingCapacity: true)
            return
        }
        enforcePayloadBudget()
    }

    /// Newest payloads keep their bodies; older rows past the cumulative budget keep
    /// only metadata. Idempotent, so it can run on every trim.
    private func enforcePayloadBudget() {
        var budget = totalPayloadBudgetOverride ?? Self.maximumTotalPayloadBytes
        for index in stride(from: entries.count - 1, through: 0, by: -1) {
            guard let payload = entries[index].responsePayloadJSON else { continue }
            let cost = payload.utf8.count
            if cost <= budget {
                budget -= cost
            } else if !entries[index].payloadOmitted {
                entries[index] = entries[index].omittingPayload()
            }
        }
    }

    // MARK: - Disk persistence (shared instance only)

    private static var archiveURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Hisingen", isDirectory: true)
            .appendingPathComponent("api-diagnostics.json")
    }

    private func ensureLoaded() {
        guard persistsToDisk, !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let url = Self.archiveURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([APILogEntry].self, from: data) else { return }
        entries = stored
        trimIfNeeded()
    }

    /// Coalesces bursts of records into one write; actor reentrancy makes the delayed
    /// flush safe without locking.
    private func persistSoon() {
        guard persistsToDisk, !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounce)
            await self?.flushToDisk()
        }
    }

    private func flushToDisk() {
        saveScheduled = false
        guard persistsToDisk, let url = Self.archiveURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Sanitization

    private static func describeError(_ error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        var text = typeName
        // `String(describing:)` carries enum payloads (`server(statusCode: 503)`) and
        // NSError domains/codes that the bare type name loses.
        let detail = String(describing: error)
        if !detail.isEmpty, detail != typeName {
            text += ": \(detail)"
        }
        if text.count > 300 {
            text = String(text.prefix(300)) + "…"
        }
        return DiagnosticRedaction.redact(text)
    }

    private static func redactURL(_ url: URL?) -> String {
        guard let url else { return "<unavailable>" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return DiagnosticRedaction.redact(components?.string ?? "<unavailable>")
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
            return DiagnosticRedaction.redact(string)
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
