import AppIntents
import Foundation

/// How a Focus treats the chosen vehicle's notifications. The raw values are what the
/// system stores per Focus; the display representations are what Focus settings show.
enum FocusNotificationPolicy: String, AppEnum {
    /// All notifications for the vehicle, which clears the per-vehicle mute.
    case all
    /// The per-vehicle mute Hisingen's notification settings already use.
    case muted

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Notifications")
    static let caseDisplayRepresentations: [FocusNotificationPolicy: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "All notifications"),
        .muted: DisplayRepresentation(title: "Muted")
    ]
}

/// The concrete settings one applied filter leaves behind, resolved from the parameters
/// before anything is written. Pure so the mapping is testable without the AppIntents
/// machinery.
@MainActor
enum FocusFilterMapping {
    struct Applied: Equatable {
        let vin: String?
        let brand: VehicleBrand?
        let muted: Bool
        /// What the vehicle is called in the Focus filter's own summary.
        let vehicleName: String?
    }

    /// A blank or missing vehicle argument means the default vehicle, exactly as the
    /// Shortcuts vehicle argument behaves. A name that matches nothing resolves to no
    /// vehicle, so nothing is applied and the summary says so.
    static func resolve(
        vehicle: String?, policy: FocusNotificationPolicy, preferences: PreferencesStore
    ) -> Applied {
        let vin = AutomationHandoff.resolveVIN(from: vehicle, preferences: preferences)
        let brand = vin.map { Self.brand(of: $0, preferences: preferences) }
        let name = vin.map { Self.displayName(for: $0, preferences: preferences) }
        return Applied(vin: vin, brand: brand, muted: policy == .muted, vehicleName: name)
    }

    /// Writes what the Focus chose: the active vehicle, and the mute the Notifier already
    /// reads per VIN. Baselines keep advancing while muted, so un-muting later never
    /// replays a burst of stale edge events.
    static func apply(_ applied: Applied, to preferences: PreferencesStore) {
        if let brand = applied.brand { preferences.activeBrand = brand }
        if let vin = applied.vin { preferences.setMuted(applied.muted, for: vin) }
    }

    /// The summary Focus settings shows for this filter once it has run.
    static func displaySummary(_ applied: Applied) -> String {
        guard let vin = applied.vin else {
            return L10n.text("No vehicle in Hisingen matches that name or VIN.")
        }
        let name = applied.vehicleName ?? L10n.text("Vehicle")
        return applied.muted
            ? L10n.format("%@: notifications muted", name)
            : L10n.format("%@: notifications on", name)
    }

    private static func brand(of vin: String, preferences: PreferencesStore) -> VehicleBrand {
        if preferences.vin(for: .polestar) == vin { return .polestar }
        if preferences.vin(for: .volvo) == vin { return .volvo }
        return VehicleBrand.isVolvoVIN(vin) ? .volvo : .polestar
    }

    private static func displayName(for vin: String, preferences: PreferencesStore) -> String {
        let nickname = preferences.vehicleNickname(for: vin)
        if !nickname.isEmpty { return nickname }
        if let model = AutomationHandoff.sharedStateStore.snapshot(for: vin)?.identity.modelName {
            return model
        }
        return L10n.text("Vehicle")
    }
}

/// A macOS Focus filter. When a Focus that carries this filter turns on, Hisingen applies
/// the vehicle and notification policy that Focus was configured with; the system stores
/// the parameter values per Focus, so two Focuses can pick two different vehicles.
/// When the Focus turns off, the system does not run the intent again, so the last applied
/// choice stays until the reader or another Focus changes it.
///
/// System-wide discovery of Hisingen's AppIntents (Shortcuts, Focus configuration) is
/// currently blocked by the SwiftPM AppIntents metadata issue tracked as a separate work
/// item; this intent compiles and its mapping is unit-tested here, but it cannot be
/// picked up by the system until that metadata ships.
struct SetHisingenFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Hisingen Focus Filter"
    static let description = IntentDescription(
        "Sets the active vehicle and whether that vehicle's notifications are muted when a Focus turns on."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @Parameter(title: "Notifications", default: .all)
    var notifications: FocusNotificationPolicy

    /// What Focus settings shows for the configured filter. Built from the stored
    /// parameters only, without touching app state, so the system can read it from
    /// whatever context it holds.
    var displayRepresentation: DisplayRepresentation {
        let policy = notifications == .muted
            ? L10n.text("Muted")
            : L10n.text("All notifications")
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle and notifications")),
            subtitle: LocalizedStringResource(stringLiteral: policy)
        )
    }

    /// Hisingen mutes a vehicle's notifications itself, in the per-VIN preference the
    /// Notifier already reads, so the system-side notification predicate stays unset:
    /// Focus only needs to run `perform` to apply the app-side choice. `perform` runs
    /// when the Focus turns on; the system does not run it again when the Focus turns
    /// off, so the applied choice stays until the reader or another Focus changes it.
    @MainActor
    func perform() async throws -> some IntentResult {
        let preferences = PreferencesStore.shared
        let applied = FocusFilterMapping.resolve(
            vehicle: vehicle, policy: notifications, preferences: preferences
        )
        FocusFilterMapping.apply(applied, to: preferences)
        return .result()
    }
}
