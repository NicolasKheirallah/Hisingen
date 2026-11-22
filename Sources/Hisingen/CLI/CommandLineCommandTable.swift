import Foundation

/// Every Remote Command the command line can send, how its arguments are spelled, and how those
/// arguments become the `RemoteCommand` value the app's gate and coordinator already take.
///
/// There is deliberately no dispatch logic here: each entry only builds the same value a Controls
/// button, a deep link or a Shortcut builds. Everything after that — the capability gate,
/// confirmation, the provider call, the audit row, the receipt — is the app's own code.
///
/// Identifiers are `RemoteCommand.identifier`, the string the audit table and the command receipts
/// already record, so the command line, the history and the receipts name a command the same way.
/// `CommandLineCommandTableTests` fails if this table and `RemoteCommand`'s own identifiers drift
/// apart, in either direction.
enum CommandLineCommandTable {
    static let specs: [CommandLineCommandSpec] = [
        CommandLineCommandSpec(identifier: "start-climate", arguments: "[--temperature <°C>]", options: ["temperature"],
                               probe: climate(22)),
        CommandLineCommandSpec(identifier: "stop-climate", arguments: "", options: [], probe: .stopClimate),
        CommandLineCommandSpec(identifier: "start-precleaning", arguments: "", options: [], probe: .startPreCleaning),
        CommandLineCommandSpec(identifier: "stop-precleaning", arguments: "", options: [], probe: .stopPreCleaning),
        CommandLineCommandSpec(identifier: "lock", arguments: "", options: [], probe: .lock),
        CommandLineCommandSpec(identifier: "lock-reduced-guard", arguments: "", options: [], probe: .lockReducedGuard),
        CommandLineCommandSpec(identifier: "unlock", arguments: "", options: [], probe: .unlock),
        CommandLineCommandSpec(identifier: "unlock-trunk", arguments: "", options: [], probe: .unlockTrunk),
        CommandLineCommandSpec(identifier: "open-tailgate", arguments: "", options: [], probe: .openTailgate),
        CommandLineCommandSpec(identifier: "close-tailgate", arguments: "", options: [], probe: .closeTailgate),
        CommandLineCommandSpec(identifier: "open-windows", arguments: "", options: [], probe: .openWindows),
        CommandLineCommandSpec(identifier: "close-windows", arguments: "", options: [], probe: .closeWindows),
        CommandLineCommandSpec(identifier: "flash-lights", arguments: "", options: [], probe: .flashLights),
        CommandLineCommandSpec(identifier: "honk-flash", arguments: "", options: [], probe: .honkAndFlash),
        CommandLineCommandSpec(identifier: "honk-horn", arguments: "", options: [], probe: .honkHorn),
        CommandLineCommandSpec(identifier: "set-charge-target", arguments: "<percent>", options: [],
                               probe: .setChargeTarget(80)),
        CommandLineCommandSpec(identifier: "set-amp-limit", arguments: "<amps>", options: [],
                               probe: .setAmpLimit(16)),
        CommandLineCommandSpec(identifier: "start-charge-override", arguments: "", options: [],
                               probe: .startChargingOverride),
        CommandLineCommandSpec(identifier: "stop-charge-override", arguments: "", options: [],
                               probe: .stopChargingOverride),
        CommandLineCommandSpec(identifier: "set-charge-timer",
                               arguments: "--start <HH:MM> --stop <HH:MM> [--weekdays mon,tue] [--inactive]",
                               options: ["start", "stop", "weekdays", "inactive"],
                               probe: .setGlobalChargeTimer(daySchedule(kind: .globalCharging))),
        CommandLineCommandSpec(identifier: "set-climate-timer",
                               arguments: "--start <HH:MM> --stop <HH:MM> [--weekdays mon,tue] [--inactive]",
                               options: ["start", "stop", "weekdays", "inactive"],
                               probe: .setClimateTimer(daySchedule(kind: .climate))),
        CommandLineCommandSpec(identifier: "delete-climate-timer", arguments: "<id>", options: [],
                               probe: .deleteClimateTimer(id: "0")),
        CommandLineCommandSpec(identifier: "schedule-ota", arguments: "<minutes>", options: [],
                               probe: .scheduleOTA(delayMinutes: 120)),
        CommandLineCommandSpec(identifier: "install-ota", arguments: "", options: [], probe: .installOTANow),
        CommandLineCommandSpec(identifier: "cancel-ota", arguments: "", options: [], probe: .cancelOTA),
        CommandLineCommandSpec(identifier: "create-charge-location",
                               arguments: "<name> [--amps <amps>] [--soc <percent>] [--no-optimised]",
                               options: ["amps", "soc", "no-optimised"],
                               probe: .createChargeLocationAtCar(alias: "Home", ampLimit: 16, minimumSoc: 40,
                                                                optimisedCharging: true)),
        CommandLineCommandSpec(identifier: "rename-charge-location", arguments: "<id> <name>", options: [],
                               probe: .updateChargeLocationAlias(id: "0", alias: "Home")),
        CommandLineCommandSpec(identifier: "set-location-amp-limit", arguments: "<id> <amps>", options: [],
                               probe: .updateChargeLocationAmpLimit(id: "0", amps: 16)),
        CommandLineCommandSpec(identifier: "set-location-min-soc", arguments: "<id> <percent>", options: [],
                               probe: .updateChargeLocationMinimumSoc(id: "0", soc: 40)),
        CommandLineCommandSpec(identifier: "set-location-optimised-charging", arguments: "<id> [--off]",
                               options: ["off"],
                               probe: .setChargeLocationOptimisedCharging(id: "0", enabled: true)),
        CommandLineCommandSpec(identifier: "delete-charge-location", arguments: "<id>", options: [],
                               probe: .deleteChargeLocation(id: "0")),
        CommandLineCommandSpec(identifier: "start-engine", arguments: "<minutes>", options: [],
                               probe: .startEngine(runtimeMinutes: 10)),
        CommandLineCommandSpec(identifier: "stop-engine", arguments: "", options: [], probe: .stopEngine),
    ]

