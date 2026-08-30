import Foundation
import OSLog

/// Scrubbing rules shared by everything that leaves the process for support purposes.
/// Applied defensively even to unified-log text, which is already privacy-annotated at
/// the call site — belt and braces beats trusting every future log statement.
enum DiagnosticRedaction {
    /// Replaces VIN-shaped tokens, UUID-shaped identifiers, and credential-bearing
    /// substrings (`token=…`, `Bearer …`) with placeholders.
    ///
    /// The VIN heuristic additionally requires ≥ 2 digits in the 17-character run:
    /// a plain 17-letter run ("batteryPercentage") is an ordinary identifier-shaped
    /// word, not a VIN, and over-redacting it corrupts the evidence we export for.
    static func redact(_ value: String) -> String {
        var result = redactVINShapedTokens(value)
        result = redactSecrets(result)
        return result
    }

    private static let vinPattern = "(?i)[A-HJ-NPR-Z0-9]{17}"

    private static func redactVINShapedTokens(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: vinPattern) else { return value }
        let nsValue = value as NSString
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return value }

        var result = ""
        var cursor = fullRange.location
        for match in matches where match.range.location >= cursor {
            result += nsValue.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = nsValue.substring(with: match.range)
            result += token.filter(\.isNumber).count >= 2 ? "<vehicle>" : token
            cursor = match.range.location + match.range.length
        }
        result += nsValue.substring(from: cursor)
        return result
    }

    /// Secret and identifier scrubbing without the VIN shape-heuristic. Used for
    /// recorded API payloads, which are already structurally sanitized at record
    /// time — running the 17-character VIN regex over them again would corrupt
    /// legitimate 17-letter words ("batteryPercentage") inside the JSON.
    static func redactSecrets(_ value: String) -> String {
        var result = value
        result = replacingMatches(in: result, pattern: "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", replacement: "<identifier>")
        result = replacingMatches(in: result, pattern: "(?i)(bearer|token|authorization|client_secret|password|api[_-]?key)[=:][^,; ]+", replacement: "$1=<redacted>")
        return result
    }

    static func replacingMatches(in value: String, pattern: String, replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

/// Builds the single-file diagnostic bundle users attach to bug reports: app/system
/// metadata, recent unified-log entries from this process only, and the redacted API
/// request history. Everything passes through `DiagnosticRedaction` before leaving.
///
/// Runs off the main thread at the call site; `OSLogStore` and JSON assembly are not
/// main-thread work.
enum DiagnosticLogExporter {
    static let subsystem = AppLog.subsystem

    /// How far back the unified log reaches, and the hard ceiling on rows either way.
    static let logLookback: TimeInterval = 24 * 3_600
    static let maximumLogEntries = 4_000

    /// Worst-case payload ceiling for one export bundle (the store enforces its own
    /// cumulative budget at retention time; this is the second line of defense). Rows
    /// past the budget keep their metadata and lose only their payload body, newest first.
    static let apiPayloadBudgetBytes = 8 * 1024 * 1024

    struct UnifiedLogEntry: Sendable {
        let date: Date
        let level: String
        let category: String
        let message: String
    }

    /// Reads this process's own unified-log entries for `subsystem`, oldest first,
    /// trimmed to the newest `maxEntries`. Never sweeps other processes' logs.
    static func collectUnifiedLogEntries(subsystem: String = DiagnosticLogExporter.subsystem,
                                         lookback: TimeInterval = logLookback,
                                         maxEntries: Int = maximumLogEntries) -> [UnifiedLogEntry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let cutoff = Date().addingTimeInterval(-lookback)
        guard let enumerator = try? store.getEntries(
            at: store.position(date: cutoff),
            matching: NSPredicate(format: "subsystem == %@", subsystem)) else { return [] }

        var collected: [UnifiedLogEntry] = []
        for object in enumerator {
            guard let entry = object as? OSLogEntryLog else { continue }
            collected.append(UnifiedLogEntry(
                date: entry.date,
                level: levelName(entry.level),
                category: entry.category.isEmpty ? "-" : entry.category,
                message: DiagnosticRedaction.redact(entry.composedMessage)))
        }
        if collected.count > maxEntries {
            collected.removeFirst(collected.count - maxEntries)
        }
        return collected
    }

    static func collectMeta(now: Date = Date()) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "appVersion": info?["CFBundleShortVersionString"] ?? "development",
            "appBuild": info?["CFBundleVersion"] ?? "-",
            "platform": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "hardwareModel": hardwareModel(),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "redactionNote": "Vehicle identification numbers, UUID-shaped identifiers, and credential-bearing substrings are replaced with placeholders before export.",
        ]
    }

    /// Pure assembly, separated from collection so tests can pin the output format and
    /// redaction guarantees without touching `OSLogStore`.
    ///
    /// `schemaVersion` lets support tooling evolve the format; bump it whenever a
    /// section's shape changes.
    static func makeReport(meta: [String: Any],
                           unifiedLog: [UnifiedLogEntry],
                           apiEntries: [APILogEntry],
                           apiPayloadBudgetBytes: Int = DiagnosticLogExporter.apiPayloadBudgetBytes,
                           refreshDiagnostics: DiagnosticsSnapshot? = nil,
                           commandAudits: [[String: Any]] = [],
                           databaseStats: [String: Any]? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()

        var apiRows: [[String: Any]] = []
        var payloadBudget = apiPayloadBudgetBytes
        var payloadsTruncated = false
        // Entries are redacted at record time, but scrubbing again here makes the
        // guarantee hold regardless of how an entry was constructed.
        for entry in apiEntries.reversed() {
            var row: [String: Any] = [
                "timestamp": formatter.string(from: entry.timestamp),
                "provider": entry.provider.rawValue,
                "method": entry.method,
                "endpoint": DiagnosticRedaction.redact(entry.endpoint),
                "operation": DiagnosticRedaction.redact(entry.operation),
                "durationMilliseconds": entry.durationMilliseconds,
            ]
            if let statusCode = entry.statusCode { row["statusCode"] = statusCode }
            if let responseBytes = entry.responseBytes { row["responseBytes"] = responseBytes }
            if let errorType = entry.errorType { row["errorType"] = DiagnosticRedaction.redact(errorType) }
            if let payload = entry.responsePayloadJSON {
                let cost = payload.utf8.count
                if cost <= payloadBudget {
                    row["payload"] = DiagnosticRedaction.redactSecrets(payload)
                    payloadBudget -= cost
                } else {
                    payloadsTruncated = true
                    row["payloadOmitted"] = true
                }
            } else if entry.responseBytes != nil {
                // The store dropped the body (budget enforcement at retention time, or a
                // non-JSON response such as a protobuf frame).
                row["payloadOmitted"] = true
            }
            apiRows.insert(row, at: 0)
        }

        var report: [String: Any] = [
            "schemaVersion": 1,
            "meta": meta,
            "unifiedLog": unifiedLog.map { entry in
                [
                    "timestamp": formatter.string(from: entry.date),
                    "level": entry.level,
                    "category": entry.category,
                    "message": DiagnosticRedaction.redact(entry.message),
                ] as [String: Any]
            },
            "apiRequests": apiRows,
        ]
        if payloadsTruncated {
            report["apiPayloadsTruncated"] = true
        }
        if let refreshDiagnostics {
            report["refreshDiagnostics"] = Self.diagnosticsSection(refreshDiagnostics, formatter: formatter)
        }
        if !commandAudits.isEmpty {
            report["commandAudit"] = commandAudits
        }
        if let databaseStats {
            report["databaseStats"] = databaseStats
        }
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }

    private static func diagnosticsSection(_ snapshot: DiagnosticsSnapshot,
                                           formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "lastSuccess": snapshot.lastSuccess.map(formatter.string(from:)) as Any? ?? NSNull(),
            "lastError": (snapshot.lastError.map { DiagnosticRedaction.redact($0) }) as Any? ?? NSNull(),
            "latencySeconds": snapshot.latency as Any? ?? NSNull(),
            "nextRefresh": snapshot.nextRefresh.map(formatter.string(from:)) as Any? ?? NSNull(),
            "sessionValid": snapshot.sessionValid,
            "networkAvailable": snapshot.networkAvailable,
            "refreshInProgress": snapshot.refreshInProgress,
            "liveStreamConnected": snapshot.liveStreamConnected,
            "refreshAttempts": snapshot.refreshAttempts,
            "refreshSuccesses": snapshot.refreshSuccesses,
            "refreshFailures": snapshot.refreshFailures,
            "vehicleSwitchPending": snapshot.vehicleSwitchPending,
        ]
    }

    /// Convenience path used by the Settings export button.
    static func buildReport(now: Date = Date(), database: VehicleDatabase? = nil) async throws -> Data {
        async let apiEntriesTask = APIDiagnosticLogStore.shared.snapshot()
        async let diagnosticsTask = LatestDiagnosticsStore.shared.current()
        let apiEntries = await apiEntriesTask
        let refreshDiagnostics = await diagnosticsTask

        var commandAudits: [[String: Any]] = []
        var databaseStats: [String: Any]?
        if let database {
            let formatter = ISO8601DateFormatter()
            // Newest first; VINs and free-text errors pass the redactor on the way out.
            commandAudits = database.recentCommandAudits(for: nil, limit: 25).map { audit in
                [
                    "timestamp": formatter.string(from: audit.executedAt),
                    "command": audit.command,
                    "status": audit.status,
                    "durationMilliseconds": audit.durationMs as Any? ?? NSNull(),
                    "error": audit.errorMessage.map { DiagnosticRedaction.redact($0) } as Any? ?? NSNull(),
                ] as [String: Any]
            }
            let counts = database.recordCounts()
            databaseStats = [
                "sizeBytes": database.databaseSizeBytes,
                "vehicleSnapshots": counts.snapshots,
                "chargingSessions": counts.chargingSessions,
                "chargingSamples": counts.chargingSamples,
                "batteryHealth": counts.batteryHealth,
                "telemetry": counts.telemetry,
                "remoteCommands": counts.commands,
            ]
        }

        return try makeReport(meta: collectMeta(now: now),
                              unifiedLog: collectUnifiedLogEntries(),
                              apiEntries: apiEntries,
                              refreshDiagnostics: refreshDiagnostics,
                              commandAudits: commandAudits,
                              databaseStats: databaseStats)
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "undefined"
        @unknown default: "other"
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var model = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let bytes = model[..<(model.firstIndex(of: 0) ?? model.endIndex)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
