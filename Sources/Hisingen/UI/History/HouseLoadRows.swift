import SwiftUI

/// Log, Charging Trends: how much of the house's metered electricity the car used, from the house
/// meter's hourly readings (Tibber, or Perific when Tibber is not connected) and the home charger's
/// own measurements.
struct HouseLoadRows: View {
    let share: HouseLoadShare

    private var shareInfo: String {
        let from = Format.shortDate(date: share.coveredFrom)
        let to = Format.shortDate(date: share.coveredTo)
        var text = share.meter == .perific
            ? L10n.format("Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter.", from, to)
            : L10n.format("Charger-measured home sessions against the house meter's readings from Tibber, %@ to %@. Charging away from home never reaches that meter.", from, to)
        if share.cappedHours > 0 {
            text += " " + L10n.format(
                "In %d of those hours the charger's energy was above the meter's reading, so the reading was used.",
                share.cappedHours)
        }
        return text
    }

    private var costSymbol: String {
        guard let currency = share.currency else { return "" }
        return currency == "SEK" ? "kr" : currency
    }

    var body: some View {
        KVRow(L10n.text("Car Share of House Load"), Format.percent(share.carShare * 100), symbol: "house", info: shareInfo)
        KVRow(L10n.text("House Consumption"), Format.energyKwh(share.houseKwh, decimals: 0), symbol: "bolt.horizontal")
        KVRow(L10n.text("Car at Home"), Format.energyKwh(share.carKwh, decimals: 0), symbol: "car")
        KVRow(L10n.text("Rest of the House"), Format.energyKwh(share.restKwh, decimals: 0), symbol: "house")
        if let houseCost = share.houseCost, let carCost = share.carCost {
            KVRow(L10n.text("House Cost"), Format.currency(houseCost, symbol: costSymbol, decimals: 0), symbol: "creditcard",
                  info: share.includesGridFee
                      ? L10n.text("What Tibber billed for the energy in those hours, taxes included, plus the grid transfer fee from your tariff. The fixed fee is not in it.")
                      : L10n.text("What Tibber billed for the energy in those hours, taxes included. The grid fee is not in it."))
            KVRow(L10n.text("Car Cost at Home"), Format.currency(carCost, symbol: costSymbol, decimals: 0), symbol: "car",
                  info: share.includesGridFee
                      ? L10n.text("The car's energy at each hour's average Tibber price plus your grid transfer fee. Sessions are priced by the quarter-hour, so the two can differ.")
                      : L10n.text("The car's energy at each hour's average Tibber price. Sessions are priced by the quarter-hour with your network fee, so the two can differ."))
        }
    }
}
