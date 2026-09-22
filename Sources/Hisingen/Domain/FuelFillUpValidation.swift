import Foundation

/// Parses and validates the fill-up sheet's text fields. Pure, so the sheet can show a
/// reason per field while the reader types and tests can pin the rules. The previous
/// behavior silently dropped invalid input: Save just did nothing.
struct FuelFillUpValidation: Equatable, Sendable {
    enum Field: String, Sendable, CaseIterable {
        case volume, price, odometer
    }

    let liters: Double
    let pricePerLiter: Double
    let odometerKm: Double?
    let invalidFields: Set<Field>

    var isValid: Bool { invalidFields.isEmpty }

    static func validate(volumeText: String, priceText: String, odometerText: String) -> FuelFillUpValidation {
        var invalid = Set<Field>()

        let liters = parse(volumeText)
        if liters == nil || liters! <= 0 { invalid.insert(.volume) }

        let price = parse(priceText)
        if price == nil || price! < 0 { invalid.insert(.price) }

        var odometer: Double?
        let odometerIsBlank = odometerText.trimmingCharacters(in: .whitespaces).isEmpty
        if !odometerIsBlank {
            let parsed = parse(odometerText)
            if let parsed, parsed >= 0 {
                odometer = parsed
            } else {
                invalid.insert(.odometer)
            }
        }

        return FuelFillUpValidation(
            liters: liters ?? 0,
            pricePerLiter: price ?? 0,
            odometerKm: odometer,
            invalidFields: invalid
        )
    }

    /// The one-line reason a field is rejected, for display next to it. `nil` when valid.
    func reason(for field: Field) -> String? {
        guard invalidFields.contains(field) else { return nil }
        switch field {
        case .volume: return L10n.text("Enter the volume in litres, greater than zero.")
        case .price: return L10n.text("Enter the price per litre as a number.")
        case .odometer: return L10n.text("Enter the odometer as a number.")
        }
    }

    private static func parse(_ text: String) -> Double? {
        // Comma normalizes to the decimal separator (the sheet's Swedish-first convention)
        // and spaces are grouping separators a reader may type in an odometer value.
        Double(text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces))
    }
}
