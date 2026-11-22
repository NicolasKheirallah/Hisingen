import AppIntents
import Foundation

struct LockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Vehicle"
    static let description = IntentDescription("Locks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.lock, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct UnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlocks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.unlock, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct FlashLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Flash Vehicle Lights"
    static let description = IntentDescription("Flashes the headlights so the car is easier to find.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.flashLights, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct HonkAndFlashIntent: AppIntent {
    static let title: LocalizedStringResource = "Honk and Flash Vehicle"
    static let description = IntentDescription("Sounds the horn and flashes the lights together.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.honkAndFlash, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
