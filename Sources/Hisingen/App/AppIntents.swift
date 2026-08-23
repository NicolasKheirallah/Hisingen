import AppIntents
import AppKit
import Foundation

@available(macOS 13.0, *)
@MainActor
enum AutomationHandoff {
    static func dispatch(_ route: String) -> Bool {
        guard let url = URL(string: "hisingen://\(route)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func resolveVIN(from input: String?) -> String {
        resolveVIN(from: input, preferences: .shared)
    }

    static func resolveVIN(from input: String?, preferences: PreferencesStore) -> String {
        guard let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            return preferences.vin
        }
        let upper = input.uppercased()
        let store = VehicleStateStore(database: VehicleDatabase.shared)
        if store.snapshot(for: upper) != nil {
            return upper
        }
        for vin in [preferences.vin(for: .polestar), preferences.vin(for: .volvo)] where !vin.isEmpty {
            let nick = preferences.vehicleNickname(for: vin)
            if nick.localizedCaseInsensitiveContains(input) || vin.localizedCaseInsensitiveContains(input) {
                return vin
            }
            if let snap = store.snapshot(for: vin), snap.modelName?.localizedCaseInsensitiveContains(input) == true {
                return vin
            }
        }
        return upper
    }

    static func canSendVolvoCommand(for input: String? = nil, requiresRestrictedScopes: Bool = false) -> String? {
        let preferences = PreferencesStore.shared
        let targetVin = resolveVIN(from: input)
        guard !targetVin.isEmpty else { return "No vehicle is configured in Hisingen." }
        let isVolvo = targetVin.hasPrefix("YV") || preferences.activeBrand == .volvo
        guard isVolvo else {
            return "This shortcut is available only for Volvo commands exposed by the official public API."
        }
        if requiresRestrictedScopes && !preferences.volvoRestrictedScopesEnabled {
            return "Enable Approved Volvo permissions in Hisingen Settings and sign in again first."
        }
        return nil
    }

