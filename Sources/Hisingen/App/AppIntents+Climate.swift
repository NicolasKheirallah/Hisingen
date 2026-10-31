import AppIntents
import Foundation

struct StartClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Climate"
    static let description = IntentDescription("Starts cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        // Seat levels mirror the in-app and calendar-automation climate paths, which all
        // start from the user's saved remote-seat-heating preferences.
        let preferences = PreferencesStore.shared
        let result = await AutomationHandoff.send(
            .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: preferences.remoteDriverSeatHeating,
                frontRightSeat: preferences.remoteFrontRightSeatHeating,
                rearLeftSeat: preferences.remoteRearLeftSeatHeating,
                rearRightSeat: preferences.remoteRearRightSeatHeating,
                steeringWheel: preferences.remoteSteeringWheelHeating),
            vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Cabin Climate"
    static let description = IntentDescription("Stops cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.stopClimate, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// Pre-cleaning purifies the cabin air before departure. Dispatch runs through the normal
/// command path, so a vehicle without the pre-cleaning capability answers with the same
/// refusal the in-app control gets.
struct StartPreCleaningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Pre-Cleaning"
    static let description = IntentDescription("Starts the cabin pre-cleaning cycle that purifies the interior air before departure.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.startPreCleaning, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopPreCleaningIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Cabin Pre-Cleaning"
    static let description = IntentDescription("Stops a running cabin pre-cleaning cycle.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.stopPreCleaning, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// Remote engine start is the one command family only combustion and hybrid Volvos offer;
/// the runtime choices mirror the Controls tab picker.
struct StartEngineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Engine"
    static let description = IntentDescription("Starts the combustion engine to precondition the cabin (Volvo vehicles with engine start support).")
    static let openAppWhenRun = false

    @Parameter(title: "Runtime (minutes)", default: 15, inclusiveRange: (5, 15))
    var minutes: Int

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.startEngine(runtimeMinutes: minutes), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopEngineIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Engine"
    static let description = IntentDescription("Stops a remotely started combustion engine.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.stopEngine, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
