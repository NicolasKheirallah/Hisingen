import Foundation

/// The air outside the car, from the CAMS European air-quality forecast that Open-Meteo serves.
/// It is the model's value for the car's grid cell, not a measurement at the car: the cabin
/// sensors and the car's own outdoor particulate reading are separate things and stay separate.
struct OutdoorAirQuality: Equatable, Sendable {
    /// The European Air Quality Index. Open-Meteo gives the worst of its pollutant sub-indices.
    let europeanAQI: Int?
    /// Fine particles, µg/m³.
    let particulateMatter25: Double?

    /// The index's own six bands, named by the scale and never reworded. An index of 20 is the top
    /// of "good", 40 of "fair" and so on, and anything above 100 is "extremely poor".
    enum Band: Int, Equatable, Sendable, CaseIterable {
        case good, fair, moderate, poor, veryPoor, extremelyPoor

        init(index: Int) {
            switch index {
            case ...20: self = .good
            case 21...40: self = .fair
            case 41...60: self = .moderate
            case 61...80: self = .poor
            case 81...100: self = .veryPoor
            default: self = .extremelyPoor
            }
        }

        var displayName: String {
            switch self {
            case .good: return L10n.text("Good")
            case .fair: return L10n.text("Fair")
            case .moderate: return L10n.text("Moderate")
            case .poor: return L10n.text("Poor")
            case .veryPoor: return L10n.text("Very poor")
            case .extremelyPoor: return L10n.text("Extremely poor")
            }
        }
    }

    /// Nil when the model gave no index, so the readout shows nothing instead of a guessed band.
    var band: Band? { europeanAQI.map(Band.init(index:)) }
}
