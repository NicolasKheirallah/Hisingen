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
    private let content: (ArraySlice<Row>, PaginationFooter) -> Content

    @State private var page = 0

    /// When any key changes — filter edit, period switch, fresh data — the list goes back
    /// to its first page, matching the behavior before paging moved into this module.
    init(items: [Row],
         pageSize: Int,
         resetKeys: [String] = [],
         newerHelp: String = L10n.text("Show newer entries"),
         olderHelp: String = L10n.text("Show older entries"),
         @ViewBuilder content: @escaping (ArraySlice<Row>, PaginationFooter) -> Content) {
        self.items = items
        self.pageSize = pageSize
        self.resetKeys = resetKeys
        self.newerHelp = newerHelp
        self.olderHelp = olderHelp
        self.content = content
    }

    var body: some View {
        let pageCount = HistoryPagination.pageCount(itemCount: items.count, pageSize: pageSize)
        let current = HistoryPagination.clampedPage(page, pageCount: pageCount)
        // Keyed on the (clamped) page index so every page swap — footer navigation,
        // filter reset, list shrinking under the last page — is a crossfade.
        Group {
            content(HistoryPagination.page(of: items, index: current, pageSize: pageSize),
                    PaginationFooter(page: current, pageCount: pageCount,
                                     newerHelp: newerHelp, olderHelp: olderHelp) { page = $0 })
        }
        .id(current)
        .transition(.opacity)
        .animation(Motion.resolve(Motion.entrance), value: current)
        .onChange(of: resetKeys) { _, _ in page = 0 }
    }
}

/// The "Newer · Page X of Y · Older" controls. Renders nothing while the list fits on one page.
struct PaginationFooter: View {
    let page: Int
    let pageCount: Int
    let newerHelp: String
    let olderHelp: String
    let goTo: (Int) -> Void

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 8) {
                Button { goTo(max(0, page - 1)) } label: {
                    Label(L10n.text("Newer"), systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .buttonStyle(.pressable).disabled(page == 0)
                .help(newerHelp)
                .accessibilityLabel(newerHelp)
                Spacer()
                Text(L10n.format("Page %d of %d", page + 1, pageCount))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.resolveCrossfade(Motion.telemetry), value: page)
                Spacer()
                Button { goTo(min(pageCount - 1, page + 1)) } label: {
                    Label(L10n.text("Older"), systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .buttonStyle(.pressable).disabled(page >= pageCount - 1)
                .help(olderHelp)
                .accessibilityLabel(olderHelp)
            }
            .padding(.top, 2)
        }
    }
}