    static func spec(for identifier: String) -> CommandLineCommandSpec? {
        specs.first { $0.identifier == identifier }
    }

    /// Builds the command a `send` asked for, refusing anything the app's own surfaces cannot
    /// express: an unknown command, an option this command does not read, a missing or surplus
    /// value, or a number outside the range the Controls tab's pickers cover.
    @MainActor
    static func command(
        identifiedBy identifier: String,
        operands: CommandLineOperands,
        defaults: CommandLineDefaults
    ) throws -> RemoteCommand {
        guard let spec = spec(for: identifier) else {
            throw CommandLineUsageError(message: L10n.format("Unknown command \"%@\".", identifier))
        }
        let invocationOptions = CommandLineArguments.invocationOptions
        let accepted = spec.options.union(invocationOptions)
        for name in operands.values.keys.sorted() where !accepted.contains(name) {
            throw rejection(of: name, by: spec)
        }
        for name in operands.switches.sorted() where !accepted.contains(name) {
            throw rejection(of: name, by: spec)
        }

        func bare(_ count: Int) throws {
            guard operands.positionals.count == count else {
                throw CommandLineUsageError(
                    message: L10n.format("\"%@\" takes a different number of values.", identifier))
            }
        }
        func value(_ index: Int, _ option: String) throws -> String {
            guard index < operands.positionals.count, !operands.positionals[index].isEmpty else {
                throw CommandLineUsageError(
                    message: L10n.format("\"%@\" needs a value.", "--\(option)"))
            }
            return operands.positionals[index]
        }
        func integer(_ index: Int, _ option: String) throws -> Int {
            let text = try value(index, option)
            guard let number = Int(text) else {
                throw CommandLineUsageError(
                    message: L10n.format("\"%@\" is not a valid value.", text))
            }
            return number
        }
        func optionInteger(_ option: String, fallback: Int) throws -> Int {
            guard let text = operands[option] else { return fallback }
            guard let number = Int(text) else {
                throw CommandLineUsageError(message: L10n.format("\"%@\" is not a valid value.", text))
            }
            return number
        }
        func percent(_ value: Int) throws -> Int {
            let range = VehicleChargeBounds.fallbackTargetRange
            guard range.contains(value) else {
                throw CommandLineUsageError(
                    message: L10n.format("The charge level must be between %d%% and %d%%.", range.lowerBound,
                                         range.upperBound))
            }
            return value
        }
        func amps(_ value: Int) throws -> Int {
            let range = VehicleChargeBounds.fallbackAmperageRange
            guard range.contains(value) else {
                throw CommandLineUsageError(
                    message: L10n.format("The charging current must be between %d A and %d A on this vehicle.",
                                         range.lowerBound, range.upperBound))
            }
            return value
        }

        switch identifier {
        case "start-climate":
            try bare(0)
            return climate(try climateTemperature(operands, defaults: defaults))
        case "stop-climate": try bare(0); return .stopClimate
        case "start-precleaning": try bare(0); return .startPreCleaning
        case "stop-precleaning": try bare(0); return .stopPreCleaning
        case "lock": try bare(0); return .lock
        case "lock-reduced-guard": try bare(0); return .lockReducedGuard
        case "unlock": try bare(0); return .unlock
        case "unlock-trunk": try bare(0); return .unlockTrunk
        case "open-tailgate": try bare(0); return .openTailgate
        case "close-tailgate": try bare(0); return .closeTailgate
        case "open-windows": try bare(0); return .openWindows
        case "close-windows": try bare(0); return .closeWindows
        case "flash-lights": try bare(0); return .flashLights
        case "honk-flash": try bare(0); return .honkAndFlash
        case "honk-horn": try bare(0); return .honkHorn
        case "set-charge-target":
            try bare(1)
            return .setChargeTarget(try percent(try integer(0, "percent")))
        case "set-amp-limit":
            try bare(1)
            return .setAmpLimit(try amps(try integer(0, "amps")))
        case "start-charge-override": try bare(0); return .startChargingOverride
        case "stop-charge-override": try bare(0); return .stopChargingOverride
        case "set-charge-timer":
            try bare(0)
            return .setGlobalChargeTimer(try schedule(kind: .globalCharging, operands: operands))
        case "set-climate-timer":
            try bare(0)
            return .setClimateTimer(try schedule(kind: .climate, operands: operands))
        case "delete-climate-timer":
            try bare(1)
            return .deleteClimateTimer(id: try value(0, "id"))
        case "schedule-ota":
            try bare(1)
            let minutes = try integer(0, "minutes")
            let delays = URLCommandRouter.otaScheduleDelayMinutes
            guard delays.contains(minutes) else {
                throw CommandLineUsageError(
                    message: L10n.text("Choose a delay of 120, 480 or 720 minutes."))
            }
            return .scheduleOTA(delayMinutes: minutes)
        case "install-ota": try bare(0); return .installOTANow
        case "cancel-ota": try bare(0); return .cancelOTA
        case "create-charge-location":
            try bare(1)
            return .createChargeLocationAtCar(
                alias: try value(0, "name"),
                ampLimit: try amps(try optionInteger("amps", fallback: VehicleChargeBounds.fallbackAmperageRange.lowerBound)),
                minimumSoc: try percent(try optionInteger("soc", fallback: VehicleChargeBounds.fallbackTargetRange.lowerBound)),
                optimisedCharging: !operands.isOn("no-optimised"))
        case "rename-charge-location":
            try bare(2)
            return .updateChargeLocationAlias(id: try value(0, "id"), alias: try value(1, "name"))
        case "set-location-amp-limit":
            try bare(2)
            return .updateChargeLocationAmpLimit(id: try value(0, "id"), amps: try amps(try integer(1, "amps")))
        case "set-location-min-soc":
            try bare(2)
            return .updateChargeLocationMinimumSoc(id: try value(0, "id"),
                                                   soc: try percent(try integer(1, "percent")))
        case "set-location-optimised-charging":
            try bare(1)
            return .setChargeLocationOptimisedCharging(id: try value(0, "id"), enabled: !operands.isOn("off"))
        case "delete-charge-location":
            try bare(1)
            return .deleteChargeLocation(id: try value(0, "id"))
        case "start-engine":
            try bare(1)
            let minutes = try integer(0, "minutes")
            let runtimes = URLCommandRouter.engineRuntimeMinutes
            guard runtimes.contains(minutes) else {
                throw CommandLineUsageError(message: L10n.text("Engine runtime must be 5, 10 or 15 minutes."))
            }
            return .startEngine(runtimeMinutes: minutes)
        case "stop-engine": try bare(0); return .stopEngine
        default:
            // Unreachable while `specs` and this switch agree; `CommandLineCommandTableTests`
            // pins that they do.
            throw CommandLineUsageError(message: L10n.format("Unknown command \"%@\".", identifier))
        }
    }

