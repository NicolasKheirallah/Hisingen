import AppIntents
import Foundation

struct StartClimateIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Start Cabin Climate")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Starts cabin climate preconditioning.")))
    }
    static let openAppWhenRun: Bool = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
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
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Stop Cabin Climate")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Stops cabin climate preconditioning.")))
    }
    static let openAppWhenRun: Bool = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
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
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Start Cabin Pre-Cleaning")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Starts the cabin pre-cleaning cycle that purifies the interior air before departure.")))
    }
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.startPreCleaning, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopPreCleaningIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Stop Cabin Pre-Cleaning")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Stops a running cabin pre-cleaning cycle.")))
    }
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
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
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Start Engine")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Starts the combustion engine to precondition the cabin (Volvo vehicles with engine start support).")))
    }
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Runtime (minutes)")),
               description: LocalizedStringResource(stringLiteral: L10n.text("How long the engine runs, between 5 and 15 minutes.")),
               default: 15, inclusiveRange: (5, 15))
    var minutes: Int

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.startEngine(runtimeMinutes: minutes), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopEngineIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Stop Engine")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Stops a remotely started combustion engine.")))
    }
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.stopEngine, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
