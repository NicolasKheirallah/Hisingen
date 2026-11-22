import AppIntents
import Foundation

// Coverage for the commands the first wave of intents left out: the body controls, software
// updates, timers and the saved charge locations. Everything here goes through
// `AutomationHandoff.send`, so a shortcut meets the same capability gates, provider catalog and
// vehicle resolution as the Controls tab — nothing here is a second command path.

/// `HH:MM` parsed the way a person writes a time in a shortcut field. Internal so the
/// refusal path is testable: a shortcut that silently scheduled the wrong hour would be worse
/// than one that reports its own mistake.
func intentClockTime(_ text: String, name: String) throws -> (hour: Int, minute: Int) {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0...23).contains(hour), (0...59).contains(minute) else {
        throw IntentError.invalidTime(field: name, value: text)
    }
    return (hour, minute)
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidTime(field: String, value: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidTime(let field, let value):
            return "The \(field) must be written as HH:MM, for example 07:30. Received “\(value)”."
        }
    }
}

// MARK: - Tailgate

struct OpenTailgateIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Tailgate"
    static let description = IntentDescription("Opens the tailgate.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.openTailgate, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct CloseTailgateIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Tailgate"
    static let description = IntentDescription("Closes the tailgate.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.closeTailgate, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - Windows

struct OpenWindowsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Windows"
    static let description = IntentDescription("Opens the windows to the ventilation position.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.openWindows, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct CloseWindowsIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Windows"
    static let description = IntentDescription("Closes every window.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.closeWindows, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - Software updates

struct InstallSoftwareUpdateIntent: AppIntent {
    static let title: LocalizedStringResource = "Install Software Update"
    static let description = IntentDescription("Starts installing the software update the car has downloaded.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.installOTANow, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct CancelSoftwareUpdateIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Software Update"
    static let description = IntentDescription("Cancels a software update installation that has not started yet.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let result = await AutomationHandoff.send(.cancelOTA, vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - Timers

struct SetChargingTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charging Timer"
    static let description = IntentDescription("Sets the car's charging window for every day.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @Parameter(title: "Start Time", description: "When charging may begin, as HH:MM.")
    var start: String

    @Parameter(title: "Stop Time", description: "When charging must stop, as HH:MM.")
    var stop: String

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let from = try intentClockTime(start, name: "start time")
        let to = try intentClockTime(stop, name: "stop time")
        let schedule = VehicleSchedule(
            kind: .globalCharging,
            startHour: from.hour, startMinute: from.minute,
            endHour: to.hour, endMinute: to.minute,
            weekdays: [],
            isActive: true
        )
        let result = await AutomationHandoff.send(.setGlobalChargeTimer(schedule), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct SetClimateTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Climate Timer"
    static let description = IntentDescription("Sets a pre-conditioning timer for every day.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @Parameter(title: "Start Time", description: "When pre-conditioning starts, as HH:MM.")
    var start: String

    @Parameter(title: "Stop Time", description: "When pre-conditioning stops, as HH:MM.")
    var stop: String

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let from = try intentClockTime(start, name: "start time")
        let to = try intentClockTime(stop, name: "stop time")
        let schedule = VehicleSchedule(
            kind: .climate,
            startHour: from.hour, startMinute: from.minute,
            endHour: to.hour, endMinute: to.minute,
            weekdays: [],
            isActive: true
        )
        let result = await AutomationHandoff.send(.setClimateTimer(schedule), vehicle: vehicle)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - Saved charge locations

struct ListSavedChargeLocationsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Saved Charge Locations"
    static let description = IntentDescription("Returns the charge locations the car has saved.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        guard let vin = AutomationHandoff.resolveVIN(from: vehicle) else {
            let message = L10n.text("No vehicle in Hisingen matches that name or VIN.")
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        guard let state = AutomationHandoff.sharedStateStore.snapshot(for: vin) else {
            let message = L10n.text("Hisingen has no saved snapshot for that vehicle yet.")
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let locations = state.savedChargeLocations
        guard !locations.isEmpty else {
            let message = L10n.text("This vehicle has no saved charge locations.")
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let nick = preferences.vehicleNickname(for: vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? state.model.brand.displayName) : nick
        let lines = locations.map { location -> String in
            var parts = [location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias]
            if location.ampLimit > 0 { parts.append(L10n.format("%d A", location.ampLimit)) }
            if location.minimumSoc > 0 { parts.append(L10n.format("%d%% minimum", location.minimumSoc)) }
            if location.optimisedChargingEnabled { parts.append(L10n.text("Optimised charging")) }
            return parts.joined(separator: " · ")
        }
        let summary = L10n.format("%@: %@", name, lines.joined(separator: "; "))
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