    private static func rejection(of option: String, by spec: CommandLineCommandSpec) -> CommandLineUsageError {
        CommandLineUsageError(
            message: L10n.format("\"%@\" is not an option of \"%@\".", "--\(option)", spec.identifier))
    }

    /// The climate setpoint, clamped to the range the app's own slider covers. Non-finite input is
    /// refused rather than clamped: `--temperature nan` is a typo, not a request.
    private static func climateTemperature(
        _ operands: CommandLineOperands,
        defaults: CommandLineDefaults
    ) throws -> Double {
        guard let text = operands["temperature"] else { return defaults.climateTemperatureCelsius }
        guard let requested = Double(text), requested.isFinite else {
            throw CommandLineUsageError(message: L10n.format("\"%@\" is not a valid value.", text))
        }
        let range = VehicleControlSettings().temperatureRange
        return min(max(requested, Double(range.lowerBound)), Double(range.upperBound))
    }

    private static func climate(_ temperature: Double) -> RemoteCommand {
        .startClimate(
            temperatureCelsius: Float(temperature),
            frontLeftSeat: .off, frontRightSeat: .off,
            rearLeftSeat: .off, rearRightSeat: .off,
            steeringWheel: .off)
    }

    private static func daySchedule(kind: ScheduleKind) -> VehicleSchedule {
        VehicleSchedule(kind: kind, startHour: 7, startMinute: 0, endHour: 17, endMinute: 0,
                        weekdays: [], isActive: true)
    }

    /// The timer syntax is the deep link's, parsed by the deep link's own parser: `--start`/
    /// `--stop`/`--weekdays` are handed over as the query items `hisingen://charge-timer/set`
    /// carries, so a timer written by hand and one typed at the terminal cannot mean two things.
    @MainActor
    private static func schedule(kind: ScheduleKind, operands: CommandLineOperands) throws -> VehicleSchedule {
        var items: [URLQueryItem] = []
        for name in ["start", "stop", "weekdays"] {
            if let value = operands[name] { items.append(URLQueryItem(name: name, value: value)) }
        }
        if operands.isOn("inactive") { items.append(URLQueryItem(name: "active", value: "0")) }
        guard let schedule = URLCommandRouter.schedule(kind: kind, from: items) else {
            throw CommandLineUsageError(
                message: L10n.text("A timer needs --start and --stop times, for example --start 07:30 --stop 17:00."))
        }
        return schedule
    }
}
