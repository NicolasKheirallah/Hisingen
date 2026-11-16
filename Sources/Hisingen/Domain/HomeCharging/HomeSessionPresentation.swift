import Foundation

/// The wording for the charger's side of a session: what it measured, when, and how its cost was reached.
struct WallboxSessionPresentation: Equatable {
    var energyValue: String
    var energyInfo: String
    var costLabel: String
    /// `nil` when no cost is known at all.
    var costValue: String?
    var costInfo: String?

    init(_ wallbox: WallboxMeasurement, currencyFallback: String) {
        energyValue = Format.energyKwh(wallbox.energyKwh)
        energyInfo = L10n.format(
            "Metered by the charger and read from Home Assistant. Last charger reading %@.",
            Format.dateTimeFormatter.string(from: wallbox.measuredAt)
        )
        let currency = wallbox.currency ?? currencyFallback
        if let cost = wallbox.cost {
            costValue = Format.currency(cost, symbol: currency)
            costLabel = wallbox.isEstimatedCost ? L10n.text("Estimated Electricity Cost") : L10n.text("Electricity Cost")
        } else if let missing = wallbox.missingKwh, missing > 0.005 {
            costValue = L10n.format("Missing prices for %@", Format.energyKwh(missing, decimals: 2))
            costLabel = L10n.text("Electricity Cost")
        } else {
            costValue = nil
            costLabel = L10n.text("Electricity Cost")
        }
        var lines: [String] = []
        if let source = wallbox.priceSource { lines.append(L10n.format("Price source: %@.", source)) }
        if let method = wallbox.costMethod.flatMap(HomeSessionCost.Method.init(rawValue:)) {
            lines.append(Self.methodSentence(method))
        }
        lines.append(contentsOf: wallbox.costAssumptions)
        costInfo = lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    private static func methodSentence(_ method: HomeSessionCost.Method) -> String {
        switch method {
        case .intervalTibber: return L10n.text("Priced per 15-minute interval from the charger's own readings.")
        case .totalTibberAverage: return L10n.text("Only the session total was available, so this is an estimate.")
        case .totalSpotPolicy: return L10n.text("Only the session total was available, so this is an estimate.")
        case .totalFixedTariff: return L10n.text("Only the session total was available, so this is an estimate.")
        }
    }
}
