import AppIntents
import AppKit
import Foundation

@available(macOS 13.0, *)
@MainActor
enum AutomationHandoff {
    /// Installed by `AppDelegate` once composition is complete. Shortcuts intents await
    /// this, so a shortcut that fires while the app is still launching dispatches as soon
    /// as the shell is wired — no URL round-trip, no polling the command audit table.
    private static var waiters: [UUID: CheckedContinuation<any RemoteCommandDispatching, Never>] = [:]
    private(set) static var context: (any RemoteCommandDispatching)?

    static func install(_ context: any RemoteCommandDispatching) {
        self.context = context
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(returning: context) }
    }

    static func waitForContext() async -> any RemoteCommandDispatching {
        if let context { return context }
        return await withCheckedContinuation { continuation in
            waiters[UUID()] = continuation
        }
    }

#if DEBUG
    /// Test isolation for the process-wide hub.
    static func resetForTesting() {
        context = nil
        waiters = [:]
    }
#endif

    /// The one Remote Command path the Shortcuts surface uses: resolve the target vehicle,
    /// select it (deep links always have, so the command runs against the car the user
    /// named), dispatch through the shell, and describe the outcome in the intent dialog.
    static func send(_ command: RemoteCommand, vehicle: String?,
                     preferences: PreferencesStore = .shared) async -> String {
        let context = await waitForContext()
        let targetVin = resolveVIN(from: vehicle, preferences: preferences)
        if !targetVin.isEmpty { context.selectVehicle(vin: targetVin) }
        let outcome = await context.perform(command, origin: .userInitiated)
        switch outcome {
        case .sent: return command.outcomeDescription
        case .refused(let reason): return reason
        }
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
            if let snap = store.snapshot(for: vin), snap.identity.modelName?.localizedCaseInsensitiveContains(input) == true {
                return vin
            }
        }
        return upper
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
        if let battery = state.energy.batteryPercentage {
            parts.append(String(format: "%.0f%% battery", battery))
        } else if let fuel = state.fuelSystem.levelPercent {
            parts.append(String(format: "%.0f%% fuel", fuel))
        }
        if let range = state.primaryRangeKm {
            parts.append(String(format: "%d %@ range", preferences.distanceUnit.convert(km: range), preferences.distanceUnit.suffix))
        }
        if state.isCharging {
            if let power = state.energy.powerWatts, power > 0 {
                parts.append("charging at \(Format.kilowatts(watts: power))")
            } else {
                parts.append("currently charging")
            }
        }
        let summary = parts.joined(separator: ", ")
        let nick = preferences.vehicleNickname(for: vin)
        let model = nick.isEmpty ? (state.identity.modelName ?? "Vehicle") : nick
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
            let name = nick.isEmpty ? (state.identity.modelName ?? state.model.brand.displayName) : nick
            var parts: [String] = []
            if let battery = state.energy.batteryPercentage {
                parts.append(String(format: "%.0f%%", battery))
            } else if let fuel = state.fuelSystem.levelPercent {
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
        let result = await AutomationHandoff.send(.lock, vehicle: vehicle)
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
        let result = await AutomationHandoff.send(.unlock, vehicle: vehicle)
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
        let result = await AutomationHandoff.send(
            .startClimate(
                temperatureCelsius: Float(PreferencesStore.shared.remoteClimateTemperature),
                frontLeftSeat: .off, frontRightSeat: .off,
                rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
            vehicle: vehicle)
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
        let result = await AutomationHandoff.send(.stopClimate, vehicle: vehicle)
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
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? "Vehicle") : nick
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
        var parts = [state.energy.chargingState.displayName]
        if let power = state.energy.powerWatts, power > 0 { parts.append(Format.kilowatts(watts: power)) }
        if let target = state.energy.targetPercentage { parts.append("target \(target)%") }
        if let minutes = state.energy.estimatedTimeToFullMinutes, minutes > 0 {
            parts.append("\(Format.shortDuration(minutes: minutes)) remaining")
        }
        let response = "\(state.identity.modelName ?? "Vehicle"): \(parts.joined(separator: ", "))."
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
        let trips = VehicleDatabase.shared.history.derivedTrips(for: state.identity.vin, limit: 1_000, since: cutoff)
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
        let result = await AutomationHandoff.send(.flashLights, vehicle: vehicle)
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
        let result = await AutomationHandoff.send(.honkAndFlash, vehicle: vehicle)
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
        let result = await AutomationHandoff.send(.setChargeTarget(percent), vehicle: vehicle)
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
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? "Vehicle") : nick
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
