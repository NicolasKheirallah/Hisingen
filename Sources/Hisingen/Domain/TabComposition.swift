import Foundation

/// The tabs Hisingen ships with. Settings is deliberately not composable — it is the surface
/// where composition is managed, so a reader who hid it would have no way back.
enum BuiltInTab: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case vehicle, info, history, controls, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicle: return L10n.text("Vehicle")
        case .info: return L10n.text("Info")
        case .history: return L10n.text("History")
        case .controls: return L10n.text("Controls")
        case .settings: return L10n.text("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .vehicle: return "bolt.car"
        case .info: return "info.circle"
        case .history: return "chart.xyaxis.line"
        case .controls: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }

    /// Tabs a reader may hide. Settings cannot be hidden, and hiding the last visible tab
    /// would leave an empty panel with no way to navigate.
    static var hideableCases: [BuiltInTab] { [.vehicle, .info, .history, .controls] }

    var isHideable: Bool { Self.hideableCases.contains(self) }
}

/// Which tab the panel is showing: one of the shipped tabs, or a reader's own.
enum TabRef: Hashable, Codable, Sendable, Identifiable {
    case builtIn(BuiltInTab)
    case custom(String)

    static let vehicle = TabRef.builtIn(.vehicle)
    static let info = TabRef.builtIn(.info)
    static let history = TabRef.builtIn(.history)
    static let controls = TabRef.builtIn(.controls)
    static let settings = TabRef.builtIn(.settings)

    var id: String { storageKey }

    /// The key this tab is stored under. Built-in tabs move between builds; custom ids are
    /// generated here once and never regenerated, so a reader's placement of a card survives
    /// every update.
    var storageKey: String {
        switch self {
        case .builtIn(let tab): return "builtin:\(tab.rawValue)"
        case .custom(let id): return "custom:\(id)"
        }
    }

    var builtIn: BuiltInTab? {
        if case .builtIn(let tab) = self { return tab }
        return nil
    }

    var customID: String? {
        if case .custom(let id) = self { return id }
        return nil
    }

    var isBuiltIn: Bool { builtIn != nil }
}

/// A tab the reader built: a name, a glyph, and whichever cards they chose from any tab.
struct CustomTab: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var symbol: String

    init(id: String = UUID().uuidString, name: String, symbol: String = "square.grid.2x2") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    var reference: TabRef { .custom(id) }

    /// Glyphs a reader can pick for their tab. All are symbols the app already draws with, so
    /// a custom tab cannot introduce an icon that is missing on an older macOS.
    static let symbolChoices: [String] = [
        "square.grid.2x2", "bolt.car", "car.side", "bolt.fill", "batteryblock",
        "thermometer.medium", "location.fill", "chart.xyaxis.line", "chart.pie.fill",
        "powerplug.fill", "lock.fill", "fan", "wind", "road.lanes", "gauge.with.needle",
        "wrench.and.screwdriver", "sparkles", "shield.lefthalf.filled", "star.fill",
        "leaf.fill", "speedometer", "calendar", "clock", "mappin.and.ellipse"
    ]
}

/// Which tabs exist, what is on each of them, and in what order.
///
/// This is a layout record only. It never decides what data Hisingen fetches; the
/// `AppFeature` selection does that, and the Settings pane keeps the two in step so hiding
/// the last card that needs a reading also stops the request that fetched it.
struct TabComposition: Equatable, Codable, Sendable {
    /// Layout version, so a future shape change can migrate rather than silently reset a
    /// reader's tabs.
    var version: Int = 1

    /// Tabs whose contents differ from the shipped layout, keyed by `TabRef.storageKey`.
    /// A built-in tab is absent until the reader changes something about it, which is what
    /// keeps its default rendering free of composition entirely.
    var tabContents: [String: [TabItemID]] = [:]

    /// Items the reader switched off where they live. Hiding is separate from removal: a
    /// hidden card keeps its position, so switching it back on puts it back where it was.
    var hiddenItems: Set<TabItemID> = []

    /// Built-in tabs the reader hid. Settings is excluded — see `BuiltInTab.isHideable`.
    var hiddenTabs: Set<BuiltInTab> = []

    /// Tabs the reader built, in the order they were created.
    var customTabs: [CustomTab] = []

    static let `default` = TabComposition()

    // MARK: - Reading

