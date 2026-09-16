import Foundation

/// Whether a catalogued card may draw at all.
///
/// The catalog already declares which stored data each card draws on (`TabItem.feature`), and
/// hiding the last card that needs a reading is what switches the corresponding provider request
/// off. That declaration was never consulted where a reader's own tab is actually composed:
/// `ComposableCards.view(_:)` constructed every card unconditionally, so a card whose feature the
/// reader had switched off still drew *and still ran its side effects* — the charging planner
/// fetched spot prices with its feature off.
///
/// This is the one place that answers the question, and the only thing it decides is the declared
/// rule: is this card's data switched on. Whether the provider has returned anything yet is left to
/// the cards, which can see the snapshot and this module cannot.
enum CardAvailability: Equatable, Sendable {
    /// The card may draw.
    case drawable
    /// The reader switched this card's data off, so the card must not draw and must not start work.
    case switchedOff

    /// The answer for one catalogued item.
    static func of(_ item: TabItemID, enabledFeatures: Set<AppFeature>) -> CardAvailability {
        // An item with no declared feature draws on data the app always fetches, so there is
        // nothing for the reader to have switched off.
        guard let feature = TabItemCatalog.item(item)?.feature else { return .drawable }
        return enabledFeatures.contains(feature) ? .drawable : .switchedOff
    }
}
