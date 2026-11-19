import Foundation

/// Whether a catalogued card may draw at all.
///
/// Catalogued cards declare the feature needed to request their data.
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