    /// Contents of a tab: the reader's arrangement when they have one, otherwise the shipped
    /// layout.
    func items(for tab: TabRef) -> [TabItemID] {
        if let stored = tabContents[tab.storageKey] { return stored }
        guard let builtIn = tab.builtIn else { return [] }
        return TabItemCatalog.defaultItems(for: builtIn)
    }

    /// Whether an item should be drawn. Unlisted items are visible: a new card shipped in a
    /// later version appears for existing readers instead of being silently absent.
    func shows(_ item: TabItemID) -> Bool { !hiddenItems.contains(item) }

    func isHidden(_ item: TabItemID) -> Bool { hiddenItems.contains(item) }

    func customTab(_ id: String) -> CustomTab? { customTabs.first { $0.id == id } }

    func title(for tab: TabRef) -> String {
        if let id = tab.customID { return customTab(id)?.name ?? L10n.text("Custom Tab") }
        return tab.builtIn?.title ?? L10n.text("Tab")
    }

    func symbol(for tab: TabRef) -> String {
        if let id = tab.customID { return customTab(id)?.symbol ?? "square.grid.2x2" }
        return tab.builtIn?.symbol ?? "square.grid.2x2"
    }

    /// Tabs the tab bar draws, in order. Included even when `includeSettings` is false is the
    /// Settings tab itself, which is never composable.
    func visibleTabs(includingSettings includeSettings: Bool = false) -> [TabRef] {
        var out: [TabRef] = []
        for tab in BuiltInTab.allCases where tab != .settings {
            if !hiddenTabs.contains(tab) { out.append(.builtIn(tab)) }
        }
        out.append(contentsOf: customTabs.map(\.reference))
        if includeSettings { out.append(.settings) }
        return out
    }

    /// Whether this tab still renders its shipped layout rather than a stored arrangement.
    func isShipped(for tab: TabRef) -> Bool {
        tabContents[tab.storageKey] == nil && tab.builtIn != nil
    }

    func isVisible(_ tab: TabRef) -> Bool {
        if let builtIn = tab.builtIn { return builtIn == .settings || !hiddenTabs.contains(builtIn) }
        return customTab(tab.customID ?? "") != nil
    }

    /// Cards and headers the reader has placed on a tab, with hidden ones removed.
    ///
    /// A hidden tab reports nothing, which is what the Settings pane counts and what the panel
    /// draws. The arrangement is kept, so showing the tab again restores it untouched.
    func visibleItems(for tab: TabRef) -> [TabItemID] {
        guard isVisible(tab) else { return [] }
        return items(for: tab).filter { shows($0) }
    }

    func visibleCards(for tab: TabRef) -> [TabItemID] {
        visibleItems(for: tab).filter { TabItemCatalog.item($0)?.isCard ?? true }
    }

    var visibleCardCount: Int {
        visibleTabs().reduce(0) { $0 + visibleCards(for: $1).count }
    }

    // MARK: - Writing

    mutating func setItem(_ item: TabItemID, shown: Bool) {
        if shown { hiddenItems.remove(item) } else { hiddenItems.insert(item) }
    }

