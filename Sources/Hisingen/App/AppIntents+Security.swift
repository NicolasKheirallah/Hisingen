import AppIntents
import Foundation

struct LockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Lock Vehicle")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Locks the vehicle doors.")))
    }
    static let openAppWhenRun: Bool = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.lock, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct UnlockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Unlock Vehicle")) }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource(stringLiteral: L10n.text("Unlocks the vehicle doors.")))
    }
    static let openAppWhenRun: Bool = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.unlock, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct FlashLightsIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Flash Vehicle Lights")) }
    static let description = IntentDescription("Flashes the headlights so the car is easier to find.")
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.flashLights, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct HonkAndFlashIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource(stringLiteral: L10n.text("Honk and Flash Vehicle")) }
    static let description = IntentDescription("Sounds the horn and flashes the lights together.")
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource(stringLiteral: L10n.text("Vehicle")),
               description: LocalizedStringResource(stringLiteral: L10n.text("Vehicle nickname or VIN (optional)")))
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.honkAndFlash, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