    static func dispatchAndWait(
        _ route: String, command: String, vin: String? = nil, timeout: TimeInterval = 45
    ) async -> String {
        let targetVin = resolveVIN(from: vin)
        let preferences = PreferencesStore.shared
        let effectiveVin = targetVin.isEmpty ? preferences.vin : targetVin
        let routeWithVin: String
        if !targetVin.isEmpty {
            routeWithVin = route.contains("?") ? "\(route)&vin=\(targetVin)" : "\(route)?vin=\(targetVin)"
        } else {
            routeWithVin = route
        }
        let startedAt = Date().addingTimeInterval(-1)
        guard dispatch(routeWithVin) else { return "Hisingen could not be opened to send the request." }

        let database = VehicleDatabase.shared
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            if let result = database.recentCommandAudits(for: effectiveVin, limit: 10).first(where: {
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

    static func snapshot(for input: String? = nil) -> (VehicleState, PreferencesStore)? {
        let preferences = PreferencesStore.shared
        let vin = resolveVIN(from: input)
        guard !vin.isEmpty,
              let state = VehicleStateStore(database: VehicleDatabase.shared).snapshot(for: vin)
        else { return nil }
        return (state, preferences)
    }
}

@available(macOS 13.0, *)
struct GetVehicleBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Battery"
    static let description = IntentDescription("Returns the battery level, range, and charging status of a vehicle.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        let vin = AutomationHandoff.resolveVIN(from: vehicle)
        let store = VehicleStateStore(database: VehicleDatabase.shared)
        guard let state = store.snapshot(for: vin) else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        var parts: [String] = []
        if let battery = state.batteryPercentage {
            parts.append(String(format: "%.0f%% battery", battery))
        } else if let fuel = state.fuelLevelPercent {
            parts.append(String(format: "%.0f%% fuel", fuel))
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
        let nick = preferences.vehicleNickname(for: vin)
        let model = nick.isEmpty ? (state.modelName ?? "Vehicle") : nick
        let response = "\(model): \(summary)."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct GetGarageStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Garage Status"
    static let description = IntentDescription("Returns the status of all vehicles in your garage.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        let store = VehicleStateStore(database: VehicleDatabase.shared)
        var knownVINs: [String] = []
        for brand in VehicleBrand.allCases {
            let vin = preferences.vin(for: brand)
            if !vin.isEmpty && !knownVINs.contains(vin) { knownVINs.append(vin) }
        }
        if knownVINs.isEmpty && !preferences.vin.isEmpty { knownVINs.append(preferences.vin) }

        var lines: [String] = []
        for vin in knownVINs {
            guard let state = store.snapshot(for: vin) else { continue }
            let nick = preferences.vehicleNickname(for: vin)
            let name = nick.isEmpty ? (state.modelName ?? state.model.brand.displayName) : nick
            var parts: [String] = []
            if let battery = state.batteryPercentage {
                parts.append(String(format: "%.0f%%", battery))
            } else if let fuel = state.fuelLevelPercent {
                parts.append(String(format: "%.0f%% fuel", fuel))
            }
            if let range = state.primaryRangeKm {
                parts.append(Format.distance(km: range, unit: preferences.distanceUnit))
            }
            if state.isCharging { parts.append("⚡ charging") }
            if let locked = state.exteriorStatus?.isLocked { parts.append(locked ? "locked" : "unlocked") }
            lines.append("\(name): \(parts.joined(separator: ", "))")
        }

        if lines.isEmpty {
            return .result(value: "--", dialog: "No vehicles or telemetry found in your garage.")
        }
        let response = lines.joined(separator: ". ") + "."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct LockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Vehicle"
    static let description = IntentDescription("Locks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle, requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("lock", command: "lock", vin: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct UnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlocks the vehicle doors.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle, requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("unlock", command: "unlock", vin: vehicle, timeout: 60)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct StartClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cabin Climate"
    static let description = IntentDescription("Starts cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("climate/start", command: "start-climate", vin: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct StopClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Cabin Climate"
    static let description = IntentDescription("Stops cabin climate preconditioning.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("climate/stop", command: "stop-climate", vin: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct GetVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Status"
    static let description = IntentDescription("Returns lock, opening, and attention status from the latest Hisingen snapshot.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        var details: [String] = []
        if let locked = state.exteriorStatus?.isLocked { details.append(locked ? "locked" : "unlocked") }
        if let exterior = state.exteriorStatus, !exterior.itemsNeedingAttention.isEmpty {
            details.append(exterior.itemsNeedingAttention.map(\.displayName).joined(separator: ", "))
        }
        details.append(state.stateSummary.message)
        let nick = preferences.vehicleNickname(for: state.vin)
        let name = nick.isEmpty ? (state.modelName ?? "Vehicle") : nick
        let response = "\(name): \(details.joined(separator: "; ")). Data \(Format.relativeAge(since: state.dataTimestamp))."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

@available(macOS 13.0, *)
struct GetChargingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Charging Status"
    static let description = IntentDescription("Returns charging state, power, target, and time remaining.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
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

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: "No vehicle telemetry available in Hisingen.")
        }
        // Push the 7-day bound into SQL instead of decoding up to 20k telemetry rows per run.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let trips = VehicleDatabase.shared.derivedTrips(for: state.vin, limit: 1_000, since: cutoff)
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

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle, requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("flash-lights", command: "flash-lights", vin: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

@available(macOS 13.0, *)
struct HonkAndFlashIntent: AppIntent {
    static let title: LocalizedStringResource = "Honk and Flash Vehicle"
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor func perform() async throws -> some ProvidesDialog {
        if let reason = AutomationHandoff.canSendVolvoCommand(for: vehicle, requiresRestrictedScopes: true) {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        let result = await AutomationHandoff.dispatchAndWait("honk-flash", command: "honk-flash", vin: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// Sets the active vehicle's target charge level through Hisingen's normal command path.
/// The parameter is validated by the same capability/bounds logic as the in-app slider,
/// so an out-of-range request surfaces the vehicle's own limits instead of failing blindly.
@available(macOS 13.0, *)
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
        let result = await AutomationHandoff.dispatchAndWait(
            "charge-target/\(percent)", command: "set-charge-target", vin: vehicle, timeout: 60
        )
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

/// Returns where the vehicle was last reported, with a one-tap map link in Shortcuts output.
/// Uses only the locally cached snapshot; it never wakes the car or hits the location API,
/// so running it repeatedly costs nothing and reveals nothing fresher than Hisingen holds.
@available(macOS 13.0, *)
struct WhereIsMyCarIntent: AppIntent {
    static let title: LocalizedStringResource = "Where Is My Car"
    static let description = IntentDescription("Returns the last reported parking position of the active vehicle.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle),
              let lat = state.location?.latitude, let lon = state.location?.longitude else {
            return .result(value: "unknown",
                           dialog: "No location has been reported for this vehicle yet.")
        }
        let when = state.location?.timestamp.map { Format.relativeAge(since: $0) } ?? "unknown time"
        let nick = preferences.vehicleNickname(for: state.vin)
        let name = nick.isEmpty ? (state.modelName ?? "Vehicle") : nick
        let response = "\(name): \(String(format: "%.5f, %.5f", lat, lon)), reported \(when)."
        let mapsURL = MapLinks.appleMapsPin(latitude: lat, longitude: lon)?.absoluteString ?? ""
        return .result(value: "\(response) Map: \(mapsURL)",
                       dialog: IntentDialog(stringLiteral: response))
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