    mutating func setTab(_ tab: BuiltInTab, shown: Bool) {
        guard tab.isHideable else { return }
        if shown { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
    }

    /// Writes an explicit arrangement for a tab. Built-in tabs are seeded with their shipped
    /// layout first, so the caller's array is a reordering of what the reader already sees
    /// rather than a replacement of it.
    mutating func setItems(_ items: [TabItemID], for tab: TabRef) {
        var seen: Set<TabItemID> = []
        let deduplicated = items.filter { seen.insert($0).inserted }
        if let builtIn = tab.builtIn, deduplicated == TabItemCatalog.defaultItems(for: builtIn) {
            // Back to the shipped layout: drop the override so the tab tracks future default
            // changes instead of freezing today's list.
            tabContents.removeValue(forKey: tab.storageKey)
            return
        }
        tabContents[tab.storageKey] = deduplicated
    }

    mutating func move(_ item: TabItemID, in tab: TabRef, by offset: Int) {
        var current = items(for: tab)
        guard let index = current.firstIndex(of: item) else { return }
        let destination = index + offset
        guard current.indices.contains(destination) else { return }
        current.swapAt(index, destination)
        setItems(current, for: tab)
    }

    /// Moves a card to another card's position, which is what a drag reports.
    ///
    /// Expressed as "put this where that is" rather than as source/destination row indexes:
    /// rows in Settings are grouped and filtered, so a row index there is not an index into
    /// the tab's own order.
    mutating func move(_ item: TabItemID, onto target: TabItemID, in tab: TabRef) {
        guard item != target else { return }
        var current = items(for: tab)
        guard let from = current.firstIndex(of: item),
              let to = current.firstIndex(of: target) else { return }
        current.remove(at: from)
        current.insert(item, at: to)
        setItems(current, for: tab)
    }

    /// Moves cards within a tab by index set, the shape `List` drag reports.
    mutating func moveCards(in tab: TabRef, fromOffsets source: IndexSet, toOffset destination: Int) {
        let whole = items(for: tab)
        let headers = whole.filter { TabItemCatalog.item($0)?.isCard == false }
        var cards = whole.filter { TabItemCatalog.item($0)?.isCard ?? true }
        cards.move(fromOffsets: source, toOffset: destination)
        setItems(headers + cards, for: tab)
    }

    /// Moves a card by one position, for a keyboard or button reorder.

    /// Whether a card can move any further in the given direction, so a reorder control can be
    /// disabled instead of silently doing nothing at the ends of the list.
    func canMove(_ item: TabItemID, in tab: TabRef, by offset: Int) -> Bool {
        let current = items(for: tab)
        guard let index = current.firstIndex(of: item) else { return false }
        return current.indices.contains(index + offset)
    }

    /// Puts an item on a tab, shown, in the position its kind calls for: headers first, cards
    /// below them, matching every shipped tab's shape.
    mutating func addItem(_ item: TabItemID, to tab: TabRef) {
        setItem(item, shown: true)
        var current = items(for: tab)
        guard !current.contains(item), let entry = TabItemCatalog.item(item) else { return }
        if entry.isCard {
            // The end of the card section, so cards read in the order they were added rather
            // than newest-first. Headers keep the top, as on every shipped tab.
            current.append(item)
        } else {
            current.insert(item, at: 0)
        }
        setItems(current, for: tab)
    }

    mutating func removeItem(_ item: TabItemID, from tab: TabRef) {
        // A hidden item that is not on the tab is already gone from the reader's point of
        // view; keep it hidden so a later "add" does not quietly re-enable it.
        var current = items(for: tab)
        guard current.contains(item) else {
            hiddenItems.insert(item)
            return
        }
        current.removeAll { $0 == item }
        setItems(current, for: tab)
        hiddenItems.insert(item)
    }

    /// Puts an item back on the tab it was designed for, shown, at its shipped position.
    mutating func restoreItem(_ item: TabItemID) {
        hiddenItems.remove(item)
        guard let entry = TabItemCatalog.item(item) else { return }
        showItem(item, on: entry.sourceTab)
    }

    private mutating func showItem(_ item: TabItemID, on tab: BuiltInTab) {
        let reference = TabRef.builtIn(tab)
        var current = items(for: reference)
        guard !current.contains(item) else { return }
        let defaultOrder = TabItemCatalog.defaultItems(for: tab)
        let insertion = defaultOrder.firstIndex(of: item).map { defaultIndex in
            current.firstIndex { existing in
                (defaultOrder.firstIndex(of: existing) ?? Int.max) > defaultIndex
            } ?? current.count
        } ?? current.count
        current.insert(item, at: insertion)
        setItems(current, for: reference)
    }

    // MARK: - Custom tabs

    @discardableResult
    mutating func addCustomTab(name: String, symbol: String = "square.grid.2x2") -> TabRef {
        let tab = CustomTab(name: uniqueName(for: name), symbol: symbol)
        customTabs.append(tab)
        return tab.reference
    }

    mutating func rename(_ id: String, to name: String) {
        guard let index = customTabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customTabs[index].name = trimmed
    }

    mutating func setSymbol(_ symbol: String, for id: String) {
        guard let index = customTabs.firstIndex(where: { $0.id == id }) else { return }
        customTabs[index].symbol = symbol
    }

    mutating func removeCustomTab(_ id: String) {
        let reference = TabRef.custom(id)
        customTabs.removeAll { $0.id == id }
        tabContents.removeValue(forKey: reference.storageKey)
    }

    /// Copies a tab's arrangement onto a new tab. "Duplicate" is the shortest path to a second
    /// tab that differs from the first by one card.
    @discardableResult
    mutating func duplicateCustomTab(_ id: String) -> TabRef? {
        guard let source = customTab(id) else { return nil }
        let carried = visibleItems(for: source.reference)
        let copy = addCustomTab(name: L10n.format("%@ copy", source.name), symbol: source.symbol)
        setItems(carried, for: copy)
        return copy
    }

    private func uniqueName(for proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? L10n.text("My Tab") : trimmed
        guard customTabs.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while customTabs.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Repair

    /// Drops everything that can no longer be drawn. Called after decoding, so a catalog
    /// change or a hand-edited defaults file cannot leave a tab referring to a card that no
    /// longer exists — which would render as an empty slot with no way to remove it.
    func normalized() -> TabComposition {
        var result = self
        let known = Set(TabItemID.allCases)
        // Settings is never hideable, whatever a stored file claims.
        result.hiddenTabs.subtract([.settings])

        let customIDs = Set(result.customTabs.map(\.id))
        result.tabContents = result.tabContents.compactMapValues { items in
            // Deduplicated as well as filtered: a card listed twice would draw twice, and a
            // hand-edited defaults file is not a reason to render a tab that way.
            var seen: Set<TabItemID> = []
            let filtered = items.filter { known.contains($0) && seen.insert($0).inserted }
            return filtered.isEmpty ? nil : filtered
        }
        result.tabContents = result.tabContents.filter { key, _ in
            if key.hasPrefix("custom:") {
                return customIDs.contains(String(key.dropFirst("custom:".count)))
            }
            return true
        }
        return result
    }
}

/// One tab's layout as its view needs it: what to draw, and in what order.
///
/// Every tab view takes one of these instead of reading the composition itself, so the rules
/// that matter live in one place rather than in four copies that drift apart.
///
/// The empty case is deliberately not "the default": a tab of the reader's own starts with
/// nothing on it, and a hidden tab draws nothing, and both of those are genuinely empty lists.
/// Conflating them with "no layout yet" is how a hidden tab ends up drawing everything.
struct TabLayout: Equatable, Sendable {
    /// The items to draw, in order.
    let items: [TabItemID]
    /// Items the reader switched off where they live.
    let hidden: Set<TabItemID>
    /// Whether an item the layout has never heard of should still be drawn. True only for a tab
    /// the reader has never rearranged, where "not in the layout" means "added since".
    let includesNewItems: Bool

    private let rank: [TabItemID: Int]

    /// A tab the reader has not customised: everything, exactly as designed.
    static let everything = TabLayout(items: [], hidden: [], includesNewItems: true)

    init(items: [TabItemID], hidden: Set<TabItemID> = [], includesNewItems: Bool = false) {
        self.items = items
        self.hidden = hidden
        self.includesNewItems = includesNewItems
        self.rank = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1, $0) })
    }

    /// Builds the layout a tab renders from.
    static func resolve(_ composition: TabComposition, for tab: TabRef) -> TabLayout {
        TabLayout(
            items: composition.visibleItems(for: tab),
            hidden: composition.hiddenItems,
            includesNewItems: composition.isShipped(for: tab)
        )
    }

    var isDefault: Bool { includesNewItems && items.isEmpty }

    /// Whether the reader's layout draws this item.
    ///
    /// A tab the reader never rearranged draws an item it has never heard of, so a card shipped
    /// in a later version appears instead of going silently missing from their panel. Once they
    /// have arranged a tab themselves, that list is the whole truth about it.
    func draws(_ item: TabItemID) -> Bool {
        if rank[item] != nil { return true }
        // The reader switched it off, wherever it used to live.
        guard !hidden.contains(item) else { return false }
        // Not placed and not switched off. On a tab they never rearranged that means "added
        // since", which is drawn; on a tab they arranged themselves it means it is not theirs.
        return includesNewItems
    }

    /// The reader's order. Entries the layout does not place — only possible on a tab that
    /// accepts new items — keep the position they were given, after everything the reader did
    /// place.
    func ordered<T>(_ entries: [T], by item: (T) -> TabItemID) -> [T] {
        guard !items.isEmpty else { return entries }
        return entries.enumerated().sorted { lhs, rhs in
            let left = rank[item(lhs.element)] ?? (items.count + lhs.offset)
            let right = rank[item(rhs.element)] ?? (items.count + rhs.offset)
            return left < right
        }.map(\.element)
    }
}
