import Foundation

/// The charger columns every charging-history export appends after its own, so the four exports
/// carry the same measured-energy, source and cost-method fields under the same names.
enum WallboxCSV {
    static let header: [String] = [
        "Charger Energy (kWh)", "Charger Energy Source", "Charger Measured At", "Charger ID", "Charger Session Key",
        "Charger Cost", "Charger Average Price (per kWh)", "Cost Method", "Price Source", "Cost Assumptions", "Missing Price Energy (kWh)", "Attribution"
    ]

    /// Columns that carry nothing sensitive and belong in a pack handed to someone else.
    static let handoverHeader: [String] = ["Charger Energy (kWh)", "Charger Cost", "Cost Method", "Price Source"]

    static func fields(_ wallbox: WallboxMeasurement?) -> [String] {
        guard let wallbox else { return Array(repeating: "", count: header.count) }
        return [
            String(format: "%.3f", wallbox.energyKwh),
            wallbox.energySource,
            Format.iso8601.string(from: wallbox.measuredAt),
            wallbox.chargerID,
            wallbox.sessionKey,
            wallbox.cost.map { String(format: "%.2f", $0) } ?? "",
            wallbox.cost.flatMap { wallbox.energyKwh > 0 ? String(format: "%.4f", $0 / wallbox.energyKwh) : nil } ?? "",
            wallbox.costMethod ?? "",
            wallbox.priceSource ?? "",
            wallbox.costAssumptions.joined(separator: "; "),
            wallbox.missingKwh.map { String(format: "%.3f", $0) } ?? "",
            wallbox.attribution ?? ""
        ]
    }

    static func handoverFields(_ wallbox: WallboxMeasurement?) -> [String] {
        guard let wallbox else { return Array(repeating: "", count: handoverHeader.count) }
        return [
            String(format: "%.3f", wallbox.energyKwh),
            wallbox.cost.map { String(format: "%.2f", $0) } ?? "",
            wallbox.costMethod ?? "",
            wallbox.priceSource ?? ""
        ]
    }

    /// Battery percentages carry -1 when the charger recorded a session with no battery reading.
    static func percent(_ value: Double, decimals: Int = 1) -> String {
        value < 0 ? "" : String(format: "%.\(decimals)f", value)
    }
}
