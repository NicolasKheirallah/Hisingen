import Foundation
import Testing
@testable import Hisingen

/// Records what a test's surface printed. The output closures are `@Sendable` because the live
/// ones write to the process's handles, so the box they append to serializes itself.
private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []

    var output: CommandLineOutput {
        CommandLineOutput(
            standardOutput: { [self] text in lock.withLock { out.append(text) } },
            standardError: { [self] text in lock.withLock { err.append(text) } })
    }

    var standardOutput: [String] { lock.withLock { out } }
    var standardError: [String] { lock.withLock { err } }
}

@MainActor
private final class StubDirectory: CommandLineVehicleDirectory {
    var requestedRefreshes: [Bool] = []
    var report = CommandLineVehicleListReport(vehicles: [])

    func vehicles(refresh: Bool) async -> CommandLineVehicleListReport {
        requestedRefreshes.append(refresh)
        return report
    }
}

@MainActor
private final class StubSender: CommandLineCommandSending {
    var sent: [CommandLineSendRequest] = []
    var report = CommandLineSendReport(status: .sent, command: "lock", vin: nil, vehicle: nil,
                                        outcome: "accepted", message: "sent")
    var failure: (any Error)?

    func send(_ request: CommandLineSendRequest) async throws -> CommandLineSendReport {
        if let failure { throw failure }
        sent.append(request)
        return report
    }
}

@Suite("Command line surface")
@MainActor
struct CommandLineRunnerTests {
    private func runner(
        _ recorder: OutputRecorder,
        directory: StubDirectory = StubDirectory(),
        sender: StubSender = StubSender()
    ) -> CommandLineRunner {
        CommandLineRunner(directory: directory, sender: sender, output: recorder.output)
    }

    @Test
    func aRefusalExitsWithTheRefusalCodeAndPrintsTheAppsOwnSentence() async {
        let recorder = OutputRecorder()
        let sender = StubSender()
        let reason = CommandAvailability.unsupportedByVehicle.shortReason ?? ""
        sender.report = CommandLineSendReport(status: .refused, command: "unlock", vin: "YSM1",
                                               vehicle: "Blue", outcome: nil, message: reason)

        let code = await runner(recorder, sender: sender)
            .run(.send(CommandLineSendRequest(command: .unlock, vehicle: nil, confirmed: true), json: false))

        #expect(code == CommandLineExit.refused.rawValue)
        #expect(code != 0)
        #expect(recorder.standardError == [reason + "\n"])
        #expect(recorder.standardOutput.isEmpty)
    }

    @Test
    func everyStatusCarriesItsOwnExitCode() async {
        let cases: [(CommandLineSendReport.Status, Int32)] = [
            (.sent, 0), (.refused, 3), (.confirmationRequired, 4), (.notSent, 5),
        ]
        for (status, expected) in cases {
            let recorder = OutputRecorder()
            let sender = StubSender()
            sender.report = CommandLineSendReport(status: status, command: "lock", vin: nil, vehicle: nil,
                                                  outcome: nil, message: "message")
            let code = await runner(recorder, sender: sender)
                .run(.send(CommandLineSendRequest(command: .lock, vehicle: nil, confirmed: false), json: false))
            #expect(code == expected, "\(status) should exit \(expected)")
        }
    }

    @Test
    func jsonModePrintsOneObjectOnTheStandardOutputEvenForARefusal() async throws {
        let recorder = OutputRecorder()
        let sender = StubSender()
        sender.report = CommandLineSendReport(status: .refused, command: "unlock", vin: "YSM1",
                                               vehicle: "Blue", outcome: nil,
                                               message: "This vehicle does not support the command.")

        let code = await runner(recorder, sender: sender)
            .run(.send(CommandLineSendRequest(command: .unlock, vehicle: nil, confirmed: true), json: true))

        #expect(code == CommandLineExit.refused.rawValue)
        #expect(recorder.standardError.isEmpty)
        let line = try #require(recorder.standardOutput.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "refused")
        #expect(json["command"] as? String == "unlock")
        #expect(json["vin"] as? String == "YSM1")
        #expect(json["message"] as? String == "This vehicle does not support the command.")
    }

    @Test
    func theVehiclesListIsTheSameAnswerInBothModes() async throws {
        let recorder = OutputRecorder()
        let directory = StubDirectory()
        directory.report = CommandLineVehicleListReport(vehicles: [
            CommandLineVehicleReport(
                vin: "YSM1", name: "Blue", brand: "polestar", selected: true, state: "cached",
                fetchedAt: Date(timeIntervalSince1970: 0),
                commands: ["lock": "available", "unlock": "unsupported-by-vehicle"],
                reasons: ["unlock": "This vehicle does not support the command."],
                note: nil),
        ])

        _ = await runner(recorder, directory: directory).run(.vehicles(json: false, refresh: false))
        let text = try #require(recorder.standardOutput.first)
        #expect(text.contains("YSM1"))
        #expect(text.contains("lock"))
        #expect(text.contains("This vehicle does not support the command."))

        let jsonRecorder = OutputRecorder()
        _ = await runner(jsonRecorder, directory: directory).run(.vehicles(json: true, refresh: true))
        #expect(directory.requestedRefreshes == [false, true])
        let line = try #require(jsonRecorder.standardOutput.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let vehicles = try #require(json["vehicles"] as? [[String: Any]])
        let first = try #require(vehicles.first)
        #expect(first["vin"] as? String == "YSM1")
        let commands = try #require(first["commands"] as? [String: String])
        #expect(commands["unlock"] == "unsupported-by-vehicle")
    }

    @Test
    func anUnusableArgumentExitsWithTheUsageCodeAndRepeatsTheUsage() async {
        let recorder = OutputRecorder()
        let sender = StubSender()
        sender.failure = CommandLineUsageError(message: "No vehicle in Hisingen matches that name or VIN.")

        let code = await runner(recorder, sender: sender)
            .run(.send(CommandLineSendRequest(command: .lock, vehicle: "nothing", confirmed: false), json: true))

        #expect(code == CommandLineExit.usage.rawValue)
        #expect(recorder.standardOutput.isEmpty)
        #expect(recorder.standardError.first == "No vehicle in Hisingen matches that name or VIN.\n")
        #expect(recorder.standardError.last?.hasPrefix(CommandLineHelp.usage) == true)
    }

    @Test
    func anInvocationThatCannotBeParsedNeverReachesTheSender() async {
        let recorder = OutputRecorder()
        let code = await CommandLineEntryPoint.execute(["send", "lock", "--amps", "16"], output: recorder.output)
        #expect(code == CommandLineExit.usage.rawValue)
        #expect(recorder.standardOutput.isEmpty)
        #expect(recorder.standardError.isEmpty == false)
    }

    @Test
    func helpNeedsNoDatabaseAndSucceeds() async {
        let recorder = OutputRecorder()
        let code = await CommandLineEntryPoint.execute(["help"], output: recorder.output)
        #expect(code == CommandLineExit.success.rawValue)
        let text = recorder.standardOutput.joined(separator: "\n")
        #expect(text.contains("hisingen cli send"))
        #expect(text.contains("Exit codes"))
    }

    @Test
    func theSurfaceIsNotEnteredWhenTheAppIsLaunchedNormally() {
        #expect(CommandLineEntryPoint.runIfRequested(["Hisingen"]) == nil)
        #expect(CommandLineEntryPoint.runIfRequested(["Hisingen", "--ci-smoke-test"]) == nil)
    }
}
