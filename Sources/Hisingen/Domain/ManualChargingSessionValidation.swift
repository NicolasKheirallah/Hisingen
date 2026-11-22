import Foundation

/// Parses and validates the charging-session entry sheet's text fields. Pure, so the sheet can
/// show a reason per field while the reader types and tests can pin the rules. The energy is the
/// number from the receipt; a price may be given as the total paid, as a per-kWh figure, or both.
struct ManualChargingSessionValidation: Equatable, Sendable {
    enum Field: String, Sendable, CaseIterable {
        case energy, totalPrice, pricePerKwh
    }

    let energyKwh: Double
    let totalCost: Double?
    let pricePerKwh: Double?
    let invalidFields: Set<Field>

    /// No field was rejected. Entry additionally wants a price (`isComplete`); editing an
    /// existing session may keep no price rather than force the reader to invent one.
    var isValid: Bool { invalidFields.isEmpty }

    /// A session entered by hand needs a positive energy figure and at least one price. A total
    /// wins over a per-kWh figure when both are present, because it is the amount actually paid.
    var isComplete: Bool { isValid && hasPrice }

    var hasPrice: Bool { totalCost != nil || pricePerKwh != nil }

    /// True when neither price field was filled in and neither was malformed (a malformed one
    /// already gets its own message).
    var needsPrice: Bool {
        !hasPrice && !invalidFields.contains(.totalPrice) && !invalidFields.contains(.pricePerKwh)
    }

    /// The total stored with the session. A typed total wins; otherwise it is energy × price.
    var resolvedTotalCost: Double? {
        totalCost ?? pricePerKwh.map { $0 * energyKwh }
    }

    /// The per-kWh figure stored with the session. A typed per-kWh price wins; otherwise it is
    /// the total divided across the energy.
    var resolvedPricePerKwh: Double? {
        pricePerKwh ?? (energyKwh > 0 ? totalCost.map { $0 / energyKwh } : nil)
    }

    static func validate(energyText: String, totalPriceText: String, pricePerKwhText: String) -> ManualChargingSessionValidation {
        var invalid = Set<Field>()

        let energy = parse(energyText)
        if energy == nil || energy! <= 0 { invalid.insert(.energy) }

        var total: Double?
        if !totalPriceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = parse(totalPriceText), parsed >= 0, parsed.isFinite {
                total = parsed
            } else {
                invalid.insert(.totalPrice)
            }
        }

        var perKwh: Double?
        if !pricePerKwhText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = parse(pricePerKwhText), parsed >= 0, parsed.isFinite {
                perKwh = parsed
            } else {
                invalid.insert(.pricePerKwh)
            }
        }

        return ManualChargingSessionValidation(
            energyKwh: energy ?? 0,
            totalCost: invalid.contains(.totalPrice) ? nil : total,
            pricePerKwh: invalid.contains(.pricePerKwh) ? nil : perKwh,
            invalidFields: invalid
        )
    }

    /// The one-line reason a field is rejected, for display next to it. `nil` when valid.
    func reason(for field: Field) -> String? {
        guard invalidFields.contains(field) else { return nil }
        switch field {
        case .energy: return L10n.text("Enter the energy in kWh, greater than zero.")
        case .totalPrice: return L10n.text("Enter the total price as a number.")
        case .pricePerKwh: return L10n.text("Enter the price per kWh as a number.")
        }
    }

    private static func parse(_ text: String) -> Double? {
        Double(text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
