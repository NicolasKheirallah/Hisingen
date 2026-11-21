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
                    entry.statusCode.map(String.init), entry.errorType, entry.semanticErrorType]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if head.contains(needle) { return true }
        return entry.responsePayloadJSON?.range(of: needle, options: .caseInsensitive) != nil
    }
}

/// Which partition of the log the inspector is showing. `.all` merges every vehicle so a
/// cross-car timeline is still one glance away.
enum VehicleLogSelection: Hashable, Sendable {
    case all
    case partition(APILogPartitionKey)
}

/// Live, read-only view over the already-redacted per-vehicle log. It deliberately reads the
/// sanitized store rather than observing transport traffic, so opening the inspector cannot
/// broaden what the application retains.
@MainActor
struct APIDiagnosticInspectorView: View {
    @AppStorage(AppTimeFormat.storageKey) private var timeFormat: AppTimeFormat = .twentyFourHour
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.dismiss) private var dismiss

    let store: APIDiagnosticLogStore
    /// The garage as the rest of Settings knows it. The picker lists every car here, not only
    /// the cars that happen to have recorded something, so "this car made no requests" is a
    /// readable answer rather than a missing option.
    let fleet: FleetSnapshot
    let activeVIN: String?

    @State private var partitions: [APILogPartition] = []
    @State private var choices: [Choice] = []
    @State private var titles: [APILogPartitionKey: String] = [:]
    @State private var selection: VehicleLogSelection = .all
    @State private var didApplyDefaultSelection = false
    /// The filtered rows, newest first. Built off the main thread whenever the log or a
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

    init(store: APIDiagnosticLogStore = .shared,
         fleet: FleetSnapshot = FleetSnapshot(),
         activeVIN: String? = nil) {
        self.store = store
        self.fleet = fleet
        self.activeVIN = activeVIN
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
        let partition: APILogPartitionKey?
        let entry: APILogEntry
    }

    struct Choice: Identifiable, Hashable, Sendable {
        let id: String
        let selection: VehicleLogSelection
        let title: String
    }

    nonisolated static func rows(from entries: [APILogEntry],
                                 matching filter: APIDiagnosticInspectorFilter) -> [Row] {
        rows(from: entries.map { (partition: nil, entry: $0) }, matching: filter)
    }

    /// `tagged` is oldest-first for the selection. Row identity counts entries sharing a
    /// timestamp in that order, so it survives filtering.
    nonisolated static func rows(from tagged: [(partition: APILogPartitionKey?, entry: APILogEntry)],
                                 matching filter: APIDiagnosticInspectorFilter) -> [Row] {
        let needle = filter.normalizedQuery
        var seen: [Date: Int] = [:]
        var result: [Row] = []
        for item in tagged {
            let entry = item.entry
            let ordinal = seen[entry.timestamp, default: 0]
            seen[entry.timestamp] = ordinal + 1
            if filter.matches(entry, needle: needle) {
                result.append(Row(id: RowID(timestamp: entry.timestamp, ordinal: ordinal),
                                  partition: item.partition,
                                  entry: entry))
            }
        }
        return result.reversed()
    }

    /// The entries for one selection, oldest first. Merging keeps a stable order for rows that
    /// share a timestamp, because the partition key breaks the tie.
    nonisolated static func taggedEntries(
        from partitions: [APILogPartition],
        selection: VehicleLogSelection
    ) -> [(partition: APILogPartitionKey?, entry: APILogEntry)] {
        switch selection {
        case .partition(let key):
            let entries = partitions.first(where: { $0.key == key })?.entries ?? []
            return entries.map { (partition: key, entry: $0) }
        case .all:
            var tagged: [(partition: APILogPartitionKey?, entry: APILogEntry)] = []
            for partition in partitions {
                for entry in partition.entries {
                    tagged.append((partition.key, entry))
                }
            }
            return tagged.enumerated().sorted { lhs, rhs in
                if lhs.element.entry.timestamp == rhs.element.entry.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.entry.timestamp < rhs.element.entry.timestamp
            }.map(\.element)
        }
    }

    private var selectedEntries: [(partition: APILogPartitionKey?, entry: APILogEntry)] {
        Self.taggedEntries(from: partitions, selection: selection)
    }

    private var selectedTitle: String {
        switch selection {
        case .all: return L10n.text("All")
        case .partition(let key): return titles[key] ?? L10n.text("Vehicle")
        }
    }

    private func refilter() {
        let filter = APIDiagnosticInspectorFilter(provider: provider, outcome: outcome, query: query)
        let source = selectedEntries
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

    private nonisolated static func filteredRows(
        _ source: [(partition: APILogPartitionKey?, entry: APILogEntry)],
        _ filter: APIDiagnosticInspectorFilter
    ) async -> [Row] {
        rows(from: source, matching: filter)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Live API Diagnostics"))
                        .hisType(.heading, weight: .semibold)
                    Text(L10n.format("%d redacted requests retained for up to 24 hours",
                                     selectedEntries.count))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Picker(L10n.text("Vehicle"), selection: $selection) {
                    ForEach(choices) { choice in
                        Text(choice.title).tag(choice.selection)
                    }
                }
                .frame(width: 190)
                Picker(L10n.text("Provider"), selection: $provider) {
                    Text(L10n.text("All providers")).tag(APILogProvider?.none)
                    ForEach(APILogProvider.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(Optional(value))
                    }
                }
                .frame(width: 140)
                Picker(L10n.text("Outcome"), selection: $outcome) {
                    ForEach(APIDiagnosticOutcomeFilter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .frame(width: 140)
            }

            HStack(spacing: 8) {
                HisTextField(L10n.text("Filter endpoint, operation, status, or error"), text: $query)
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(L10n.text("Clear"), systemImage: "trash")
                }
                .disabled(selectedEntries.isEmpty)
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
                    selectedEntries.isEmpty ? L10n.text("No API requests recorded")
                                            : L10n.text("No matching requests"),
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
                            if let partition = row.partition, let title = titles[partition] {
                                diagnosticDetail(L10n.text("Vehicle"), title)
                            }
                            diagnosticDetail(L10n.text("Endpoint"), entry.endpoint)
                            diagnosticDetail(L10n.text("Operation"), entry.operation)
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
                            // The vehicle leads in the merged view: it is the first thing the
                            // reader is scanning for when every car's requests share a list.
                            if selection == .all, let partition = row.partition,
                               let title = titles[partition] {
                                Text(title)
                                    .hisType(.micro, weight: .semibold)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 130, alignment: .leading)
                                    .foregroundStyle(.secondary)
                            }
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
        .frame(minWidth: 620, minHeight: 480)
        // refreshLoop() rewrites `partitions` every second from outside any transaction;
        // keying on the row count is what animates per-second row inserts and the
        // list↔empty-state swap.
        .hisAnimation(Motion.stateChange, value: rows.count)
        .confirmationDialog(
            L10n.text("Clear the redacted API request log?"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Clear Log"), role: .destructive) {
                clearSelection()
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(clearConfirmationMessage)
        }
        .task { await refreshLoop() }
        .onChange(of: provider) { _, _ in refilter() }
        .onChange(of: outcome) { _, _ in refilter() }
        .onChange(of: query) { _, _ in refilter() }
        .onChange(of: selection) { _, _ in refilter() }
        .onDisappear { filterTask?.cancel() }
    }

    private var clearConfirmationMessage: String {
        switch selection {
        case .all:
            return L10n.text("All retained request entries will be discarded. New requests are recorded again as they happen.")
        case .partition:
            return L10n.format(
                "%@ entries will be discarded. New requests are recorded again as they happen.",
                selectedTitle)
        }
    }

    private func clearSelection() {
        let selection = self.selection
        Task {
            switch selection {
            case .all:
                await store.clearAll()
            case .partition(let key):
                await store.clear(key)
            }
            let latest = await store.partitions()
            withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                partitions = latest
                rebuildChoices()
                refilter()
            }
        }
    }

    /// The options are the garage (in its order) plus any partition the store knows about that
    /// no current vehicle claims: account traffic, rows from before per-vehicle logs, and a
    /// signed-out car whose log outlived the session.
    private func rebuildChoices() {
        var nextChoices: [Choice] = [Choice(id: "all", selection: .all,
                                            title: L10n.text("All"))]
        var nextTitles: [APILogPartitionKey: String] = [:]
        var claimed = Set<APILogPartitionKey>()
        for vin in fleet.vehicles(orderedBy: preferences.garageVehicleOrder) {
            let key = APILogPartitionKey.vehicle(vin)
            guard !claimed.contains(key) else { continue }
            claimed.insert(key)
            let state = fleet.snapshot(for: vin)
            let brand: VehicleBrand = state?.model.brand
                ?? (VehicleBrand.isVolvoVIN(vin) ? .volvo : preferences.activeBrand)
            let title = preferences.formattedVehicleTitle(
                vin: vin,
                modelName: state?.identity.modelName,
                modelYear: state?.identity.modelYear,
                registrationNo: state?.identity.registrationNo,
                fallbackBrand: brand)
            nextTitles[key] = title
            nextChoices.append(Choice(id: key.rawValue, selection: .partition(key), title: title))
        }
        for partition in partitions where !claimed.contains(partition.key) {
            let title: String
            switch partition.key {
            case .account:
                title = L10n.text("Account")
            case .legacy:
                title = L10n.text("Unknown")
            default:
                let suffix = partition.key.rawValue
                    .replacingOccurrences(of: "vehicle-", with: "")
                    .prefix(4).uppercased()
                title = L10n.format("Vehicle %@", String(suffix))
            }
            nextTitles[partition.key] = title
            nextChoices.append(Choice(id: partition.key.rawValue,
                                      selection: .partition(partition.key), title: title))
        }
        choices = nextChoices
        titles = nextTitles
        if case .partition(let key) = selection,
           !nextChoices.contains(where: { $0.selection == .partition(key) }) {
            selection = .all
        }
    }

    /// The log only appends and trims its oldest entries, so a changed count or edge entry is a
    /// changed log.
    private static func logChanged(from old: [APILogPartition], to new: [APILogPartition]) -> Bool {
        guard old.count == new.count else { return true }
        for (left, right) in zip(old, new) where left.key != right.key
            || left.entries.count != right.entries.count
            || left.entries.first != right.entries.first
            || left.entries.last != right.entries.last {
            return true
        }
        return false
    }

    private func diagnosticDetail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).hisType(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(value).hisType(.caption, design: .monospaced).textSelection(.enabled)
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            let latest = await store.partitions()
            // Most seconds nothing was recorded. Publishing an equal array anyway re-rendered the
            // list and rebuilt every row once a second.
            if !hasLoadedOnce || Self.logChanged(from: partitions, to: latest) {
                partitions = latest
                rebuildChoices()
                if !didApplyDefaultSelection {
                    didApplyDefaultSelection = true
                    if let vin = activeVIN?.normalizedVIN, !vin.isEmpty {
                        selection = .partition(.vehicle(vin))
                    }
                }
                refilter()
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
