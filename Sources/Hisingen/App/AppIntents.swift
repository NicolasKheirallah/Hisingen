import AppIntents
import AppKit
import Foundation

@MainActor
enum AutomationHandoff {
    /// Installed by `AppDelegate` once composition is complete. Shortcuts intents await
    /// this, so a shortcut that fires while the app is still launching dispatches as soon
    /// as the shell is wired – no URL round-trip, no polling the command audit table.
    private static var waiters: [UUID: CheckedContinuation<any RemoteCommandDispatching, Never>] = [:]
    private(set) static var context: (any RemoteCommandDispatching)?

    /// One store shared by every Shortcuts entry point, so per-invocation instances cannot drift
    /// on their caches while answering. It is a pure reader: the launch maintenance
    /// (`activate()`) belongs to `applicationDidFinishLaunching`, and `init` no longer runs
    /// anything that a second store instance would repeat.
    static let sharedStateStore = VehicleStateStore(database: VehicleDatabase.shared)

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

    /// Installed by `AppDelegate` next to the dispatch context. A refresh is not a remote
    /// command, so it rides its own action; a shortcut firing before composition reports
    /// that instead of awaiting a handler that would never arrive.
    static var refreshAction: (() -> Void)?

    static func installRefreshAction(_ action: @escaping () -> Void) {
        refreshAction = action
    }

    #if DEBUG
    /// Test isolation for the process-wide hub.
    static func resetForTesting() {
        context = nil
        waiters = [:]
        refreshAction = nil
    }
    #endif

    /// The one Remote Command path the Shortcuts surface uses: resolve the target vehicle,
    /// resolve it through the shell's awaited target-selection boundary, and describe the
    /// provider acknowledgement without claiming telemetry confirmation.
    static func send(_ command: RemoteCommand, vehicle: String?,
                     preferences: PreferencesStore = .shared) async -> String {
        let context = await waitForContext()
        let targetVin = resolveVIN(from: vehicle, preferences: preferences)
        let outcome = await context.perform(
            command,
            targetVIN: targetVin.isEmpty ? nil : targetVin,
            origin: .userInitiated
        )
        switch outcome {
        case .sent: return L10n.text("Command accepted; waiting for the vehicle to report the result.")
        case .deferred(let reason): return reason
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
        let store = AutomationHandoff.sharedStateStore
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
              let state = sharedStateStore.snapshot(for: vin)
        else { return nil }
        return (state, preferences)
    }
}

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
        let store = AutomationHandoff.sharedStateStore
        guard let state = store.snapshot(for: vin) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        var parts: [String] = []
        if let battery = state.energy.batteryPercentage {
            parts.append(L10n.format("%.0f%% battery", battery))
        } else if let fuel = state.fuelSystem.levelPercent {
            parts.append(L10n.format("%.0f%% fuel", fuel))
        }
        if let range = state.primaryRangeKm {
            parts.append(L10n.format("%d %@ range", preferences.distanceUnit.convert(km: range), preferences.distanceUnit.suffix))
        }
        if state.isCharging {
            if let power = state.energy.powerWatts, power > 0 {
                parts.append(L10n.format("charging at %@", Format.kilowatts(watts: power)))
            } else {
                parts.append(L10n.text("currently charging"))
            }
        }
        let summary = parts.joined(separator: ", ")
        let nick = preferences.vehicleNickname(for: vin)
        let model = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        let response = L10n.format("%@: %@.", model, summary)
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetGarageStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Garage Status"
    static let description = IntentDescription("Returns the status of all vehicles in your garage.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        let store = AutomationHandoff.sharedStateStore
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
                parts.append(L10n.format("%.0f%%", battery))
            } else if let fuel = state.fuelSystem.levelPercent {
                parts.append(L10n.format("%.0f%% fuel", fuel))
            }
            if let range = state.primaryRangeKm {
                parts.append(Format.distance(km: range, unit: preferences.distanceUnit))
            }
            if state.isCharging { parts.append(L10n.text("⚡ charging")) }
            if let locked = state.exteriorStatus?.isLocked { parts.append(locked ? L10n.text("locked") : L10n.text("unlocked")) }
            lines.append(L10n.format("%@: %@.", name, parts.joined(separator: ", ")))
        }

        if lines.isEmpty {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicles or telemetry found in your garage.")))
        }
        let response = L10n.format("%@.", lines.joined(separator: ". "))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

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

