import Foundation

/// What kind of work a maintenance entry records. The list is short on purpose: it holds the
/// things a service book actually has separate lines for, and everything else is "Other" with the
/// reader's own words in the title.
enum MaintenanceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case service
    case repair
    case inspection
    case tyres
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: return L10n.text("Service")
        case .repair: return L10n.text("Repair")
        case .inspection: return L10n.text("Inspection")
        case .tyres: return L10n.text("Tyres")
        case .other: return L10n.text("Other")
        }
    }

    var symbol: String {
        switch self {
        case .service: return "wrench.and.screwdriver"
        case .repair: return "hammer"
        case .inspection: return "checkmark.seal"
        case .tyres: return "circle.grid.2x2"
        case .other: return "square.and.pencil"
        }
    }
}

/// One line in the reader's own maintenance log: work done, when, at what odometer, and what it
/// cost. Kept locally, like the fuel log, and never derived from a provider reading – a service
/// visit is something the reader knows and the car does not report.
struct MaintenanceEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let vin: String
    let date: Date
    let odometerKm: Int?
    let kind: MaintenanceKind
    let title: String
    let notes: String?
    let cost: Double?

    init(id: String = UUID().uuidString, vin: String, date: Date, odometerKm: Int?,
         kind: MaintenanceKind, title: String, notes: String?, cost: Double?) {
        self.id = id
        self.vin = vin
        self.date = date
        self.odometerKm = odometerKm
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        self.cost = cost
    }
}

/// Parses and validates the maintenance sheet's text fields, so the sheet can put a reason beside
/// the field the reader got wrong and tests can pin the rules. Same shape as `FuelFillUpValidation`.
struct MaintenanceEntryValidation: Equatable, Sendable {
    enum Field: String, Sendable, CaseIterable {
        case cost, odometer, title
    }

    let cost: Double?
    let odometerKm: Int?
    let title: String
    let invalidFields: Set<Field>

    var isValid: Bool { invalidFields.isEmpty }

    static func validate(
        title: String, costText: String, odometerText: String, now: Date = Date()
    ) -> MaintenanceEntryValidation {
        var invalid = Set<Field>()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { invalid.insert(.title) }

        var cost: Double?
        if !costText.trimmingCharacters(in: .whitespaces).isEmpty {
            if let parsed = parse(costText), parsed >= 0, parsed.isFinite {
                cost = parsed
            } else {
                invalid.insert(.cost)
            }
        }

        var odometer: Int?
        if !odometerText.trimmingCharacters(in: .whitespaces).isEmpty {
            if let parsed = parse(odometerText), parsed >= 0, parsed < 10_000_000 {
                odometer = Int(parsed.rounded())
            } else {
                invalid.insert(.odometer)
            }
        }

        return MaintenanceEntryValidation(
            cost: cost, odometerKm: odometer, title: trimmedTitle, invalidFields: invalid)
    }

    /// The one-line reason a field is rejected, for display next to it. `nil` when valid.
    func reason(for field: Field) -> String? {
        guard invalidFields.contains(field) else { return nil }
        switch field {
        case .title: return L10n.text("Give the entry a name, for example “Front brake pads”.")
        case .cost: return L10n.text("Enter the cost as a number, or leave it empty.")
        case .odometer: return L10n.text("Enter the odometer as a number, or leave it empty.")
        }
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces))
    }
}

/// The reader's ownership assumption as the database returns it, or nil when they have not filled
/// it in. Its own type so a report can say "no assumption entered" without inventing a value.
struct VehicleOwnership: Equatable, Sendable {
    let vin: String
    let assumption: DepreciationAssumption
}
