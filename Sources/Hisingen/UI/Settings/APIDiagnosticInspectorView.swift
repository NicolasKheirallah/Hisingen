import SwiftUI

enum APIDiagnosticOutcomeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case success
    case clientError
    case serverError
    case transportError
    case semanticError

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("All outcomes")
        case .success: return L10n.text("Success")
        case .clientError: return L10n.text("4xx")
        case .serverError: return L10n.text("5xx")
        case .transportError: return L10n.text("Network errors")
        case .semanticError: return L10n.text("API errors")
        }
    }
}

struct APIDiagnosticInspectorFilter: Equatable, Sendable {
    var provider: APILogProvider?
    var outcome: APIDiagnosticOutcomeFilter = .all
    var query = ""

    func apply(to entries: [APILogEntry]) -> [APILogEntry] {
        let needle = normalizedQuery
        return entries.filter { matches($0, needle: needle) }
    }

    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// `needle` is `normalizedQuery`, passed in so a caller testing many entries trims and
    /// lowercases the query once.
    func matches(_ entry: APILogEntry, needle: String) -> Bool {
        if let provider, entry.provider != provider { return false }
        switch outcome {
        case .all:
            break
        case .success:
            guard entry.statusCode.map({ (200...299).contains($0) }) == true else { return false }
        case .clientError:
            guard entry.statusCode.map({ (400...499).contains($0) }) == true else { return false }
        case .serverError:
            guard entry.statusCode.map({ (500...599).contains($0) }) == true else { return false }
        case .transportError:
            guard entry.errorType != nil else { return false }
        case .semanticError:
            guard entry.semanticErrorType != nil else { return false }
        }
        guard !needle.isEmpty else { return true }
        // Only the short fields are joined and lowercased. The payload can be 256 KB, so it is
        // searched in place instead of copied and lowercased for every entry on every keystroke.
        let head = [entry.method, entry.endpoint, entry.operation,
                    entry.statusCode.map(String.init), entry.errorType, entry.semanticErrorType,
                    entry.scopePartition]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if head.contains(needle) { return true }
        return entry.responsePayloadJSON?.range(of: needle, options: .caseInsensitive) != nil
    }
}

/// Live, read-only view over the already-redacted API ring buffer. It deliberately reads the
/// sanitized store rather than observing transport traffic, so opening the inspector cannot
/// broaden what the application retains.
@MainActor
struct APIDiagnosticInspectorView: View {
    @AppStorage(AppTimeFormat.storageKey) private var timeFormat: AppTimeFormat = .twentyFourHour
    let store: APIDiagnosticLogStore

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [APILogEntry] = []
    /// The filtered entries, newest first. Built off the main thread whenever the log or a
    /// filter changes, so a render only reads it.
    @State private var rows: [Row] = []
    @State private var filterTask: Task<Void, Never>?
    /// "No API requests recorded" was asserted on the first frame, before the first snapshot had
    /// resolved, so an inspector with a full buffer briefly told the reader it had nothing.
    @State private var hasLoadedOnce = false
    @State private var provider: APILogProvider?
    @State private var outcome: APIDiagnosticOutcomeFilter = .all
    @State private var query = ""
    /// Keyed on the row's own identity, not its position, so a rebuilt list never re-points an
    /// open row at a different request.
    @State private var expandedRows = Set<RowID>()
    @State private var showClearConfirmation = false

    init(store: APIDiagnosticLogStore = .shared) {
        self.store = store
    }

    /// A timestamp alone is not unique: the log is saved with one-second precision, so every
    /// request of a refresh comes back from disk with the same one. The ordinal counts earlier
    /// entries that share it, which stays put as filters change.
    struct RowID: Hashable, Sendable {
        let timestamp: Date
        let ordinal: Int
    }

    struct Row: Identifiable, Sendable {
        let id: RowID
        let entry: APILogEntry
    }

    nonisolated static func rows(from entries: [APILogEntry],
                                 matching filter: APIDiagnosticInspectorFilter) -> [Row] {
        let needle = filter.normalizedQuery
        var seen: [Date: Int] = [:]
        var result: [Row] = []
        for entry in entries {
            let ordinal = seen[entry.timestamp, default: 0]
            seen[entry.timestamp] = ordinal + 1
            if filter.matches(entry, needle: needle) {
                result.append(Row(id: RowID(timestamp: entry.timestamp, ordinal: ordinal), entry: entry))
            }
        }
        return result.reversed()
    }

    private func refilter() {
        let filter = APIDiagnosticInspectorFilter(provider: provider, outcome: outcome, query: query)
        let source = entries
        let debounce = !filter.normalizedQuery.isEmpty
        filterTask?.cancel()
        filterTask = Task {
            // Typing restarts this task; only the last keystroke pays for a search.
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let result = await Self.filteredRows(source, filter)
            guard !Task.isCancelled else { return }
            rows = result
            hasLoadedOnce = true
        }
    }

