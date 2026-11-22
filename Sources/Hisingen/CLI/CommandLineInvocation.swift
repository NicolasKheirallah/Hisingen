import Foundation

/// What the command-line surface was asked to do.
///
/// Parsing is pure: it reads tokens and the saved climate default, never preferences, a provider
/// or the database. A malformed invocation therefore fails before any session, keychain or SQLite
/// work starts, and the parser is testable without an app.
enum CommandLineInvocation: Equatable {
    case help
    case vehicles(json: Bool, refresh: Bool)
    case send(CommandLineSendRequest, json: Bool)
}

struct CommandLineSendRequest: Equatable {
    let command: RemoteCommand
    /// The `--vin` value: a VIN, a saved nickname or a model name. Nil means the selected vehicle.
    let vehicle: String?
    /// The explicit confirmation flag. Commands the app asks about are refused without it.
    let confirmed: Bool
}

/// A command line the surface could not read. The message is printed as-is and the process exits
/// with the usage code, so a script can tell "you typed it wrong" from "the app would refuse this".
struct CommandLineUsageError: Error, Equatable {
    let message: String
}

/// The saved values a command needs at parse time. Only the climate setpoint, because an absent
/// `--temperature` takes the same default the deep link and the Controls tab take.
struct CommandLineDefaults: Equatable, Sendable {
    let climateTemperatureCelsius: Double

    static let fallback = CommandLineDefaults(climateTemperatureCelsius: 22)
}

/// How a command's own arguments are spelled, and the command the gate is asked about when the
/// surface lists what a vehicle can do. `probe` is not a second list of commands to send: the
/// listing evaluates the same `CapabilityGate` the dispatch does, and a gate question needs a
/// concrete command to ask.
struct CommandLineCommandSpec: Sendable, Equatable {
    let identifier: String
    /// Shown after the identifier in help, e.g. `[--temperature <°C>]`.
    let arguments: String
    /// Options this command reads. `--json`, `--confirm` and `--vin` are read by every command.
    let options: Set<String>
    let probe: RemoteCommand
}

enum CommandLineArguments {
    /// Values that consume the next token. Every other `--name` is a switch, so a mistyped
    /// `--confirm=true` is refused instead of silently sending an unconfirmed command.
    static let valueOptions: Set<String> = ["vin", "temperature", "amps", "soc", "start", "stop", "weekdays"]

    /// The options every command reads, handled once by `CommandLineInvocation.parse`.
    static let invocationOptions: Set<String> = ["json", "confirm", "vin", "refresh"]
}

/// One command's arguments after the identifier: bare values in order, `--name value` pairs, and
/// `--name` switches.
struct CommandLineOperands: Equatable {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var switches: Set<String> = []

    subscript(option: String) -> String? { values[option] }
    func isOn(_ option: String) -> Bool { switches.contains(option) }
}

extension CommandLineInvocation {
    /// Main-actor because the command table reads `VehicleControlSettings` and the deep-link
    /// picker lists, the same authorities the app's own surfaces read.
    @MainActor
    static func parse(
        _ arguments: [String],
        defaults: CommandLineDefaults = .fallback
    ) throws -> CommandLineInvocation {
        guard let subcommand = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "help", "--help", "-h":
            return .help

        case "vehicles", "list":
            let operands = try CommandLineOperands.parse(rest, allowing: ["json", "refresh"])
            return .vehicles(json: operands.isOn("json"), refresh: operands.isOn("refresh"))

        case "send":
            return try parseSend(rest, defaults: defaults)

        default:
            throw CommandLineUsageError(message: L10n.format("Unknown command \"%@\".", subcommand))
        }
    }

    @MainActor
    private static func parseSend(
        _ arguments: [String],
        defaults: CommandLineDefaults
    ) throws -> CommandLineInvocation {
        let parsed = try CommandLineOperands.parse(arguments, allowing: CommandLineArguments.invocationOptions.union(
            CommandLineCommandTable.specs.reduce(into: Set<String>()) { $0.formUnion($1.options) }
        ))
        guard let identifier = parsed.positionals.first else {
            throw CommandLineUsageError(message: L10n.text("Name the command to send, for example \"hisingen cli send lock\"."))
        }
        let command = try CommandLineCommandTable.command(
            identifiedBy: identifier,
            operands: CommandLineOperands(
                positionals: Array(parsed.positionals.dropFirst()),
                values: parsed.values,
                switches: parsed.switches
            ),
            defaults: defaults
        )
        return .send(
            CommandLineSendRequest(
                command: command,
                vehicle: parsed.values["vin"],
                confirmed: parsed.isOn("confirm")
            ),
            json: parsed.isOn("json")
        )
    }
}

extension CommandLineOperands {
    /// Splits tokens into positionals and options. `allowing` is every option this invocation can
    /// read anywhere, so an unknown name is refused with the whole invocation in view rather than
    /// with one command's vocabulary, which would misname a valid sibling command's option.
    static func parse(_ tokens: [String], allowing: Set<String>) throws -> CommandLineOperands {
        var operands = CommandLineOperands()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), token.count > 2 {
                let body = String(token.dropFirst(2))
                let name: String
                let inlineValue: String?
                if let separator = body.firstIndex(of: "=") {
                    name = String(body[body.startIndex..<separator])
                    inlineValue = String(body[body.index(after: separator)...])
                } else {
                    name = body
                    inlineValue = nil
                }
                guard allowing.contains(name) else {
                    throw CommandLineUsageError(message: L10n.format("Unknown option \"%@\".", "--\(name)"))
                }
                if CommandLineArguments.valueOptions.contains(name) {
                    if let inlineValue {
                        operands.values[name] = inlineValue
                    } else {
                        guard index + 1 < tokens.count else {
                            throw CommandLineUsageError(message: L10n.format("\"%@\" needs a value.", "--\(name)"))
                        }
                        index += 1
                        operands.values[name] = tokens[index]
                    }
                } else {
                    guard inlineValue == nil else {
                        throw CommandLineUsageError(message: L10n.format("\"%@\" is a switch and takes no value.", "--\(name)"))
                    }
                    operands.switches.insert(name)
                }
            } else {
                operands.positionals.append(token)
            }
            index += 1
        }
        return operands
    }
}
