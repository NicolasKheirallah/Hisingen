import Foundation

enum APILogProvider: String, Codable, CaseIterable, Sendable {
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
    /// Why a response body is absent. This separates privacy suppression from binary data,
    /// oversized bodies, and retention-budget eviction in support exports.
    let payloadOmissionReason: String?
    let durationMilliseconds: Int
    let errorType: String?
    /// Provider-level failure found inside an HTTP-success response (GraphQL errors,
    /// gRPC status trailers represented as JSON, or property-level API failures).
    let semanticErrorType: String?
    /// Provenance belongs to each row because the ring buffer survives relaunches.
    let appVersion: String?
    let appBuild: String?
    let processIdentifier: Int32?
    let launchIdentifier: String?

    init(timestamp: Date, provider: APILogProvider, method: String, endpoint: String,
         operation: String, statusCode: Int?, responseBytes: Int?,
         responsePayloadJSON: String?, payloadOmissionReason: String? = nil,
         durationMilliseconds: Int, errorType: String?, semanticErrorType: String? = nil,
         appVersion: String? = nil, appBuild: String? = nil,
         processIdentifier: Int32? = nil, launchIdentifier: String? = nil) {
        self.timestamp = timestamp
        self.provider = provider
        self.method = method
        self.endpoint = endpoint
        self.operation = operation
        self.statusCode = statusCode
        self.responseBytes = responseBytes
        self.responsePayloadJSON = responsePayloadJSON
        self.payloadOmissionReason = payloadOmissionReason
        self.durationMilliseconds = durationMilliseconds
        self.errorType = errorType
        self.semanticErrorType = semanticErrorType
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.processIdentifier = processIdentifier
        self.launchIdentifier = launchIdentifier
    }

    var payloadOmitted: Bool { responsePayloadJSON == nil && responseBytes != nil }

    /// Same record without the payload body (used when the cumulative payload budget
    /// is exhausted). Distinguished in exports by `payloadOmitted`.
    func omittingPayload() -> APILogEntry {
        APILogEntry(
            timestamp: timestamp, provider: provider, method: method, endpoint: endpoint,
            operation: operation, statusCode: statusCode, responseBytes: responseBytes,
            responsePayloadJSON: nil, payloadOmissionReason: "retentionBudget",
            durationMilliseconds: durationMilliseconds, errorType: errorType,
            semanticErrorType: semanticErrorType, appVersion: appVersion, appBuild: appBuild,
            processIdentifier: processIdentifier, launchIdentifier: launchIdentifier)
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
    private static let launchIdentifier = UUID().uuidString
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private static let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

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
        // A cancelled request (`URLError.cancelled`, NSURLErrorDomain -999) is normal teardown
        // — a superseded sign-in, a brand switch, app quit. Recording it as an error just adds
        // noise a support bundle then has to explain away. The providers wrap it in their own
        // `.network(URLError)` case, so check the whole error text, not just a top-level cast.
        if let error, Self.isCancellation(error) { return }
        ensureLoaded()
        let completedAt = Date()
        let sensitiveResponse = Self.isSensitiveResponse(request: request, operation: operation)
        let redactedPayload = sensitiveResponse ? nil : Self.redactJSON(responseData)
        let omissionReason = Self.payloadOmissionReason(
            data: responseData, redactedPayload: redactedPayload, sensitive: sensitiveResponse)
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
            responsePayloadJSON: redactedPayload,
            payloadOmissionReason: omissionReason,
            durationMilliseconds: max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000)),
            errorType: error.map { Self.describeError($0) },
            semanticErrorType: sensitiveResponse ? nil : Self.semanticError(in: responseData),
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            launchIdentifier: Self.launchIdentifier
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

    /// True when `error` is (or wraps) a `URLError.cancelled` / NSURLErrorDomain -999.
    private static func isCancellation(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isCancellation(underlying) }
        // Providers wrap the URLError in their own `.network(_)` enum case; the payload's
        // description still carries the -999 code.
        return String(describing: error).contains("Code=-999")
    }

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

    private static func isSensitiveResponse(request: URLRequest?, operation: String) -> Bool {
        let haystack = [operation, request?.url?.lastPathComponent ?? ""]
            .joined(separator: " ").lowercased()
        return haystack.contains("token") || haystack.contains("oauth2")
    }

    private static func payloadOmissionReason(data: Data?, redactedPayload: String?,
                                              sensitive: Bool) -> String? {
        if sensitive, data?.isEmpty == false { return "sensitive" }
        guard let data else { return nil }
        if data.isEmpty { return "empty" }
        if data.count > 2_000_000 { return "tooLarge" }
        if redactedPayload == nil { return "nonJSON" }
        return nil
    }

    /// Classifies provider errors that are encoded inside an HTTP 2xx JSON body. Keep the
    /// value intentionally coarse and credential-free so the inspector can filter it safely.
    private static func semanticError(in data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dictionary = object as? [String: Any],
           let errors = dictionary["errors"] as? [Any], !errors.isEmpty {
            let code = (errors.first as? [String: Any])?["extensions"] as? [String: Any]
            let value = (code?["code"] ?? code?["errorType"]) as? String
            return value.map { "graphql:\($0)" } ?? "graphql:error"
        }
        if containsSemanticValue("AUTHENTICATIONFAILURE", in: object) {
            return "authentication:failure"
        }
        if containsSemanticValue("PROPERTY_NOT_FOUND", in: object) {
            return "property:unavailable"
        }
        return nil
    }

    private static func containsSemanticValue(_ expected: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.uppercased() == expected
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsSemanticValue(expected, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsSemanticValue(expected, in: $0) }
        }
        return false
    }

    private static func redactURL(_ url: URL?) -> String {
        guard let url else { return "<unavailable>" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if let path = components?.percentEncodedPath {
            components?.percentEncodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
                .map { segment in
                    let value = String(segment)
                    // OAuth resume/state identifiers are typically long URL-safe random
                    // strings. Endpoint names remain visible; transaction identifiers do not.
                    // Preserve recognizable API service/method names, but redact every other
                    // long opaque segment. Requiring a digit was insufficient: an OAuth state
                    // can be letters-only and must never survive an export.
                    let staticService = value.range(
                        of: "^[A-Z][A-Za-z]+(Service|Controller|Resource)$",
                        options: .regularExpression) != nil
                    let staticMethod = value.range(
                        of: "^(Get|Set|List|Create|Update|Delete|Fetch|Invoke|Start|Stop)[A-Z][A-Za-z]+$",
                        options: .regularExpression) != nil
                    let qualifiedService = value.contains(".")
                        && value.range(of: "^[A-Za-z][A-Za-z.]+$", options: .regularExpression) != nil
                    if value.count >= 20, !staticService, !staticMethod, !qualifiedService,
                       value.range(of: "^[A-Za-z0-9._~-]+$", options: .regularExpression) != nil {
                        return "redacted"
                    }
                    return value
                }
                .joined(separator: "/")
        }
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
                || normalizedKey.hasSuffix("_token")
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
        "client_id", "client_secret", "id_token",
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
