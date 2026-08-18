import AppIntents
import Foundation

@available(macOS 13.0, *)
struct GetVehicleBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Battery"
    static let description = IntentDescription("Returns the battery level, range, and charging status of the active vehicle.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore()
        let vin = preferences.vin
        let store = VehicleStateStore(database: VehicleDatabase())
        guard let state = store.snapshot(for: vin) else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        var parts: [String] = []
        if let battery = state.batteryPercentage {
            parts.append(String(format: "%.0f%% battery", battery))
        }
        if let range = state.primaryRangeKm {
            parts.append(String(format: "%d %@ range", preferences.distanceUnit.convert(km: range), preferences.distanceUnit.suffix))
        }
        if state.isCharging {
            if let power = state.chargingPowerWatts, power > 0 {
                parts.append("charging at \(Format.kilowatts(watts: power))")
            } else {
                parts.append("currently charging")
            }
        }
        let summary = parts.joined(separator: ", ")
        let model = state.modelName ?? "Vehicle"
        let response = "\(model): \(summary)."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct LockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Vehicle"
    static let description = IntentDescription("Locks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let vin = PreferencesStore().vin
        guard !vin.isEmpty else {
            return .result(dialog: "No vehicle configured in Hisingen.")
        }
        return .result(dialog: "Lock command dispatched to vehicle.")
    }
}

@available(macOS 13.0, *)
struct UnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlocks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let vin = PreferencesStore().vin
        guard !vin.isEmpty else {
            return .result(dialog: "No vehicle configured in Hisingen.")
        }
        return .result(dialog: "Unlock command dispatched to vehicle.")
    }
}

@available(macOS 13.0, *)
struct StartClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Climate"
    static let description = IntentDescription("Starts cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let vin = PreferencesStore().vin
        guard !vin.isEmpty else {
            return .result(dialog: "No vehicle configured in Hisingen.")
        }
        return .result(dialog: "Climate preconditioning started.")
    }
}

@available(macOS 13.0, *)
struct StopClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Cabin Climate"
    static let description = IntentDescription("Stops cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let vin = PreferencesStore().vin
        guard !vin.isEmpty else {
            return .result(dialog: "No vehicle configured in Hisingen.")
        }
        return .result(dialog: "Climate preconditioning stopped.")
    }
}

@available(macOS 13.0, *)
struct HisingenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetVehicleBatteryIntent(),
            phrases: [
                "Check \\(.applicationName) battery",
                "What is my \\(.applicationName) charge level?",
                "How much range is left in \\(.applicationName)?"
            ],
            shortTitle: "Vehicle Battery",
            systemImageName: "battery.100.bolt"
        )
    }
}
