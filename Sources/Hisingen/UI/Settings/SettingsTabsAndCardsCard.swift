import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Tabs & Cards: which tabs exist, what is on each of them, and in what order.
///
/// This is the one place a reader can turn any card in the app off, move it, or place it on a
/// tab of their own. The layout it writes is the same `TabComposition` every tab renders from,
/// so what this pane shows is what the panel draws — there is no second list to drift.
@MainActor
struct SettingsTabsAndCardsCard: View {
    let binder: PreferenceBinder
    var state: VehicleState?

    @State private var selectedTab: TabRef = .vehicle
    @State private var searchText = ""
    @State private var showAddItems = false
    @State private var renamingTabID: String?
    @State private var renameText = ""
    @State private var showNewTabSheet = false
    @State private var newTabName = ""
    @State private var newTabSymbol = CustomTab.symbolChoices[0]
    @State private var pendingTabDeletion: TabRef?

    private var prefs: PreferencesStore { binder.preferences }
    private var composition: TabComposition { prefs.tabComposition }

    /// Persists a layout and reconciles the readings behind it.
    ///
    /// The change reaches the app as `.features` when a reading was switched on or off, because
    /// that is the notification that re-configures the notifier, the updater, the planner and
    /// the live stream. Reporting it as a presentation change would leave those services
    /// running against a selection that no longer exists.
    private func save(_ updated: TabComposition) {
        prefs.tabComposition = updated
        let moved = syncFeatures(to: updated)
        binder.bump()
        binder.notify(moved ? .features : .presentation)
    }

    /// Every reading an item on `tab` draws on, if the reader can see it there.
    private func requiredFeatures(of tab: TabRef) -> Set<AppFeature> {
        Set(tabItems(of: tab).compactMap { TabItemCatalog.item($0)?.feature })
    }

    private func tabItems(of tab: TabRef) -> [TabItemID] {
        composition.visibleItems(for: tab)
    }

    /// Everything the reader can currently see, across every tab. These readings must keep
    /// being fetched: a visible card with no reading behind it is an empty shell.
    private var keptFeatures: Set<AppFeature> {
        let tabs = composition.visibleTabs(includingSettings: true)
        return tabs.reduce(into: Set<AppFeature>()) { $0.formUnion(requiredFeatures(of: $1)) }
    }

    /// A card's switch is the same switch as its reading's.
    ///
    /// Switching a card off is the reader saying they do not want it, so the provider request
    /// behind it stops as well — that is the difference between hiding a card and paying for
    /// data nobody sees. A reading is only switched off when *no* visible card needs it and at
    /// least one card that used to use it is now off, so a reading the reader turned on by hand
    /// in the feature list is left alone.
    private func syncFeatures(to updated: TabComposition) -> Bool {
        var switchedOff: Set<AppFeature> = []
        let tabs = BuiltInTab.allCases.map { TabRef.builtIn($0) } + updated.customTabs.map(\.reference)
        for tab in tabs {
            let referenced = Set(updated.items(for: tab).compactMap { TabItemCatalog.item($0)?.feature })
            let shown = Set(updated.visibleItems(for: tab).compactMap { TabItemCatalog.item($0)?.feature })
            switchedOff.formUnion(referenced.subtracting(shown))
        }
        return prefs.stopFetchingUnusedFeatures(switchedOff, keeping: keptFeatures)
    }

    /// Switching a card on is the reader asking for it, which means asking for its reading too.
    private func ensureFeature(for item: TabItemID) {
        guard let feature = TabItemCatalog.item(item)?.feature else { return }
        var features = prefs.features
        guard !features.contains(feature) else { return }
        features.set(feature, enabled: true)
        prefs.features = features
    }

