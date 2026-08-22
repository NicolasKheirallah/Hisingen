import Foundation

/// Single home for the physical unit factors used across formatting and domain math.
/// These constants were previously duplicated at five call sites with the risk of one
/// copy being "fixed" independently of the others.
enum UnitConversion {
    static let kilometersPerMile = 0.621371
    /// Assumed average consumption used to translate charging power into an estimated
    /// range-replenishment rate when no per-vehicle figure is known.
    static let defaultConsumptionWhPerKm = 180.0
}
