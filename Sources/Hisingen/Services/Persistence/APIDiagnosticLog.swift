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
    let logicalOperationID: String?
    let attempt: Int?
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
    /// gRPC status and server message as their own fields. Keeping them out of `operation`
    /// leaves that field a stable grouping key instead of a per-failure label, and lets
    /// `semanticErrorType` be derived from structure rather than parsed back out of text.
    let grpcStatus: String?
    let grpcMessage: String?
    /// True when the exchange failed before any HTTP response arrived (DNS, TLS, timeout,
    /// connection loss, cancellation-adjacent teardown). Separates "the server returned no
    /// status" from "the status was not recorded".
    let transportError: Bool?
    /// Which log partition the exchange belongs to: `account`, or `vehicle-` plus a digest of
    /// the VIN (never the VIN itself; see `VehicleLogScope.logPartition`). Optional so rows
    /// persisted before the field existed keep decoding.
    let scopePartition: String?
    /// Provenance belongs to each row because the ring buffer survives relaunches.
    let appVersion: String?
    let appBuild: String?
    let processIdentifier: Int32?
    let launchIdentifier: String?

    init(timestamp: Date, provider: APILogProvider, method: String, endpoint: String,
         operation: String, statusCode: Int?, responseBytes: Int?,
         responsePayloadJSON: String?, payloadOmissionReason: String? = nil,
         durationMilliseconds: Int, errorType: String?, semanticErrorType: String? = nil,
         grpcStatus: String? = nil, grpcMessage: String? = nil, transportError: Bool? = nil,
         appVersion: String? = nil, appBuild: String? = nil,
         processIdentifier: Int32? = nil, launchIdentifier: String? = nil,
         logicalOperationID: String? = nil, attempt: Int? = nil,
         scopePartition: String? = nil) {
        self.timestamp = timestamp
        self.provider = provider
        self.method = method
        self.endpoint = endpoint
        self.operation = operation
        self.logicalOperationID = logicalOperationID
        self.attempt = attempt
        self.statusCode = statusCode
        self.responseBytes = responseBytes
        self.responsePayloadJSON = responsePayloadJSON
        self.payloadOmissionReason = payloadOmissionReason
        self.durationMilliseconds = durationMilliseconds
        self.errorType = errorType
        self.semanticErrorType = semanticErrorType
        self.grpcStatus = grpcStatus
        self.grpcMessage = grpcMessage
        self.transportError = transportError
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.processIdentifier = processIdentifier
        self.launchIdentifier = launchIdentifier
        self.scopePartition = scopePartition
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
            semanticErrorType: semanticErrorType, grpcStatus: grpcStatus,
            grpcMessage: grpcMessage, transportError: transportError,
            appVersion: appVersion, appBuild: appBuild,
            processIdentifier: processIdentifier, launchIdentifier: launchIdentifier,
            logicalOperationID: logicalOperationID, attempt: attempt,
            scopePartition: scopePartition)
    }
}

