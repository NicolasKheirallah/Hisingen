import AppIntents
import Foundation

/// The widget-facing intents. They live in the shared target because the widget extension
/// cannot import the app executable: the extension names the same types the app links, and
/// `Metadata.appintents` for the extension is built from this module as a dependency.
///
/// All three set `openAppWhenRun`: the app performs them through
/// `VehicleWidgetCommandRouter`, so a button never reaches a vehicle backend from inside the
/// extension and the command takes the app's confirmation and capability gates.

struct WidgetLockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Vehicle"
    static let description = IntentDescription("Locks the vehicle doors.")
    static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .lock, vehicle: vehicle)
    }
}

struct WidgetUnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlocks the vehicle doors.")
    static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .unlock, vehicle: vehicle)
    }
}

struct WidgetStartClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Climate"
    static let description = IntentDescription("Starts cabin climate preconditioning.")
    static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .startClimate, vehicle: vehicle)
    }
}

/// Shared dialog construction for the three intents. A missing handler is the one case the
/// app cannot describe — it is not running — so that sentence is localised here and shipped
/// in the same language tables the widget reads.
@MainActor
private enum WidgetVehicleIntentDialog {
    static func result(for command: VehicleWidgetCommand,
                       vehicle: String?) async throws -> some ProvidesDialog {
        if let message = try await VehicleWidgetCommandRouter.send(command, vin: vehicle) {
            return .result(dialog: IntentDialog(stringLiteral: message))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("Open Hisingen to send this command.")))
    }
}
