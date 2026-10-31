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
        let targetVin: String?
        if vehicle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // A named vehicle that matches nothing is refused here, before any provider call.
            guard let resolved = resolveVIN(from: vehicle, preferences: preferences) else {
                return L10n.text("No vehicle in Hisingen matches that name or VIN.")
            }
            targetVin = resolved
        } else {
            targetVin = resolveVIN(from: nil, preferences: preferences)
        }
        let outcome = await context.perform(
            command,
            targetVIN: targetVin,
            origin: .userInitiated
        )
        switch outcome {
        case .sent: return L10n.text("Command accepted; waiting for the vehicle to report the result.")
        case .deferred(let reason): return reason
        case .refused(let reason): return reason
        }
    }

    static func resolveVIN(from input: String?) -> String? {
        resolveVIN(from: input, preferences: .shared)
    }

    /// Maps a Shortcuts vehicle argument to a configured VIN. No argument means the default
    /// vehicle, as before. A named argument resolves to a configured VIN or a nickname or model
    /// match, and returns nil when nothing matches. A typed VIN must have the valid VIN shape and
    /// belong to a configured or known vehicle, so an unknown VIN never reaches the provider.
    static func resolveVIN(from input: String?, preferences: PreferencesStore) -> String? {
        guard let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            let defaultVIN = preferences.vin
            return defaultVIN.isEmpty ? nil : defaultVIN
        }
        let upper = input.uppercased()
        let store = AutomationHandoff.sharedStateStore
        let brandVINs = [preferences.vin(for: .polestar), preferences.vin(for: .volvo)].filter { !$0.isEmpty }
        if SettingsValidation.isValidVIN(upper),
           brandVINs.contains(upper) || store.snapshot(for: upper) != nil {
            return upper
        }
        for vin in brandVINs {
            let nick = preferences.vehicleNickname(for: vin)
            if nick.localizedCaseInsensitiveContains(input) || vin.localizedCaseInsensitiveContains(input) {
                return vin
            }
            if let snap = store.snapshot(for: vin), snap.identity.modelName?.localizedCaseInsensitiveContains(input) == true {
                return vin
            }
        }
        return nil
    }

    static func snapshot(for input: String? = nil) -> (VehicleState, PreferencesStore)? {
        let preferences = PreferencesStore.shared
        guard let vin = resolveVIN(from: input),
              let state = sharedStateStore.snapshot(for: vin)
        else { return nil }
        return (state, preferences)
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
