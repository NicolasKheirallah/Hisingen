import Foundation

/// How much of a card a placement draws.
///
/// A card with two forms keeps the same identity in the catalogue: the placement decides
/// whether it draws the summary that points at its full form, or the full form itself.
enum CardViewType: String, CaseIterable, Codable, Hashable, Sendable {
    case summary
    case full

    var title: String {
        switch self {
        case .summary: return L10n.text("Summary")
        case .full: return L10n.text("Full")
        }
    }
}

/// Which cards have more than one form, and where the full form lives.
///
/// For each of them the full form is another tab's card: the planner, the home charger's plan and
/// the departure check on Plan; doors and parking on Car. The summary is therefore offered only
/// where following its link is a move rather than a no-op, so a card on its own full tab does not
/// offer a summary that would send the reader back to itself.
enum CardViewSupport {
    /// The tab a summary's link opens, for each card that can draw one. A card absent here has a
    /// single form and no view choice.
    static let summaryDestinations: [TabItemID: BuiltInTab] = [
        .controlsChargingPlanner: .controls,
        .vehicleHomeCharger: .controls,
        .vehicleReadiness: .controls,
        .vehicleOpenings: .info,
        .vehicleLocation: .info
    ]

    static func canonical(_ item: TabItemID) -> TabItemID { TabItemCatalog.canonicalID(item) }

    /// Whether this card can draw a summary at all.
    static func hasMultipleViews(_ item: TabItemID) -> Bool {
        summaryDestinations[canonical(item)] != nil
    }

    /// The tab a summary links to, or nil for a card with one form.
    static func destination(for item: TabItemID) -> BuiltInTab? {
        summaryDestinations[canonical(item)]
    }

    /// The forms worth offering on `tab`. A card on the tab its summary points at offers only
    /// the full form, because a summary there would send the reader to the card they are
    /// already looking at.
    static func choices(for item: TabItemID, on tab: TabRef) -> [CardViewType] {
        guard hasMultipleViews(item) else { return [.full] }
        if let destination = destination(for: item), tab.builtIn == destination { return [.full] }
        return [.summary, .full]
    }

    /// What a placement draws until the reader chooses otherwise. Now has always drawn these
    /// cards in their summary form; every other tab has drawn the full form.
    static func defaultType(for item: TabItemID, on tab: TabRef) -> CardViewType {
        guard tab == .vehicle, choices(for: item, on: tab).contains(.summary) else { return .full }
        return .summary
    }
}
