import SwiftUI

/// Pure paging arithmetic, shared by every paginated history list.
enum HistoryPagination {
    static let tripsPerPage = 5

    static func pageCount(itemCount: Int, pageSize: Int = tripsPerPage) -> Int {
        guard itemCount > 0, pageSize > 0 else { return 0 }
        return (itemCount + pageSize - 1) / pageSize
    }

    static func page<Element>(of items: [Element], index: Int,
                              pageSize: Int = tripsPerPage) -> ArraySlice<Element> {
        guard !items.isEmpty, pageSize > 0 else { return [] }
        let safeIndex = min(max(0, index), max(0, pageCount(itemCount: items.count, pageSize: pageSize) - 1))
        let start = safeIndex * pageSize
        return items[start..<min(items.count, start + pageSize)]
    }

    /// Display-safe page index: a delete or a period switch can shrink the list under the
    /// current page, and every pager must render a page that actually exists.
    static func clampedPage(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(0, index), pageCount - 1)
    }
}

/// Owns page state, clamping, slicing, and the "Newer · Page X of Y · Older" footer for a
/// paginated history list. The content closure receives the visible slice and the footer,
/// because each table renders its own rows and places the pager at a different spot
/// (trips and the command log put explanatory text below it).
struct PaginatedSection<Row: Identifiable, Content: View>: View {
    private let items: [Row]
    private let pageSize: Int
    private let resetKeys: [String]
    private let newerHelp: String
    private let olderHelp: String
    /// Shown when there is nothing to paginate. The component rendered a page of nothing and a
    /// footer reading "0–0 of 0", so every caller had to remember to guard it.
    private let emptyMessage: String?
    private let content: (ArraySlice<Row>, PaginationFooter) -> Content

    @State private var page = 0

    /// When any key changes – filter edit, period switch, fresh data – the list goes back
    /// to its first page, matching the behavior before paging moved into this module.
    init(items: [Row],
         pageSize: Int,
         resetKeys: [String] = [],
         newerHelp: String = L10n.text("Show newer entries"),
         olderHelp: String = L10n.text("Show older entries"),
         emptyMessage: String? = nil,
         @ViewBuilder content: @escaping (ArraySlice<Row>, PaginationFooter) -> Content) {
        self.items = items
        self.pageSize = pageSize
        self.resetKeys = resetKeys
        self.newerHelp = newerHelp
        self.olderHelp = olderHelp
        self.emptyMessage = emptyMessage
        self.content = content
    }

    var body: some View {
        let pageCount = HistoryPagination.pageCount(itemCount: items.count, pageSize: pageSize)
        let current = HistoryPagination.clampedPage(page, pageCount: pageCount)
        Group {
            if items.isEmpty, let emptyMessage {
                HisingenEmptyState(
                    symbol: "tray",
                    title: emptyMessage
                )
            } else {
                content(HistoryPagination.page(of: items, index: current, pageSize: pageSize),
                        PaginationFooter(page: current, pageCount: pageCount,
                                         pageSize: pageSize, itemCount: items.count,
                                         newerHelp: newerHelp, olderHelp: olderHelp) { page = $0 })
            }
        }
        // Deliberately no `.id(current)`: re-creating the subtree discarded row state and made a
        // second click unable to re-target. `resolveCrossfade` rather than `resolve`, because the
        // swap carries status and `resolve` returns nil under Reduce Motion, which took away the
        // only feedback the page change had.
        .hisAnimation(Motion.layout, value: current)
        .onChange(of: resetKeys) { _, _ in page = 0 }
        .onChange(of: current) { _, newPage in
            // The rows are replaced in place, so nothing told VoiceOver the page had moved.
            AccessibilityNotification.Announcement(
                L10n.format("Page %d of %d", newPage + 1, pageCount)
            ).post()
        }
    }
}

/// The "Newer · Page X of Y · Older" controls. Renders nothing while the list fits on one page.
struct PaginationFooter: View {
    let page: Int
    let pageCount: Int
    let pageSize: Int
    let itemCount: Int
    let newerHelp: String
    let olderHelp: String
    /// Shown when there is nothing to paginate. Required in spirit: the component renders its own
    /// empty state rather than a page of nothing and a "0–0 of 0" footer.
    var emptyMessage: String? = nil
    let goTo: (Int) -> Void

    /// "6–10 of 231" rather than "Page 2 of 47": the reader wants to know which rows they are
    /// looking at, and page sizes differ per list.
    private var rangeLabel: String {
        guard itemCount > 0, pageSize > 0 else {
            return L10n.format("Page %d of %d", page + 1, pageCount)
        }
        let first = page * pageSize + 1
        let last = min(itemCount, first + pageSize - 1)
        return L10n.format("%1$d–%2$d of %3$d", first, last, itemCount)
    }

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 8) {
                Button { goTo(max(0, page - 1)) } label: {
                    Label(L10n.text("Newer"), systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .buttonStyle(.pressable).disabled(page == 0)
                .help(page == 0 ? L10n.text("This is the newest page.") : newerHelp)
                .accessibilityLabel(newerHelp)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                Spacer()
                Text(rangeLabel)
                    .hisType(.micro, weight: HisingenTheme.captionWeight).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                    .hisAnimation(Motion.telemetry, value: page)
                Spacer()
                Button { goTo(min(pageCount - 1, page + 1)) } label: {
                    Label(L10n.text("Older"), systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .buttonStyle(.pressable).disabled(page >= pageCount - 1)
                .help(page >= pageCount - 1 ? L10n.text("This is the oldest page.") : olderHelp)
                .accessibilityLabel(olderHelp)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .padding(.top, 2)
        }
    }
}
