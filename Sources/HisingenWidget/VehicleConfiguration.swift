import AppIntents
import HisingenIntents
import Foundation

/// One car the widget can be pinned to. The VIN is the stored identity — WidgetKit
/// encodes an instance's chosen entity into the widget's own configuration, so a widget
/// survives relaunches pointing at its car. The name rides along only for the picker and
/// is refreshed from the garage every time the sheet lists cars.
struct VehicleWidgetEntity: AppEntity, Codable, Equatable, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Car")
    static let defaultQuery = VehicleWidgetEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(vin: String, name: String) {
        id = vin
        self.name = name
    }
}

/// Lists the garage out of the App Group snapshot files. The query runs inside the
/// widget extension process whenever the Edit sheet opens, so the list is always the
/// app's latest completed refresh, never a cached copy of this process.
struct VehicleWidgetEntityQuery: EntityQuery, EntityStringQuery, Sendable {
    func suggestedEntities() async throws -> [VehicleWidgetEntity] {
        Self.entities(from: WidgetSnapshotStore.loadGarage())
    }

    func entities(for identifiers: [String]) async throws -> [VehicleWidgetEntity] {
        let wanted = Set(identifiers.map { $0.uppercased() })
        return Self.entities(from: WidgetSnapshotStore.loadGarage())
            .filter { wanted.contains($0.id.uppercased()) }
    }

    func entities(matching string: String) async throws -> [VehicleWidgetEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Self.entities(from: WidgetSnapshotStore.loadGarage()) }
        return Self.entities(from: WidgetSnapshotStore.loadGarage()).filter {
            $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
    }

    private static func entities(from cars: [VehicleWidgetSnapshot]) -> [VehicleWidgetEntity] {
        cars.map { VehicleWidgetEntity(vin: $0.vin, name: $0.name) }
    }
}

/// The per-widget car choice behind the vehicle widget's Edit sheet. An unset target
/// keeps the original behaviour: the widget follows the app's active car. A chosen car
/// renders that car's own readings; the selection is WidgetKit-persisted per instance.
///
/// The titles come from the English-key tables the app ships, so they localize the same
/// way the widget's other strings do; an unbundled build falls back to the English key.
struct VehicleSelectionIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Vehicle"
    static let description = IntentDescription("Choose which car the widget shows.")

    @Parameter(title: "Car")
    var target: VehicleWidgetEntity?
}

/// Which car one widget instance renders, given its configured VIN and the two snapshot
/// files. Pure value-in/value-out so fixture tests pin every branch; the widget UI
/// itself cannot be unit-tested.
enum VehicleWidgetSelection {
    struct Outcome: Equatable, Sendable {
        /// The car whose readings the widget draws; nil draws the placeholder.
        var snapshot: VehicleWidgetSnapshot?
        /// True when the configured car is missing and the active car stands in; the
        /// entry then carries a note saying so.
        var substitutedActiveCar: Bool
    }

    /// An unset (or empty) selection follows the active car, which is also the whole
    /// pre-configuration behaviour. A configured car renders from the garage. When it is
    /// gone — removed from the account, detached, or the files predate the configuration —
    /// the active car stands in with a note rather than an empty widget, and with no data
    /// at all (sign-out) the widget draws its placeholder.
    static func resolve(
        selectedVIN: String?,
        active: VehicleWidgetSnapshot?,
        garage: [VehicleWidgetSnapshot]
    ) -> Outcome {
        let selected = selectedVIN?.trimmingCharacters(in: .whitespaces)
        guard let selected, !selected.isEmpty else {
            return Outcome(snapshot: active, substitutedActiveCar: false)
        }
        if let match = garage.first(where: { $0.vin.caseInsensitiveCompare(selected) == .orderedSame }) {
            return Outcome(snapshot: match, substitutedActiveCar: false)
        }
        if let active, active.vin.caseInsensitiveCompare(selected) == .orderedSame {
            // The garage file is missing or older than the configuration, but the active
            // file still names the car: render it without the note.
            return Outcome(snapshot: active, substitutedActiveCar: false)
        }
        return Outcome(snapshot: active, substitutedActiveCar: active != nil)
    }
}
