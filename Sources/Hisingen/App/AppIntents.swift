import AppIntents
import AppKit
import Foundation

@available(macOS 13.0, *)
@MainActor
private enum AutomationHandoff {
    static func dispatch(_ route: String) -> Bool {
        guard let url = URL(string: "hisingen://\(route)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func canSendVolvoCommand(requiresRestrictedScopes: Bool = false) -> String? {
        let preferences = PreferencesStore()
        guard !preferences.vin.isEmpty else { return "No vehicle is configured in Hisingen." }
        guard preferences.activeBrand == .volvo else {
            return "This shortcut is available only for Volvo commands exposed by the official public API."
        }
        if requiresRestrictedScopes && !preferences.volvoRestrictedScopesEnabled {
            return "Enable Approved Volvo permissions in Hisingen Settings and sign in again first."
        }
        return nil
    }

    static func dispatchAndWait(
        _ route: String, command: String, timeout: TimeInterval = 45
    ) async -> String {
        let preferences = PreferencesStore()
        let vin = preferences.vin
        let startedAt = Date().addingTimeInterval(-1)
        guard dispatch(route) else { return "Hisingen could not be opened to send the request." }

        let database = VehicleDatabase()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            if let result = database.recentCommandAudits(for: vin, limit: 10).first(where: {
                $0.command == command && $0.executedAt >= startedAt
            }) {
                if result.status == "failed" {
                    return "The vehicle service rejected the request: \(result.errorMessage ?? "unknown error")"
                }
                return "Vehicle service result: \(result.status.replacingOccurrences(of: "-", with: " "))."
            }
        }
        return "The request was handed to Hisingen, but no provider result arrived before the shortcut timed out. Check Command History in Hisingen."
    }

    static func snapshot() -> (VehicleState, PreferencesStore)? {
        let preferences = PreferencesStore()
        guard !preferences.vin.isEmpty,
              let state = VehicleStateStore(database: VehicleDatabase()).snapshot(for: preferences.vin)
        else { return nil }
        return (state, preferences)
    }
}

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
        if let reason = AutomationHandoff.canSendVolvoCommand(requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("lock", command: "lock")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct UnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlocks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("unlock", command: "unlock", timeout: 60)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct StartClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Climate"
    static let description = IntentDescription("Starts cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand() {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("climate/start", command: "start-climate")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct StopClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Cabin Climate"
    static let description = IntentDescription("Stops cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand() {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("climate/stop", command: "stop-climate")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct GetVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Status"
    static let description = IntentDescription("Returns lock, opening, and attention status from the latest Hisingen snapshot.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot() else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        var details: [String] = []
        if let locked = state.exteriorStatus?.isLocked { details.append(locked ? "locked" : "unlocked") }
        if let exterior = state.exteriorStatus, !exterior.itemsNeedingAttention.isEmpty {
            details.append(exterior.itemsNeedingAttention.map(\.displayName).joined(separator: ", "))
        }
        details.append(state.stateSummary.message)
        let response = "\(state.modelName ?? "Vehicle"): \(details.joined(separator: "; ")). Data \(Format.relativeAge(since: state.dataTimestamp))."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct GetChargingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Charging Status"
    static let description = IntentDescription("Returns charging state, power, target, and time remaining.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot() else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        var parts = [state.chargingState.displayName]
        if let power = state.chargingPowerWatts, power > 0 { parts.append(Format.kilowatts(watts: power)) }
        if let target = state.chargeTargetPercentage { parts.append("target \(target)%") }
        if let minutes = state.estimatedChargingTimeToFullMinutes, minutes > 0 {
            parts.append("\(Format.shortDuration(minutes: minutes)) remaining")
        }
        let response = "\(state.modelName ?? "Vehicle"): \(parts.joined(separator: ", "))."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct GetRecentTripsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Trip Summary"
    static let description = IntentDescription("Returns locally derived trip distance and driving time for the last seven days.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot() else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let trips = VehicleDatabase().derivedTrips(for: state.vin, limit: 1_000).filter { $0.endedAt >= cutoff }
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let minutes = Int(trips.reduce(0) { $0 + $1.duration } / 60)
        let response = "Last 7 days: \(trips.count) inferred trips, \(Format.distance(km: distance, decimals: 1, unit: preferences.distanceUnit)), \(Format.shortDuration(minutes: minutes)) driving."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct FlashLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Flash Vehicle Lights"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("flash-lights", command: "flash-lights")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct HonkAndFlashIntent: AppIntent {
    static let title: LocalizedStringResource = "Honk and Flash Vehicle"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("honk-flash", command: "honk-flash")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct HisingenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetVehicleBatteryIntent(),
            phrases: [
                "Check \(.applicationName) battery",
                "What is my \(.applicationName) charge level?",
                "How much range is left in \(.applicationName)?"
            ],
            shortTitle: "Vehicle Battery",
            systemImageName: "battery.100.bolt"
        )
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: ["Lock my car with \(.applicationName)"],
            shortTitle: "Lock Vehicle",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: UnlockVehicleIntent(),
            phrases: ["Unlock my car with \(.applicationName)"],
            shortTitle: "Unlock Vehicle",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: StartClimateIntent(),
            phrases: ["Start my car climate with \(.applicationName)"],
            shortTitle: "Start Climate",
            systemImageName: "fan.fill"
        )
        AppShortcut(
            intent: StopClimateIntent(),
            phrases: ["Stop my car climate with \(.applicationName)"],
            shortTitle: "Stop Climate",
            systemImageName: "fan.slash.fill"
        )
        AppShortcut(
            intent: GetVehicleStatusIntent(),
            phrases: ["Check my vehicle with \(.applicationName)"],
            shortTitle: "Vehicle Status",
            systemImageName: "car.badge.gearshape"
        )
        AppShortcut(
            intent: GetChargingStatusIntent(),
            phrases: ["Check charging with \(.applicationName)"],
            shortTitle: "Charging Status",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: GetRecentTripsIntent(),
            phrases: ["Summarize my trips with \(.applicationName)"],
            shortTitle: "Recent Trips",
            systemImageName: "point.topleft.down.to.point.bottomright.curvepath"
        )
        AppShortcut(
            intent: FlashLightsIntent(),
            phrases: ["Flash my car lights with \(.applicationName)"],
            shortTitle: "Flash Lights",
            systemImageName: "flashlight.on.fill"
        )
        AppShortcut(
            intent: HonkAndFlashIntent(),
            phrases: ["Find my car with \(.applicationName)"],
            shortTitle: "Honk and Flash",
            systemImageName: "horn.fill"
        )
    }
}
