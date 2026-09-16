import SwiftUI

/// Picks cards to place on a tab.
///
/// The catalog is grouped by the tab each card was designed for, which is the only grouping a
/// reader can predict: they know where they saw the card, not what category the code filed it
/// under. Anything already on the tab is listed as such rather than hidden, so "why isn't this
/// here?" has an answer on screen.
@MainActor
struct TabItemPickerSheet: View {
    let tab: TabRef
    let composition: TabComposition
    /// A tab the reader built only draws cards that stand on their own. On a shipped tab the
    /// full catalog is offered, because that tab gives its own cards the state they need.
    var isCustomTab = false
    /// Called once per card the reader adds, so the caller can persist each one as it happens.
    let onAdd: (TabItemID) -> Void
    let onDone: () -> Void

    @State private var searchText = ""
    @State private var selected: Set<TabItemID> = []
    @State private var filter: Filter = .everything

    enum Filter: String, CaseIterable, Identifiable {
        case everything, notOnThisTab, hidden
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everything: return L10n.text("Everything")
            case .notOnThisTab: return L10n.text("Not on this tab")
            case .hidden: return L10n.text("Hidden")
            }
        }
    }

    private var placed: Set<TabItemID> { Set(composition.items(for: tab)) }

    private var matches: [TabItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TabItemCatalog.all.filter { entry in
            // On a tab of the reader's own, only free-standing cards are offered. The tab-owned
            // ones are listed with the reason, so the gap is stated rather than hidden.
            if isCustomTab, entry.isCard, !ComposableCards.isReusable(entry.id) { return false }
            switch filter {
            case .everything: break
            case .notOnThisTab: if placed.contains(entry.id) { return false }
            case .hidden: if !composition.isHidden(entry.id) { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.title.lowercased().contains(needle) || entry.detail.lowercased().contains(needle)
        }
    }

    private func group(_ source: BuiltInTab) -> [TabItem] {
        matches.filter { $0.sourceTab == source }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.format("Add cards to %@", composition.title(for: tab)))
                    .hisType(.heading, weight: .semibold)
                Spacer()
                Button(L10n.text("Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            Text(L10n.text("Pick cards from any tab. They keep working exactly as they do where they came from."))
                .hisType(.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").hisType(.micro).foregroundStyle(.secondary)
                TextField(L10n.text("Search cards"), text: $searchText)
                    .textFieldStyle(.plain)
                    .hisType(.caption)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").hisType(.micro).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(L10n.text("Clear Search"))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.text("Card filter"))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(BuiltInTab.allCases) { source in
                        let entries = group(source)
                        if !entries.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title)
                                    .hisType(.caption, weight: .bold)
                                    .foregroundStyle(.tertiary)
                                    .textCase(.uppercase)
                                    .tracking(0.3)
                                ForEach(entries) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                    if matches.isEmpty {
                        Text(L10n.text("No cards match this filter."))
                            .hisType(.micro)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 340)

            HStack {
                Text(L10n.format("%d selected", selected.count))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Add Selected")) {
                    for item in selected.sorted(by: { $0.rawValue < $1.rawValue }) { onAdd(item) }
                    selected.removeAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                Button(L10n.text("Close"), action: onDone)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ entry: TabItem) -> some View {
        let isPlaced = placed.contains(entry.id)
        let isHidden = composition.isHidden(entry.id)
        return Button {
            if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .hisType(.body)
                    .foregroundStyle(selected.contains(entry.id) ? AnyShapeStyle(HisingenTheme.accent) : AnyShapeStyle(.tertiary))
                Image(systemName: entry.symbol)
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.title)
                            .hisType(.label, weight: .medium)
                        if entry.kind == .header {
                            tag(L10n.text("Header"))
                        }
                        if isPlaced {
                            tag(L10n.text("On this tab"))
                        } else if isHidden {
                            tag(L10n.text("Hidden"))
                        }
                    }
                    Text(entry.detail)
                        .hisType(.nano)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .opacity(isPlaced ? 0.6 : 1.0)
        .help(entry.detail)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .hisType(.nano, weight: .semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }
}