    private func enableFeatures<S: Sequence>(_ items: S) where S.Element == TabItemID {
        for item in items { ensureFeature(for: item) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                tabStrip
                Divider().opacity(HisingenTheme.dividerOpacity)

                if selectedTab == .settings {
                    settingsTabNotice
                } else {
                    // `tabControls` ends with the card list. Rendering `itemRows` again here drew
                    // every card twice.
                    tabControls
                }
            }
        }
        .sheet(isPresented: $showAddItems) {
            TabItemPickerSheet(
                tab: selectedTab,
                composition: composition,
                isCustomTab: selectedTab.customID != nil,
                onAdd: { item in
                    var updated = composition
                    updated.addItem(item, to: selectedTab)
                    // Nothing can show the card's reading if the reading is not fetched, so
                    // placing a card is also the instruction to start fetching it.
                    ensureFeature(for: item)
                    save(updated)
                },
                onDone: { showAddItems = false }
            )
        }
        .sheet(isPresented: $showNewTabSheet) { newTabSheet }
        .confirmationDialog(
            L10n.text("Delete this tab?"),
            isPresented: Binding(get: { pendingTabDeletion != nil },
                                 set: { if !$0 { pendingTabDeletion = nil } }),
            presenting: pendingTabDeletion
        ) { tab in
            Button(L10n.text("Delete Tab"), role: .destructive) {
                var updated = composition
                if let id = tab.customID { updated.removeCustomTab(id) }
                save(updated)
                if selectedTab == tab { selectedTab = .vehicle }
                pendingTabDeletion = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingTabDeletion = nil }
        } message: { tab in
            Text(L10n.format("“%@” and its card arrangement will be removed. The cards themselves stay available on the tabs they came from.", composition.title(for: tab)))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: "rectangle.3.group", title: L10n.text("Tabs & Cards"), color: .purple)
            Text(L10n.text("Choose what each tab shows, move cards into the order you want, or build a tab of your own from anything in Hisingen. Switching a card off also stops Hisingen requesting the data behind it."))
                .hisType(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabList, id: \.self) { tab in
                    let selected = selectedTab == tab
                    Button {
                        withAnimation(Motion.resolve(Motion.selection)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: composition.symbol(for: tab)).hisType(.micro)
                            Text(composition.title(for: tab))
                                .hisType(.caption, weight: selected ? .semibold : .regular)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(selected ? HisingenTheme.accent : .secondary)
                    .background(
                        selected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu { tabContextMenu(tab) }
                }

                Button {
                    newTabName = ""
                    newTabSymbol = CustomTab.symbolChoices[0]
                    showNewTabSheet = true
                } label: {
                    Image(systemName: "plus")
                        .hisType(.micro, weight: .semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(L10n.text("New tab"))
                .accessibilityLabel(L10n.text("New tab"))
            }
            .padding(.horizontal, 1)
        }
        .hisAnimation(Motion.selection, value: selectedTab)
    }

    private var tabList: [TabRef] {
        BuiltInTab.allCases.map { TabRef.builtIn($0) } + composition.customTabs.map(\.reference)
    }

    @ViewBuilder
    private func tabContextMenu(_ tab: TabRef) -> some View {
        if let builtIn = tab.builtIn, builtIn.isHideable {
            Button(composition.isVisible(tab) ? L10n.text("Hide Tab") : L10n.text("Show Tab")) {
                var updated = composition
                updated.setTab(builtIn, shown: !updated.isVisible(tab))
                save(updated)
                if !updated.isVisible(tab) { selectedTab = updated.visibleTabs().first ?? .vehicle }
            }
        }
        if let id = tab.customID {
            Button(L10n.text("Rename…")) {
                renameText = composition.customTab(id)?.name ?? ""
                renamingTabID = id
            }
            Button(L10n.text("Duplicate")) {
                var updated = composition
                _ = updated.duplicateCustomTab(id)
                save(updated)
            }
            Divider()
            Button(L10n.text("Delete Tab"), role: .destructive) { pendingTabDeletion = tab }
        }
        if tab == .settings {
            Text(L10n.text("Settings always stays available"))
        }
    }

    private var settingsTabNotice: some View {
        Text(L10n.text("Settings is where tabs are managed, so it cannot be hidden or rearranged."))
            .hisType(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: - Per-tab controls

    private var tabControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: composition.symbol(for: selectedTab))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                Text(composition.title(for: selectedTab))
                    .hisType(.label, weight: .semibold)
                Spacer()
                Text(L10n.format("%d of %d cards", visibleCount, totalCount))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
            }

            if selectedTab.customID != nil, let id = selectedTab.customID, let tab = composition.customTab(id) {
                customTabEditor(tab)
                Text(L10n.text("A tab of your own draws the cards that stand on their own — the vehicle cards and the remote controls. Cards that own a tab's own state (history charts, the Info section bars) stay on the tab they came from."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button {
                    showAddItems = true
                } label: {
                    Label(L10n.text("Add Cards…"), systemImage: "plus.circle")
                        .hisType(.micro, weight: .medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    var updated = composition
                    for entry in composition.items(for: selectedTab) { updated.setItem(entry, shown: true) }
                    enableFeatures(composition.items(for: selectedTab))
                    save(updated)
                } label: {
                    Label(L10n.text("Show All"), systemImage: "eye")
                        .hisType(.micro, weight: .medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    var updated = composition
                    for entry in composition.items(for: selectedTab) { updated.setItem(entry, shown: false) }
                    save(updated)
                } label: {
                    Label(L10n.text("Hide All"), systemImage: "eye.slash")
                        .hisType(.micro, weight: .medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(visibleCount == 0)

                Spacer()

                if let builtIn = selectedTab.builtIn {
                    Button {
                        var updated = composition
                        let shipped = TabItemCatalog.defaultItems(for: builtIn)
                        updated.setItems(shipped, for: selectedTab)
                        for entry in shipped { updated.setItem(entry, shown: true) }
                        enableFeatures(shipped)
                        save(updated)
                    } label: {
                        Label(L10n.text("Reset Tab"), systemImage: "arrow.uturn.backward")
                            .hisType(.micro, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.text("Restores this tab's original cards and order."))
                } else {
                    Button(role: .destructive) {
                        pendingTabDeletion = selectedTab
                    } label: {
                        Label(L10n.text("Delete Tab"), systemImage: "trash")
                            .hisType(.micro, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            searchField

            itemRows
        }
    }

    private func customTabEditor(_ tab: CustomTab) -> some View {
        HStack(spacing: 6) {
            if renamingTabID == tab.id {
                TextField(L10n.text("Tab name"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        var updated = composition
                        updated.rename(tab.id, to: renameText)
                        save(updated)
                        renamingTabID = nil
                    }
                Button(L10n.text("Done")) {
                    var updated = composition
                    updated.rename(tab.id, to: renameText)
                    save(updated)
                    renamingTabID = nil
                }
                .controlSize(.small)
            } else {
                Text(L10n.text("Name"))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                Button(tab.name) {
                    renameText = tab.name
                    renamingTabID = tab.id
                }
                .buttonStyle(.pressable)
                .hisType(.micro, weight: .medium)
                .help(L10n.text("Rename this tab"))
            }
            Spacer()
            symbolPicker(for: tab)
        }
    }

    private func symbolPicker(for tab: CustomTab) -> some View {
        Menu {
            ForEach(CustomTab.symbolChoices, id: \.self) { symbol in
                Button {
                    var updated = composition
                    updated.setSymbol(symbol, for: tab.id)
                    save(updated)
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        } label: {
            Image(systemName: tab.symbol).hisType(.micro)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("Tab icon"))
        .accessibilityLabel(L10n.text("Tab icon"))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").hisType(.micro).foregroundStyle(.secondary)
            TextField(L10n.text("Filter cards"), text: $searchText)
                .textFieldStyle(.plain)
                .hisType(.micro)
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
    }

    // MARK: - Rows

    private var tabItems: [TabItemID] {
        let items = composition.items(for: selectedTab)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            TabItemCatalog.title(item).lowercased().contains(needle)
                || (TabItemCatalog.item(item)?.detail.lowercased().contains(needle) ?? false)
        }
    }

    private var itemRows: some View {
        VStack(spacing: 3) {
            if tabItems.isEmpty {
                Text(searchText.isEmpty
                     ? L10n.text("This tab has no cards yet. Use Add Cards to place some.")
                     : L10n.text("No cards match this filter."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            ForEach(tabItems, id: \.self) { item in
                row(item)
            }
        }
    }

    private func row(_ item: TabItemID) -> some View {
        let entry = TabItemCatalog.item(item)
        let kind = entry?.kind ?? .card
        let isHeader = kind == .header
        let shown = composition.shows(item)
        let index = composition.items(for: selectedTab).firstIndex(of: item)
        return HStack(spacing: 8) {
            Image(systemName: TabItemCatalog.symbol(item))
                .hisType(.body)
                .foregroundStyle(shown ? .secondary : .tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(TabItemCatalog.title(item))
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(shown ? .primary : .secondary)
                    if isHeader {
                        chip(L10n.text("Pinned to top"))
                    } else if let source = entry?.sourceTab, source != (selectedTab.builtIn ?? source) {
                        chip(source.title)
                    }
                    // Cards and the readings behind them move together when this pane is used,
                    // so this only appears for a combination made in the feature list. Naming
                    // it beats a card that draws empty with no explanation.
                    if shown, let feature = entry?.feature, !prefs.features.contains(feature) {
                        chip(L10n.text("Data off"), warning: true)
                            .help(L10n.format("Hisingen is not requesting this reading because “%@” is switched off in Settings → Features.", feature.title))
                    }
                }
                Text(entry?.detail ?? "")
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if !isHeader {
                reorderControls(item: item)
            }

            Button {
                var updated = composition
                updated.setItem(item, shown: !shown)
                if !shown { ensureFeature(for: item) }
                save(updated)
            } label: {
                Image(systemName: shown ? "eye" : "eye.slash")
                    .hisType(.caption)
                    .foregroundStyle(shown ? HisingenTheme.accent : .secondary)
            }
            .buttonStyle(.pressable)
            .help(shown ? L10n.text("Hide from this tab") : L10n.text("Show on this tab"))
            // The label is the action, the value is the state: a screen reader that only
            // announced "Show on this tab" for a card already on the tab was describing the
            // opposite of what the button does.
            .accessibilityLabel(L10n.text("Shown on this tab"))
            .accessibilityValue(shown ? L10n.text("On") : L10n.text("Off"))
            .accessibilityHint(shown ? L10n.text("Hide from this tab") : L10n.text("Show on this tab"))

            Menu {
                if !isHeader {
                    Button(L10n.text("Move to Top")) { moveToTop(item) }
                        .disabled(index == topCardIndex || topCardIndex == nil)
                    Button(L10n.text("Move Up")) { moveBy(item, -1) }
                        .disabled(!composition.canMove(item, in: selectedTab, by: -1))
                    Button(L10n.text("Move Down")) { moveBy(item, 1) }
                        .disabled(!composition.canMove(item, in: selectedTab, by: 1))
                    Divider()
                }
                if let source = entry?.sourceTab, selectedTab.builtIn != source {
                    Button(L10n.format("Move to %@", source.title)) {
                        var updated = composition
                        updated.removeItem(item, from: selectedTab)
                        updated.addItem(item, to: .builtIn(source))
                        save(updated)
                    }
                } else if selectedTab.customID != nil, let source = entry?.sourceTab {
                    Text(L10n.format("Belongs to %@", source.title))
                }
                Button(L10n.text("Remove from This Tab"), role: .destructive) {
                    var updated = composition
                    updated.removeItem(item, from: selectedTab)
                    save(updated)
                }
            } label: {
                Image(systemName: "ellipsis").hisType(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("Card options"))
            .accessibilityLabel(L10n.text("Card options"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .opacity(shown ? 1.0 : 0.55)
        .contentShape(Rectangle())
        .draggable(TabItemDragPayload(item: item)) {
            Label(TabItemCatalog.title(item), systemImage: TabItemCatalog.symbol(item))
                .hisType(.caption)
                .padding(4)
        }
        .dropDestination(for: TabItemDragPayload.self) { payload, _ in
            guard let first = payload.first, first.item != item else { return false }
            var updated = composition
            updated.move(first.item, onto: item, in: selectedTab)
            save(updated)
            return true
        }
    }

    private func reorderControls(item: TabItemID) -> some View {
        HStack(spacing: 1) {
            Button { moveBy(item, -1) } label: {
                Image(systemName: "chevron.up").hisType(.nano, weight: .bold)
            }
            .buttonStyle(.pressable)
            .disabled(!composition.canMove(item, in: selectedTab, by: -1))
            .help(L10n.text("Move Up"))
            .accessibilityLabel(L10n.text("Move Up"))

            Button { moveBy(item, 1) } label: {
                Image(systemName: "chevron.down").hisType(.nano, weight: .bold)
            }
            .buttonStyle(.pressable)
            .disabled(!composition.canMove(item, in: selectedTab, by: 1))
            .help(L10n.text("Move Down"))
            .accessibilityLabel(L10n.text("Move Down"))
        }
        .foregroundStyle(.secondary)
    }

    private func chip(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .hisType(.nano, weight: .semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                (warning ? HisingenTheme.semanticWarning : Color.primary).opacity(warning ? 0.14 : 0.06),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .foregroundStyle(warning ? HisingenTheme.semanticWarning : Color.secondary)
    }

    // MARK: - Mutation

    /// Index of the first card, which is where "Move to Top" means. Headers stay above it:
    /// dropping a chart above the period picker would change what the picker appears to control.
    private var topCardIndex: Int? {
        composition.items(for: selectedTab)
            .firstIndex { TabItemCatalog.item($0)?.isCard == true }
    }

    private func moveToTop(_ item: TabItemID) {
        guard let target = topCardIndex else { return }
        var items = composition.items(for: selectedTab)
        guard let from = items.firstIndex(of: item) else { return }
        items.remove(at: from)
        items.insert(item, at: min(target, items.count))
        var updated = composition
        updated.setItems(items, for: selectedTab)
        save(updated)
    }

    private func moveBy(_ item: TabItemID, _ offset: Int) {
        var updated = composition
        updated.move(item, in: selectedTab, by: offset)
        save(updated)
    }

    // MARK: - Counts

    private var visibleCount: Int {
        composition.items(for: selectedTab).filter { composition.shows($0) }.count
    }

    private var totalCount: Int { composition.items(for: selectedTab).count }

    // MARK: - Sheets

    private var newTabSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("New Tab")).hisType(.heading, weight: .semibold)
            Text(L10n.text("Give it a name and an icon, then choose the cards to put on it."))
                .hisType(.caption)
                .foregroundStyle(.secondary)

            TextField(L10n.text("Tab name"), text: $newTabName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createTab)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                    ForEach(CustomTab.symbolChoices, id: \.self) { symbol in
                        Button {
                            newTabSymbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .hisType(.body)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(newTabSymbol == symbol ? HisingenTheme.accent : .secondary)
                        .background(
                            newTabSymbol == symbol ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .accessibilityLabel(symbol)
                        .accessibilityAddTraits(newTabSymbol == symbol ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 120)

            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showNewTabSheet = false }
                Button(L10n.text("Create")) { createTab() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTabName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func createTab() {
        var updated = composition
        let tab = updated.addCustomTab(name: newTabName, symbol: newTabSymbol)
        save(updated)
        selectedTab = tab
        showNewTabSheet = false
    }
}

/// A dragged card. Carries the catalog id rather than an index, because the visible order can
/// change under the drag (filtering, another card moved) and an index would then point at the
/// wrong card.
struct TabItemDragPayload: Codable, Transferable, Hashable {
    let item: TabItemID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .hisingenTabItem)
    }
}

extension UTType {
    static let hisingenTabItem = UTType(exportedAs: "io.kheirallah.hisingen.tab-item")
}