/// Redacted request metadata intended for user-initiated support exports. Payloads, headers,
/// credentials, and vehicle/account identifiers are never retained raw.
///
/// Entries are partitioned by `APILogPartitionKey`: one log per vehicle, one for account-level
/// traffic, and one for rows written before the partition existed. Every partition keeps its
/// own ring, age window and payload budget, so a busy car cannot evict another car's evidence;
/// the store also enforces fleet-wide ceilings so the archive stays bounded.
///
/// The `shared` instance persists its redacted entries to Application Support (debounced) so a
/// crash or relaunch no longer wipes the evidence. Direct initializations (tests) stay
/// memory-only to remain hermetic.
actor APIDiagnosticLogStore {
    static let shared = APIDiagnosticLogStore(persistsToDisk: true)

    /// Ceilings for the archive. The per-partition row count is the same figure the single-log
    /// format used, because that figure was already sized for one fully enabled vehicle.
    struct Limits: Sendable {
        var maximumEntriesPerPartition = 10_000
        var maximumEntriesTotal = 30_000
        var maximumPayloadBytesPerPartition = 8 * 1024 * 1024
        var maximumPayloadBytesTotal = 32 * 1024 * 1024
        var maximumPartitions = 16
        var retentionInterval: TimeInterval = 24 * 3_600

        static let `default` = Limits()
    }

    /// Matches the diagnostic bundle's unified-log lookback window.
    static let retentionInterval: TimeInterval = Limits.default.retentionInterval
    /// Kept for callers and tests that reason about one vehicle's ceiling.
    static let maximumEntries = Limits.default.maximumEntriesPerPartition

    private static let persistDebounce: Duration = .seconds(3)
    private static let launchIdentifier = UUID().uuidString
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private static let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    private let persistsToDisk: Bool
    private let limits: Limits
    /// Tests point this at a temporary file so archive migration and round-trips are hermetic.
    private let archiveURLOverride: URL?
    private var entriesByPartition: [APILogPartitionKey: [APILogEntry]] = [:]
    /// Running payload byte counts, kept alongside the entries so a record does not rescan
    /// every retained body. A partition budget only re-derives the exact figure when it drains.
    private var payloadBytesByPartition: [APILogPartitionKey: Int] = [:]
    private var totalPayloadBytes = 0
    private var loadedFromDisk = false
    private var saveScheduled = false

    /// `totalPayloadBudget` predates the per-partition limits; it now caps the whole archive.
    init(persistsToDisk: Bool = false, totalPayloadBudget: Int? = nil,
         limits: Limits = .default, archiveURL: URL? = nil) {
        self.persistsToDisk = persistsToDisk
        self.archiveURLOverride = archiveURL
        var resolvedLimits = limits
        if let totalPayloadBudget {
            resolvedLimits.maximumPayloadBytesTotal = totalPayloadBudget
            resolvedLimits.maximumPayloadBytesPerPartition = min(
                resolvedLimits.maximumPayloadBytesPerPartition, totalPayloadBudget)
        }
        self.limits = resolvedLimits
    }

    // MARK: - Recording

    func record(provider: APILogProvider, request: URLRequest?, operation: String,
                scope: VehicleLogScope = .account,
                grpcStatus: String? = nil, grpcMessage: String? = nil,
                statusCode: Int? = nil, responseBytes: Int? = nil, responseData: Data? = nil,
                startedAt: Date, error: Error? = nil, timestamp overrideTimestamp: Date? = nil,
                semanticErrorType: String? = nil, logicalOperationID: String? = nil, attempt: Int? = nil) {
        // A cancelled request (`URLError.cancelled`, NSURLErrorDomain -999) is normal teardown
        // – a superseded sign-in, a brand switch, app quit. Recording it as an error just adds
        // noise a support bundle then has to explain away. The providers wrap it in their own
        // `.network(URLError)` case, so check the whole error text, not just a top-level cast.
        if let error, Self.isCancellation(error) { return }
        ensureLoaded()
        let completedAt = Date()
        let sensitiveResponse = Self.isSensitiveResponse(request: request, operation: operation)
        let redactedPayload = sensitiveResponse ? nil : Self.redactJSON(responseData)
        let omissionReason = Self.payloadOmissionReason(
            data: responseData, redactedPayload: redactedPayload, sensitive: sensitiveResponse)
        let normalizedGRPCStatus = grpcStatus.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedGRPCMessage = grpcMessage
            .flatMap { $0.isEmpty ? nil : ($0.removingPercentEncoding ?? $0) }
            .map { String(DiagnosticRedaction.redact(String($0.prefix(160)))) }
        // Callers may classify a failure that lives in a body the store must not retain (an
        // OAuth `error` code, say). That explicit value wins over the sensitive-body gate,
        // because it is a classification rather than the body itself.
        let derivedSemanticError = sensitiveResponse ? nil : (
            Self.semanticError(in: responseData) ?? Self.grpcSemanticError(status: normalizedGRPCStatus, in: operation)
        )
        let entry = APILogEntry(
            // Request start, not completion – keeps exports correlatable with the
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
            semanticErrorType: semanticErrorType ?? derivedSemanticError,
            grpcStatus: normalizedGRPCStatus,
            grpcMessage: normalizedGRPCMessage,
            transportError: (error != nil && statusCode == nil && normalizedGRPCStatus == nil) ? true : nil,
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            launchIdentifier: Self.launchIdentifier,
            logicalOperationID: logicalOperationID,
            attempt: attempt,
            scopePartition: scope.logPartition
        )
        append(entry, to: scope.partitionKey)
        trim(scope.partitionKey)
        enforcePartitionLimit()
        enforceTotalEntryLimit()
        enforceTotalPayloadBudget()
        persistSoon()
    }

    // MARK: - Reading

    /// Every retained entry across partitions, oldest first. Equal timestamps keep a stable
    /// partition-and-arrival order so a live view does not reshuffle rows between polls.
    func snapshot() -> [APILogEntry] {
        ensureLoaded()
        let merged = entriesByPartition.keys.sorted { $0.rawValue < $1.rawValue }
            .flatMap { entriesByPartition[$0] ?? [] }
        return merged.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp { return lhs.offset < rhs.offset }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
    }

    /// One partition, oldest first. Empty when nothing was recorded for it.
    func snapshot(for key: APILogPartitionKey) -> [APILogEntry] {
        ensureLoaded()
        return entriesByPartition[key] ?? []
    }

    /// Non-empty partitions ordered by key. The store keeps this order deterministic; the
    /// inspector re-orders by the reader's garage order.
    func partitions() -> [APILogPartition] {
        ensureLoaded()
        return entriesByPartition
            .map { APILogPartition(key: $0.key, entries: $0.value) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    /// Whether anything at all is retained, for the inspector's empty state.
    func isEmpty() -> Bool {
        ensureLoaded()
        return entriesByPartition.isEmpty
    }

    // MARK: - Clearing

    func clearAll() {
        entriesByPartition.removeAll(keepingCapacity: true)
        payloadBytesByPartition.removeAll(keepingCapacity: true)
        totalPayloadBytes = 0
        if persistsToDisk { flushToDisk() }
    }

    /// Discards one partition. The fleet-wide form is `clearAll()` so it is never the meaning
    /// of an omitted argument.
    func clear(_ key: APILogPartitionKey) {
        clear(keys: [key])
    }

    func clear(scope: VehicleLogScope) {
        clear(scope.partitionKey)
    }

    /// Public wrapper for the termination path: the app shell bridges this onto a
    /// semaphore in `applicationWillTerminate` so debounced-but-unsaved records are
    /// not lost on quit.
    func flushPendingWrites() {
        guard persistsToDisk else { return }
        flushToDisk()
    }

    /// Synchronous erase for the sign-out and "erase local data" paths. They own a synchronous
    /// SQLite transaction and must not return while this vehicle's rows could still be written
    /// back afterwards. The wait is bounded so an unforeseen stall cannot hang sign-out; a
    /// timeout is recorded rather than silently skipping the erase.
    nonisolated func eraseVehicleLogsSynchronously(vin: String) {
        applyEraseSynchronously(keys: [.vehicle(vin)])
    }

    /// Fleet-wide counterpart of `eraseVehicleLogsSynchronously(vin:)`. Its own member so
    /// "every vehicle" is never what an omitted argument means.
    nonisolated func eraseAllLogsSynchronously() {
        applyEraseSynchronously(keys: nil)
    }

    private nonisolated func applyEraseSynchronously(keys: [APILogPartitionKey]?) {
        let erased = DispatchSemaphore(value: 0)
        // Detached on purpose: a child task would inherit the caller's main-actor isolation,
        // and the caller waits on this semaphore from that same actor.
        Task.detached(priority: .utility) { [self] in
            if let keys {
                await self.clear(keys: keys)
            } else {
                await self.clearAll()
            }
            erased.signal()
        }
        if erased.wait(timeout: .now() + 5) == .timedOut {
            AppLog.logger("api-diagnostics").fault(
                "Diagnostic log erase did not finish within its bounded wait")
        }
    }

    private func clear(keys: [APILogPartitionKey]) {
        var changed = false
        for key in keys {
            guard let entries = entriesByPartition.removeValue(forKey: key) else { continue }
            let payload = entries.reduce(0) { $0 + Self.payloadCost($1) }
            totalPayloadBytes = max(0, totalPayloadBytes - payload)
            payloadBytesByPartition[key] = nil
            changed = true
        }
        if changed, persistsToDisk { flushToDisk() }
    }

    // MARK: - Retention

    private static func payloadCost(_ entry: APILogEntry) -> Int {
        entry.responsePayloadJSON?.utf8.count ?? 0
    }

    private func append(_ entry: APILogEntry, to key: APILogPartitionKey) {
        entriesByPartition[key, default: []].append(entry)
        let cost = Self.payloadCost(entry)
        guard cost > 0 else { return }
        payloadBytesByPartition[key, default: 0] += cost
        totalPayloadBytes += cost
    }

    /// Count, age and per-vehicle payload bounds. One partition at a time, so another vehicle's
    /// evidence is never a casualty of this one's volume.
    private func trim(_ key: APILogPartitionKey) {
        guard var entries = entriesByPartition[key], !entries.isEmpty else {
            removePartition(key)
            return
        }
        var removedPayload = 0
        func dropFirst(_ count: Int) {
            guard count > 0 else { return }
            for entry in entries.prefix(count) {
                removedPayload += Self.payloadCost(entry)
            }
            entries.removeFirst(count)
        }

        let cutoff = Date().addingTimeInterval(-limits.retentionInterval)
        if let firstKeptIndex = entries.firstIndex(where: { $0.timestamp >= cutoff }) {
            dropFirst(firstKeptIndex)
        } else if entries.first.map({ $0.timestamp < cutoff }) == true {
            dropFirst(entries.count)
        }
        if entries.count > limits.maximumEntriesPerPartition {
            dropFirst(entries.count - limits.maximumEntriesPerPartition)
        }

        let payloadAfterDrops = max(0, (payloadBytesByPartition[key] ?? 0) - removedPayload)
        let enforced = enforcePayloadBudget(entries: entries,
                                            budget: limits.maximumPayloadBytesPerPartition,
                                            knownBytes: payloadAfterDrops)
        entries = enforced.entries
        totalPayloadBytes = max(0, totalPayloadBytes - removedPayload - enforced.droppedBytes)

        if entries.isEmpty {
            removePartition(key)
        } else {
            entriesByPartition[key] = entries
            payloadBytesByPartition[key] = enforced.remainingBytes
        }
    }

    /// Drops the oldest bodies once a partition is over budget. Skipped while under budget,
    /// which is the common case and the reason recording stays cheap.
    private func enforcePayloadBudget(entries: [APILogEntry], budget: Int,
                                      knownBytes: Int) -> (entries: [APILogEntry], droppedBytes: Int, remainingBytes: Int) {
        guard knownBytes > budget else { return (entries, 0, knownBytes) }
        var entries = entries
        var dropped = 0
        var remaining = 0
        for index in stride(from: entries.count - 1, through: 0, by: -1) {
            guard let payload = entries[index].responsePayloadJSON else { continue }
            let cost = payload.utf8.count
            if remaining + cost <= budget {
                remaining += cost
            } else if !entries[index].payloadOmitted {
                entries[index] = entries[index].omittingPayload()
                dropped += cost
            }
        }
        return (entries, dropped, remaining)
    }

    private func removePartition(_ key: APILogPartitionKey) {
        entriesByPartition[key] = nil
        payloadBytesByPartition[key] = nil
    }

    /// Caps the archive's row count across every partition, oldest first.
    private func enforceTotalEntryLimit() {
        let total = entriesByPartition.values.reduce(0) { $0 + $1.count }
        let excess = total - limits.maximumEntriesTotal
        guard excess > 0 else { return }
        var candidates: [(timestamp: Date, key: APILogPartitionKey, index: Int)] = []
        candidates.reserveCapacity(total)
        for (key, entries) in entriesByPartition {
            for (index, entry) in entries.enumerated() {
                candidates.append((entry.timestamp, key, index))
            }
        }
        candidates.sort { $0.timestamp < $1.timestamp }
        var removals: [APILogPartitionKey: Set<Int>] = [:]
        for candidate in candidates.prefix(excess) {
            removals[candidate.key, default: []].insert(candidate.index)
        }
        for (key, indexes) in removals {
            guard let entries = entriesByPartition[key] else { continue }
            var removedPayload = 0
            var kept: [APILogEntry] = []
            kept.reserveCapacity(entries.count - indexes.count)
            for (index, entry) in entries.enumerated() {
                if indexes.contains(index) { removedPayload += Self.payloadCost(entry) }
                else { kept.append(entry) }
            }
            totalPayloadBytes = max(0, totalPayloadBytes - removedPayload)
            payloadBytesByPartition[key] = max(0, (payloadBytesByPartition[key] ?? 0) - removedPayload)
            if kept.isEmpty { removePartition(key) } else { entriesByPartition[key] = kept }
        }
    }

    private func enforcePartitionLimit() {
        let vehicleKeys = entriesByPartition.keys.filter { !$0.isAccount }
        let accountCount = entriesByPartition[.account] == nil ? 0 : 1
        guard vehicleKeys.count + accountCount > limits.maximumPartitions else { return }
        let byLeastRecent = vehicleKeys.sorted { lhs, rhs in
            let left = entriesByPartition[lhs]?.last?.timestamp ?? .distantPast
            let right = entriesByPartition[rhs]?.last?.timestamp ?? .distantPast
            return left == right ? lhs.rawValue < rhs.rawValue : left < right
        }
        var excess = vehicleKeys.count + accountCount - limits.maximumPartitions
        for key in byLeastRecent where excess > 0 {
            removePartition(key)
            excess -= 1
        }
    }

    /// Caps payload bytes across every partition, newest bodies first, so one busy vehicle
    /// cannot grow the archive past the ceiling on its own.
    private func enforceTotalPayloadBudget() {
        guard totalPayloadBytes > limits.maximumPayloadBytesTotal else { return }
        var ordered: [(timestamp: Date, key: APILogPartitionKey, index: Int)] = []
        for (key, entries) in entriesByPartition {
            for (index, entry) in entries.enumerated() where entry.responsePayloadJSON != nil {
                ordered.append((entry.timestamp, key, index))
            }
        }
        ordered.sort { $0.timestamp > $1.timestamp }
        var budget = limits.maximumPayloadBytesTotal
        for item in ordered {
            guard let current = entriesByPartition[item.key], item.index < current.count,
                  let payload = current[item.index].responsePayloadJSON else { continue }
            let cost = payload.utf8.count
            if cost <= budget {
                budget -= cost
                continue
            }
            guard !current[item.index].payloadOmitted else { continue }
            entriesByPartition[item.key]?[item.index] = current[item.index].omittingPayload()
            totalPayloadBytes = max(0, totalPayloadBytes - cost)
            payloadBytesByPartition[item.key] = max(0, (payloadBytesByPartition[item.key] ?? 0) - cost)
        }
    }

    // MARK: - Disk persistence (shared instance only)

    private struct StoredArchive: Codable {
        let version: Int
        let partitions: [String: [APILogEntry]]
    }

    private var archiveURL: URL? { archiveURLOverride ?? Self.defaultArchiveURL }

    private static var defaultArchiveURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Hisingen", isDirectory: true)
            .appendingPathComponent("api-diagnostics.json")
    }

    private func ensureLoaded() {
        guard persistsToDisk, !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let url = archiveURL,
              let data = try? Data(contentsOf: url) else { return }
        if let stored = try? JSONDecoder.iso.decode(StoredArchive.self, from: data),
           stored.version == 2 {
            for (rawKey, entries) in stored.partitions where !entries.isEmpty {
                entriesByPartition[APILogPartitionKey(rawValue: rawKey)] = entries
            }
        } else if let legacy = try? JSONDecoder.iso.decode([APILogEntry].self, from: data),
                  !legacy.isEmpty {
            // The previous format had no vehicle scope. Guessing one would put one car's
            // traffic in another car's log, so the rows keep their own partition until the
            // 24-hour window retires them.
            entriesByPartition[.legacy] = legacy
        } else {
            return
        }
        recomputePayloadTotals()
        for key in Array(entriesByPartition.keys) { trim(key) }
        enforcePartitionLimit()
        enforceTotalEntryLimit()
        enforceTotalPayloadBudget()
    }

    private func recomputePayloadTotals() {
        payloadBytesByPartition.removeAll(keepingCapacity: true)
        totalPayloadBytes = 0
        for (key, entries) in entriesByPartition {
            let bytes = entries.reduce(0) { $0 + Self.payloadCost($1) }
            if bytes > 0 { payloadBytesByPartition[key] = bytes }
            totalPayloadBytes += bytes
        }
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
        guard persistsToDisk, let url = archiveURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let archive = StoredArchive(
            version: 2,
            partitions: entriesByPartition.reduce(into: [:]) { result, item in
                result[item.key.rawValue] = item.value
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Sanitization

    private static func grpcSemanticError(status: String?, in operation: String) -> String? {
        if let status, !status.isEmpty, status != "0" { return "grpc:\(status)" }
        // Fallback for rows recorded before `grpcStatus` became its own field, and for the
        // live-stream path that still labels its operation with the status.
        guard let marker = operation.range(of: "grpc-status=") else { return nil }
        let suffix = operation[marker.upperBound...]
        let parsed = suffix.prefix { $0.isNumber }
        guard !parsed.isEmpty, parsed != "0" else { return nil }
        return "grpc:\(parsed)"
    }

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
        // A body that also carries readable values is a successful request with optional fields
        // this vehicle lacks, not a failed one. `/energy/v2/…/state` answers 200 with the battery
        // and range filled in and `chargingPower` in error, which used to stamp every poll as a
        // failure: 86 of them in one day, all of them healthy.
        guard containsAnyPropertyError(in: object), !containsUsableReading(in: object) else { return nil }
        return "property:unavailable"
    }

    /// The same concept ships under three spellings: the specification documents `NOT_SUPPORTED`,
    /// while live responses use `PROPERTY_NOT_FOUND` (energy state) and `PROPERTY_NOT_SUPPORTED`
    /// (transfer limit). Matching one of them made the label a coin flip.
    private static func containsAnyPropertyError(in value: Any) -> Bool {
        containsSemanticValue("PROPERTY_NOT_FOUND", in: value)
            || containsSemanticValue("PROPERTY_NOT_SUPPORTED", in: value)
            || containsSemanticValue("NOT_SUPPORTED", in: value)
    }

    /// A field that came back readable: status `OK` next to a value or a timestamp. The API marks
    /// errors with `status: ERROR` and a `code` in place of the value, so this is the exact
    /// complement of the error shape.
    private static func containsUsableReading(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let status = dictionary["status"] as? String,
               status.uppercased() == "OK",
               dictionary["value"] != nil || dictionary["updatedAt"] != nil
                   || dictionary["timestamp"] != nil {
                return true
            }
            return dictionary.values.contains { containsUsableReading(in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsUsableReading(in: $0) }
        }
        return false
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