struct GetVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Status"
    static let description = IntentDescription("Returns lock, opening, and attention status from the latest Hisingen snapshot.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        var details: [String] = []
        if let locked = state.exteriorStatus?.isLocked { details.append(locked ? L10n.text("locked") : L10n.text("unlocked")) }
        if let exterior = state.exteriorStatus, !exterior.itemsNeedingAttention.isEmpty {
            details.append(exterior.itemsNeedingAttention.map(\.displayName).joined(separator: ", "))
        }
        details.append(state.stateSummary.message)
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        let response = L10n.format("%@: %@. Data %@.", name, details.joined(separator: "; "), Format.relativeAge(since: state.dataTimestamp))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

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

struct GetRecentTripsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Trip Summary"
    static let description = IntentDescription("Returns locally derived trip distance and driving time for the last seven days.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        // Push the 7-day bound into SQL instead of decoding up to 20k telemetry rows per run.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let trips = VehicleDatabase.shared.history.derivedTrips(for: state.identity.vin, limit: 1_000, since: cutoff)
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let minutes = Int(trips.reduce(0) { $0 + $1.duration } / 60)
        let response = L10n.format("Last 7 days: %d inferred trips, %@, %@ driving.",
                                   trips.count,
                                   Format.distance(km: distance, decimals: 1, unit: preferences.distanceUnit),
                                   Format.shortDuration(minutes: minutes))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

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
            return .result(value: L10n.text("unknown"),
                           dialog: IntentDialog(stringLiteral: L10n.text("No location has been reported for this vehicle yet.")))
        }
        let when = state.location?.timestamp.map { Format.relativeAge(since: $0) } ?? L10n.text("unknown time")
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        // Coordinates stay String(format:)-formatted: a localized decimal separator inside
        // a lat/lon pair would break paste-into-maps.
        let response = L10n.format("%@: %@, reported %@.",
                                   name,
                                   String(format: "%.5f, %.5f", lat, lon),
                                   when)
        let mapsURL = MapLinks.appleMapsPin(latitude: lat, longitude: lon)?.absoluteString ?? ""
        return .result(value: L10n.format("%@ Map: %@", response, mapsURL),
                       dialog: IntentDialog(stringLiteral: response))
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

struct RefreshTelemetryIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Vehicle Data"
    static let description = IntentDescription("Asks Hisingen to fetch fresh vehicle data from the provider now.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard let refresh = AutomationHandoff.refreshAction else {
            return .result(dialog: IntentDialog(stringLiteral: L10n.text("Hisingen is still launching. Try again in a moment.")))
        }
        refresh()
        return .result(dialog: IntentDialog(stringLiteral: L10n.text("Refresh requested – Hisingen is fetching the latest vehicle data.")))
    }
}

struct GetEnergyBreakdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Energy Breakdown"
    static let description = IntentDescription("Returns the vehicle's electrical energy consumption breakdown across driving, climate, and battery conditioning.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        guard let breakdown = state.energy.diagnostics?.energyBreakdown, breakdown.hasData else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("Energy breakdown data is not available for this vehicle.")))
        }
        var lines: [String] = []
        if let d = breakdown.driving, let wh = d.wattHours {
            lines.append(L10n.format("Traction: %.1f kWh", wh / 1_000))
        }
        if let c = breakdown.climate, let wh = c.wattHours {
            lines.append(L10n.format("Climate: %.1f kWh", wh / 1_000))
        }
        if let b = breakdown.battery, let wh = b.wattHours {
            lines.append(L10n.format("Battery Thermal: %.1f kWh", wh / 1_000))
        }
        if let o = breakdown.other, let wh = o.wattHours {
            lines.append(L10n.format("Electronics: %.1f kWh", wh / 1_000))
        }
        let summary = lines.isEmpty ? L10n.text("No energy consumption recorded.") : lines.joined(separator: ", ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct GetTirePressuresIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tire Pressures"
    static let description = IntentDescription("Returns the current tire pressures and statuses for all wheels.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        guard let tyres = state.maintenance.details?.tyres, !tyres.isEmpty else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("Tire status data is not available for this vehicle.")))
        }
        let lines = tyres.map { tyre -> String in
            let posName = tyre.position.displayName
            if let kpa = tyre.kilopascals {
                let targetStr = tyre.referenceKilopascals.map { " (target \(Int($0.rounded())) kPa)" } ?? ""
                return "\(posName): \(Int(kpa.rounded())) kPa\(targetStr)"
            }
            return "\(posName): \(tyre.warning.displayName)"
        }
        let summary = lines.joined(separator: "; ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

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
