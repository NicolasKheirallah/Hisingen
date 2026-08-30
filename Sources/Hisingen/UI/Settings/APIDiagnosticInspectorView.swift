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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
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
            return [entry.method, entry.endpoint, entry.operation,
                    entry.statusCode.map(String.init), entry.errorType, entry.semanticErrorType,
                    entry.responsePayloadJSON]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }
}

/// Live, read-only view over the already-redacted API ring buffer. It deliberately reads the
/// sanitized store rather than observing transport traffic, so opening the inspector cannot
/// broaden what the application retains.
@MainActor
struct APIDiagnosticInspectorView: View {
    let store: APIDiagnosticLogStore

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [APILogEntry] = []
    @State private var provider: APILogProvider?
    @State private var outcome: APIDiagnosticOutcomeFilter = .all
    @State private var query = ""
    /// Keyed on the entry's own timestamp, not its position: `filtered` is rebuilt every
    /// second by `refreshLoop()`, so an index would re-point at a different request.
    @State private var expandedRows = Set<Date>()

    init(store: APIDiagnosticLogStore = .shared) {
        self.store = store
    }

    private var filtered: [APILogEntry] {
        APIDiagnosticInspectorFilter(provider: provider, outcome: outcome, query: query)
            .apply(to: entries)
            .reversed()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Live API Diagnostics"))
                        .font(.headline)
                    Text(L10n.format("%d redacted requests retained for up to 24 hours", entries.count))
                        .font(.caption)
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
                TextField(L10n.text("Filter endpoint, operation, status, or error"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    Task {
                        await store.clear()
                        entries = []
                    }
                } label: {
                    Label(L10n.text("Clear"), systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? L10n.text("No API requests recorded") : L10n.text("No matching requests"),
                    systemImage: "network.slash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.timestamp) { entry in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedRows.contains(entry.timestamp) },
                        set: { expanded in
                            if expanded { expandedRows.insert(entry.timestamp) }
                            else { expandedRows.remove(entry.timestamp) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 6) {
                            diagnosticDetail(L10n.text("Endpoint"), entry.endpoint)
                            diagnosticDetail(L10n.text("Operation"), entry.operation)
                            diagnosticDetail(L10n.text("Duration"), "\(entry.durationMilliseconds) ms")
                            if let error = entry.errorType { diagnosticDetail(L10n.text("Error"), error) }
                            if let error = entry.semanticErrorType {
                                diagnosticDetail(L10n.text("API outcome"), error)
                            }
                            if let payload = entry.responsePayloadJSON {
                                Text(payload)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            } else if entry.payloadOmitted {
                                Text(L10n.format("Payload omitted (%@).",
                                                 entry.payloadOmissionReason ?? "unknown"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.provider.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.method).font(.caption.monospaced().weight(.medium))
                            Text(entry.operation).lineLimit(1)
                            Spacer()
                            if let status = entry.statusCode {
                                Text(String(status))
                                    .font(.caption.monospacedDigit())
                                .foregroundStyle(status >= 400 || entry.semanticErrorType != nil
                                                 ? Color.red : Color.secondary)
                            } else if entry.errorType != nil {
                                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                            }
                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 520)
        .task { await refreshLoop() }
    }

    private func diagnosticDetail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            entries = await store.snapshot()
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
