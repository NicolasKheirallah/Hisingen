import Foundation

/// What the surface asks the app for. Two narrow protocols, so the runner — argument parsing,
/// output, exit codes — is exercised by tests with no provider, keychain or database in sight.
@MainActor
protocol CommandLineVehicleDirectory {
    func vehicles(refresh: Bool) async -> CommandLineVehicleListReport
}

@MainActor
protocol CommandLineCommandSending {
    func send(_ request: CommandLineSendRequest) async throws -> CommandLineSendReport
}

/// Executes one parsed invocation and answers the exit code the process will exit with.
///
/// The runner holds no policy: a refusal's sentence arrives in the report, which the app's own
/// coordinator produced. Its one decision is which stream to print on and which code to exit with.
@MainActor
struct CommandLineRunner {
    let directory: any CommandLineVehicleDirectory
    let sender: any CommandLineCommandSending
    let output: CommandLineOutput

    func run(_ invocation: CommandLineInvocation) async -> Int32 {
        switch invocation {
        case .help:
            output.write(CommandLineHelp.text)
            return CommandLineExit.success.rawValue

        case .vehicles(let json, let refresh):
            let report = await directory.vehicles(refresh: refresh)
            output.write(report, json: json)
            return CommandLineExit.success.rawValue

        case .send(let request, let json):
            do {
                let report = try await sender.send(request)
                output.write(report, json: json)
                return CommandLineExit.exitCode(for: report.status)
            } catch let error as CommandLineUsageError {
                output.writeError(error.message)
                output.writeError(CommandLineHelp.usage)
                return CommandLineExit.usage.rawValue
            } catch {
                output.writeError(error.localizedDescription)
                return CommandLineExit.failure.rawValue
            }
        }
    }
}

/// The text `hisingen cli help` prints, and the block every usage error repeats. Kept beside the
/// parser so a new subcommand cannot ship without the help naming it.
enum CommandLineHelp {
    static let usage = L10n.text("Usage: hisingen cli vehicles [--json] [--refresh]\n       hisingen cli send <command> [value] [--vin <vin or name>] [--confirm] [--json]\n       hisingen cli help")

    static var text: String {
        let commands = CommandLineCommandTable.specs
            .map { spec in
                spec.arguments.isEmpty
                    ? "  \(spec.identifier)"
                    : "  \(spec.identifier) \(spec.arguments)"
            }
            .joined(separator: "\n")
        return [
            L10n.text("Hisingen command line"),
            "",
            usage,
            "",
            L10n.text("Commands:"),
            commands,
            "",
            L10n.text("Exit codes: 0 sent, 2 unusable arguments, 3 refused, 4 not authorized, 5 not sent and safe to retry."),
        ].joined(separator: "\n")
    }
}

/// The process entry point for `Hisingen cli …`.
///
/// It returns nil unless the process really was launched as the command-line surface, so the
/// menu-bar app's own launch path is untouched. The command line is a mode of the same binary on
/// purpose: SwiftPM will not let one executable link another, and — more importantly — the app's
/// gate, confirmation, provider and audit code must be the code that runs, not a copy of it.
enum CommandLineEntryPoint {
    /// Called from `main.swift` before AppKit starts. Top-level code runs on the main thread but
    /// is not main-actor isolated, so the hop is asserted rather than awaited.
    nonisolated static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == "cli" else { return nil }
        let rest = Array(arguments.dropFirst(2))
        return MainActor.assumeIsolated { run(rest) }
    }

    /// Where the one-shot run leaves its exit code. A reference box because the answer is written
    /// by the main-actor task and read by the thread pumping the run loop.
    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32?

        func finish(_ code: Int32) {
            lock.withLock { stored = code }
            CFRunLoopStop(CFRunLoopGetMain())
        }

        var value: Int32? { lock.withLock { stored } }
    }

    @MainActor
    static func run(_ arguments: [String], output: CommandLineOutput = .live) -> Int32 {
        let box = ExitCodeBox()
        Task { @MainActor in
            box.finish(await execute(arguments, output: output))
        }
        // A one-shot command line has no NSApplication run loop. Pumping the main run loop is
        // what lets the main-actor work above — provider fetches, the coordinator, the keychain —
        // resume; without it the task would sit queued until the process exits.
        while box.value == nil {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return box.value ?? CommandLineExit.failure.rawValue
    }

    @MainActor
    static func execute(_ arguments: [String], output: CommandLineOutput) async -> Int32 {
        let invocation: CommandLineInvocation
        do {
            invocation = try CommandLineInvocation.parse(
                arguments,
                defaults: CommandLineDefaults(
                    climateTemperatureCelsius: PreferencesStore.shared.remoteClimateTemperature))
        } catch let error as CommandLineUsageError {
            output.writeError(error.message)
            output.writeError(CommandLineHelp.usage)
            return CommandLineExit.usage.rawValue
        } catch {
            output.writeError(error.localizedDescription)
            return CommandLineExit.failure.rawValue
        }

        // Help needs no database, no keychain and no provider.
        if case .help = invocation {
            output.write(CommandLineHelp.text)
            return CommandLineExit.success.rawValue
        }

        let session = CommandLineSession()
        return await CommandLineRunner(directory: session, sender: session, output: output).run(invocation)
    }
}
