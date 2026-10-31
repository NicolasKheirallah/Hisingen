import AppIntents
import Foundation

struct GetChargingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Charging Status"
    static let description = IntentDescription("Returns charging state, power, target, and time remaining.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        var parts = [state.energy.chargingState.displayName]
        if let power = state.energy.powerWatts, power > 0 { parts.append(Format.kilowatts(watts: power)) }
        if let target = state.energy.targetPercentage { parts.append(L10n.format("target %d%%", target)) }
        if let minutes = state.energy.estimatedTimeToFullMinutes, minutes > 0 {
            parts.append(L10n.format("%@ remaining", Format.shortDuration(minutes: minutes)))
        }
        let response = L10n.format("%@: %@.", state.identity.modelName ?? L10n.text("Vehicle"), parts.joined(separator: ", "))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

/// Sets the active vehicle's target charge level through Hisingen's normal command path.
/// The parameter is validated by the same capability/bounds logic as the in-app slider,
/// so an out-of-range request surfaces the vehicle's own limits instead of failing blindly.
struct SetChargeTargetIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Target"
    static let description = IntentDescription("Sets the vehicle's target charge level percentage.")
    static let openAppWhenRun = false

    @Parameter(title: "Charge Target (%)", default: 80, inclusiveRange: (40, 100))
    var percent: Int

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.setChargeTarget(percent), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// The provider-side charging control is a schedule override: "start" charges now despite
/// an active schedule, and "stop" hands control back to the schedule. Without a schedule
/// active there is nothing to override, and the provider answer says so.
struct StartChargingOverrideIntent: AppIntent {
    static let title: LocalizedStringResource = "Charge Now"
    static let description = IntentDescription("Overrides the active charging schedule so the vehicle charges immediately.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.startChargingOverride, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopChargingOverrideIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Charging Schedule"
    static let description = IntentDescription("Ends a charging override so the vehicle returns to its charging schedule.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.stopChargingOverride, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// The range matches `VehicleChargeBounds.fallbackAmperageRange`; a vehicle with narrower
/// capabilities validates the request at dispatch and answers with its own limits.
struct SetAmpLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charging Current"
    static let description = IntentDescription("Sets the vehicle's charging current limit in amperes.")
    static let openAppWhenRun = false

    @Parameter(title: "Current (A)", default: 16, inclusiveRange: (6, 32))
    var amps: Int

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.setAmpLimit(amps), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
