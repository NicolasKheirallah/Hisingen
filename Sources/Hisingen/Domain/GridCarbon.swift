import Foundation

/// One live grid-carbon reading. The source is carried with the value so the line can say
/// where it came from; a reading is never constructed without a provider answer behind it.
struct GridCarbonReading: Equatable, Sendable {
    /// The provider name, not translated: it is a product name.
    static let electricityMapsSource = "Electricity Maps"

    /// The provider's zone id, for example `SE-SE3`.
    let zone: String
    let gramsCO2PerKwh: Double
    /// When the provider last updated the figure. `nil` when the answer carried no time.
    let observedAt: Date?
    let source: String
}