    private nonisolated static func filteredRows(_ entries: [APILogEntry],
                                                 _ filter: APIDiagnosticInspectorFilter) async -> [Row] {
        rows(from: entries, matching: filter)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Live API Diagnostics"))
                        .hisType(.heading, weight: .semibold)
                    Text(L10n.format("%d redacted requests retained for up to 24 hours", entries.count))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Picker(L10n.text("Provider"), selection: $provider) {
                    Text(L10n.text("All providers")).tag(APILogProvider?.none)
                    ForEach(APILogProvider.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(Optional(value))
                    }
                }
                .frame(width: 150)
                Picker(L10n.text("Outcome"), selection: $outcome) {
                    ForEach(APIDiagnosticOutcomeFilter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .frame(width: 150)
                HisTextField(L10n.text("Filter endpoint, operation, status, or error"), text: $query)
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(L10n.text("Clear"), systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }

            if !hasLoadedOnce {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Reading the request log…"))
                        .hisType(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? L10n.text("No API requests recorded") : L10n.text("No matching requests"),
                    systemImage: "network.slash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                List(rows) { row in
                    let entry = row.entry
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedRows.contains(row.id) },
                        set: { expanded in
                            // Expansion animates the revealed detail block; the row
                            // chevron follows without extra work.
                            withAnimation(Motion.resolve(Motion.layout)) {
                                if expanded { expandedRows.insert(row.id) }
                                else { expandedRows.remove(row.id) }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 6) {
                            diagnosticDetail(L10n.text("Endpoint"), entry.endpoint)
                            diagnosticDetail(L10n.text("Operation"), entry.operation)
                            if let partition = entry.scopePartition {
                                diagnosticDetail(
                                    L10n.text("Log partition"),
                                    partition == VehicleLogScope.account.logPartition
                                        ? L10n.text("Account")
                                        : partition
                                )
                            }
                            diagnosticDetail(L10n.text("Duration"), "\(entry.durationMilliseconds) ms")
                            if let error = entry.errorType { diagnosticDetail(L10n.text("Error"), error) }
                            if let error = entry.semanticErrorType {
                                diagnosticDetail(L10n.text("API outcome"), error)
                            }
                            if let payload = entry.responsePayloadJSON {
                                Text(payload)
                                    .hisType(.caption, design: .monospaced)
                                    .textSelection(.enabled)
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 0))
                            } else if entry.payloadOmitted {
                                Text(L10n.format("Payload omitted (%@).",
                                                 entry.payloadOmissionReason ?? "unknown"))
                                    .hisType(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.provider.rawValue.uppercased())
                                .hisType(.micro, weight: .semibold)
                                .foregroundStyle(.secondary)
                            Text(entry.method).hisType(.caption, weight: .medium, design: .monospaced)
                            Text(entry.operation).lineLimit(1)
                            .minimumScaleFactor(0.9)
                            Spacer()
                            if let status = entry.statusCode {
                                Text(String(status))
                                    .hisType(.caption, design: .monospaced).monospacedDigit()
                                .foregroundStyle(status >= 400 || entry.semanticErrorType != nil
                                                 ? HisingenTheme.semanticCritical : Color.secondary)
                            } else if entry.errorType != nil {
                                Image(systemName: "wifi.exclamationmark").foregroundStyle(HisingenTheme.semanticWarning)
                            }
                            Text(Format.localizedDateFormatter(locale: timeFormat.locale(basedOn: L10n.displayLocale))
                                .string(from: entry.timestamp))
                                .hisType(.caption, design: .monospaced).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .transition(.opacity)
            }
        }
        .padding(14)
        // 760 was wider than the 430pt panel it opens from, overhanging its own parent by up to
        // 77 % at the narrow presets. It asks for what the measurement columns actually need.
        .frame(minWidth: 560, minHeight: 480)
        // refreshLoop() rewrites `entries` every second from outside any transaction;
        // keying on the count is what animates per-second row inserts and the
        // list↔empty-state swap.
        .hisAnimation(Motion.stateChange, value: entries.count)
        .confirmationDialog(
            L10n.text("Clear the redacted API request log?"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Clear Log"), role: .destructive) {
                Task {
                    await store.clear()
                    withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                        entries = []
                    }
                    refilter()
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("All retained request entries will be discarded. New requests are recorded again as they happen."))
        }
        .task { await refreshLoop() }
        .onChange(of: provider) { _, _ in refilter() }
        .onChange(of: outcome) { _, _ in refilter() }
        .onChange(of: query) { _, _ in refilter() }
        .onDisappear { filterTask?.cancel() }
    }

    /// The log only appends and trims its oldest entries, so a changed count or edge entry is a
    /// changed log.
    private static func logChanged(from old: [APILogEntry], to new: [APILogEntry]) -> Bool {
        old.count != new.count || old.first != new.first || old.last != new.last
    }

    private func diagnosticDetail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).hisType(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(value).hisType(.caption, design: .monospaced).textSelection(.enabled)
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            let latest = await store.snapshot()
            // Most seconds nothing was recorded. Publishing an equal array anyway re-rendered the
            // list and rebuilt every row once a second.
            if !hasLoadedOnce || Self.logChanged(from: entries, to: latest) {
                entries = latest
                refilter()
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
