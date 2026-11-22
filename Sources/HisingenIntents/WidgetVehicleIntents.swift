import AppIntents
import Foundation

/// The widget-facing intents. They live in the shared target because the widget extension
/// cannot import the app executable: the extension names the same types the app links, and
/// `Metadata.appintents` for the extension is built from this module as a dependency.
///
/// All four set `openAppWhenRun`: the app performs them through
/// `VehicleWidgetCommandRouter`, so a button never reaches a vehicle backend from inside the
/// extension and the command takes the app's confirmation and capability gates.

public struct WidgetLockVehicleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Lock Vehicle"
    public static let description = IntentDescription("Locks the vehicle doors.")
    public static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    public var vehicle: String?

    public init() {
        self.vehicle = nil
    }

    public init(vehicle: String?) {
        self.vehicle = vehicle
    }

    @MainActor
    public func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .lock, vehicle: vehicle)
    }
}

public struct WidgetUnlockVehicleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Unlock Vehicle"
    public static let description = IntentDescription("Unlocks the vehicle doors.")
    public static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    public var vehicle: String?

    public init() {
        self.vehicle = nil
    }

    public init(vehicle: String?) {
        self.vehicle = vehicle
    }

    @MainActor
    public func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .unlock, vehicle: vehicle)
    }
}

public struct WidgetStartClimateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Cabin Climate"
    public static let description = IntentDescription("Starts cabin climate preconditioning.")
    public static let openAppWhenRun = true

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    public var vehicle: String?

    public init() {
        self.vehicle = nil
    }

    public init(vehicle: String?) {
        self.vehicle = vehicle
    }

    @MainActor
    public func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .startClimate, vehicle: vehicle)
    }
}

/// Refresh has no vehicle parameter: the app refreshes the car its panel is showing, the same
/// action the panel's refresh command and the Shortcuts intent use.
public struct WidgetRefreshVehicleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Refresh Vehicle Data"
    public static let description = IntentDescription("Asks Hisingen to fetch fresh vehicle data from the provider now.")
    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some ProvidesDialog {
        try await WidgetVehicleIntentDialog.result(for: .refresh, vehicle: nil)
    }
}

/// Shared dialog construction for the four intents. A missing handler is the one case the
/// app cannot describe (it is not running), so that sentence is localised here and shipped in
/// the same language tables the widget reads.
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
