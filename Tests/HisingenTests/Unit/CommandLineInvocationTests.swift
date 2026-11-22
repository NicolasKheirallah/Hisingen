import Foundation
import Testing
@testable import Hisingen

/// The command-line surface's argument grammar. Parsing is pure, so these run without a database,
/// a keychain or a provider — which is the point: a mistyped invocation must fail before any of
/// that starts.
@Suite("Command line arguments")
@MainActor
struct CommandLineInvocationTests {
    private func parse(_ arguments: [String], climate: Double = 22) throws -> CommandLineInvocation {
        try CommandLineInvocation.parse(
            arguments, defaults: CommandLineDefaults(climateTemperatureCelsius: climate))
    }

    private func send(_ arguments: [String], climate: Double = 22) throws -> CommandLineSendRequest {
        guard case .send(let request, _) = try parse(arguments, climate: climate) else {
            Issue.record("Expected a send invocation for \(arguments)")
            return CommandLineSendRequest(command: .lock, vehicle: nil, confirmed: false)
        }
        return request
    }

    private func message(_ arguments: [String]) -> String? {
        do {
            _ = try parse(arguments)
            return nil
        } catch let error as CommandLineUsageError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    @Test
    func anEmptyCommandLineIsHelp() throws {
        #expect(try parse([]) == .help)
        #expect(try parse(["help"]) == .help)
        #expect(try parse(["--help"]) == .help)
    }

    @Test
    func vehiclesReadsTheScriptingFlags() throws {
        #expect(try parse(["vehicles"]) == .vehicles(json: false, refresh: false))
        #expect(try parse(["vehicles", "--json"]) == .vehicles(json: true, refresh: false))
        #expect(try parse(["vehicles", "--refresh", "--json"]) == .vehicles(json: true, refresh: true))
    }

    @Test
    func aCommandWithNoArgumentsCarriesNoVehicleAndNoConfirmation() throws {
        let request = try send(["send", "lock"])
        #expect(request.command == .lock)
        #expect(request.vehicle == nil)
        #expect(request.confirmed == false)
    }

    @Test
    func theConfirmationAndVehicleFlagsAreRead() throws {
        let request = try send(["send", "unlock", "--confirm", "--vin", "YSMCLI0000000001", "--json"])
        #expect(request.command == .unlock)
        #expect(request.vehicle == "YSMCLI0000000001")
        #expect(request.confirmed)
        guard case .send(_, let json) = try parse(["send", "unlock", "--json"]) else {
            Issue.record("Expected a send invocation")
            return
        }
        #expect(json)
    }

    @Test
    func anAbsentClimateSetpointTakesTheSavedDefault() throws {
        guard case .startClimate(let temperature, _, _, _, _, _) = try send(["send", "start-climate"], climate: 21.5).command else {
            Issue.record("Expected a climate command")
            return
        }
        #expect(temperature == 21.5)
    }

    @Test
    func anExplicitClimateSetpointIsClampedToTheSlidersRange() throws {
        guard case .startClimate(let temperature, _, _, _, _, _) =
                try send(["send", "start-climate", "--temperature", "35"]).command else {
            Issue.record("Expected a climate command")
            return
        }
        // The app's own slider range, so the terminal cannot ask for a setpoint no control offers.
        #expect(temperature == 30)
    }

    @Test
    func aNonFiniteClimateSetpointIsRefusedRatherThanClamped() throws {
        #expect(message(["send", "start-climate", "--temperature", "nan"]) != nil)
    }

    @Test
    func theTimerGrammarIsTheDeepLinks() throws {
        let request = try send([
            "send", "set-charge-timer", "--start", "07:30", "--stop", "17:00", "--weekdays", "mon,fri",
        ])
        guard case .setGlobalChargeTimer(let schedule) = request.command else {
            Issue.record("Expected a charging timer")
            return
        }
        #expect(schedule.kind == .globalCharging)
        #expect(schedule.startHour == 7)
        #expect(schedule.startMinute == 30)
        #expect(schedule.endHour == 17)
        #expect(schedule.endMinute == 0)
        #expect(schedule.weekdays == [.monday, .friday])
        #expect(schedule.isActive)
    }

    @Test
    func anInactiveTimerIsCarriedThrough() throws {
        let request = try send([
            "send", "set-climate-timer", "--start", "06:00", "--stop", "07:00", "--inactive",
        ])
        guard case .setClimateTimer(let schedule) = request.command else {
            Issue.record("Expected a climate timer")
            return
        }
        #expect(schedule.kind == .climate)
        #expect(schedule.isActive == false)
    }

    @Test
    func aTimerWithoutBothTimesIsRefused() throws {
        #expect(message(["send", "set-charge-timer", "--start", "07:30"]) != nil)
        #expect(message(["send", "set-charge-timer", "--start", "25:00", "--stop", "17:00"]) != nil)
        #expect(message(["send", "set-charge-timer", "--start", "07:30", "--stop", "17:00",
                         "--weekdays", "funday"]) != nil)
    }

    @Test
    func valuesOutsideTheControlsPickersAreRefused() throws {
        // The Controls tab's own fallback ranges; the gate has no charge-target bound of its own,
        // so accepting these would make the terminal the one surface that can ask for them.
        #expect(message(["send", "set-charge-target", "5"]) != nil)
        #expect(message(["send", "set-charge-target", "101"]) != nil)
        #expect(message(["send", "set-amp-limit", "40"]) != nil)
        #expect(message(["send", "start-engine", "7"]) != nil)
        #expect(message(["send", "schedule-ota", "60"]) != nil)
        #expect(message(["send", "set-charge-target", "eighty"]) != nil)
    }

    @Test
    func theValuesThePickersDoOfferAreAccepted() throws {
        #expect(try send(["send", "set-charge-target", "80"]).command == .setChargeTarget(80))
        #expect(try send(["send", "set-amp-limit", "16"]).command == .setAmpLimit(16))
        #expect(try send(["send", "start-engine", "10"]).command == .startEngine(runtimeMinutes: 10))
        #expect(try send(["send", "schedule-ota", "480"]).command == .scheduleOTA(delayMinutes: 480))
        #expect(try send(["send", "delete-charge-location", "abc"]).command == .deleteChargeLocation(id: "abc"))
        #expect(try send(["send", "create-charge-location", "Home", "--amps", "10", "--soc", "60",
                          "--no-optimised"]).command
                == .createChargeLocationAtCar(alias: "Home", ampLimit: 10, minimumSoc: 60,
                                              optimisedCharging: false))
        #expect(try send(["send", "set-location-optimised-charging", "abc", "--off"]).command
                == .setChargeLocationOptimisedCharging(id: "abc", enabled: false))
        #expect(try send(["send", "rename-charge-location", "abc", "Driveway"]).command
                == .updateChargeLocationAlias(id: "abc", alias: "Driveway"))
    }

    @Test
    func anUnknownSubcommandOrCommandIsRefused() throws {
        #expect(message(["drive"]) != nil)
        #expect(message(["send", "launch"]) != nil)
        #expect(message(["send"]) != nil)
    }

    @Test
    func anOptionACommandDoesNotReadIsRefused() throws {
        // `--amps` is a real option of `create-charge-location`; lock must not quietly ignore it.
        #expect(message(["send", "lock", "--amps", "16"]) != nil)
        #expect(message(["send", "lock", "--colour", "blue"]) != nil)
    }

    @Test
    func anOptionWithoutItsValueIsRefused() throws {
        #expect(message(["send", "lock", "--vin"]) != nil)
        #expect(message(["send", "start-climate", "--temperature"]) != nil)
    }

    @Test
    func surplusValuesAreRefused() throws {
        #expect(message(["send", "lock", "now"]) != nil)
        #expect(message(["send", "set-charge-target", "80", "now"]) != nil)
    }
}

/// The table and `RemoteCommand` must not drift apart. Every command the app can send needs a way
/// to be typed, and every row must build the command it claims; a new `RemoteCommand` case that
/// nobody wired fails here instead of shipping a command line that cannot send it.
@Suite("Command line command table")
@MainActor
struct CommandLineCommandTableTests {
    /// Every case of `RemoteCommand`, constructed. The exhaustive switch in `RemoteCommand` makes
    /// a new case a compile error in the app; this list is where it becomes a test failure.
    private var everyCommand: [RemoteCommand] {
        [
            .startClimate(temperatureCelsius: 22, frontLeftSeat: .off, frontRightSeat: .off,
                           rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
            .stopClimate,
            .startPreCleaning,
            .stopPreCleaning,
            .lock,
            .lockReducedGuard,
            .unlock,
            .unlockTrunk,
            .openTailgate,
            .closeTailgate,
            .openWindows,
            .closeWindows,
            .flashLights,
            .honkAndFlash,
            .honkHorn,
            .setChargeTarget(80),
            .setAmpLimit(16),
            .startChargingOverride,
            .stopChargingOverride,
            .setGlobalChargeTimer(VehicleSchedule(kind: .globalCharging, startHour: 7, startMinute: 0,
                                                  endHour: 17, endMinute: 0, isActive: true)),
            .setClimateTimer(VehicleSchedule(kind: .climate, startHour: 7, startMinute: 0,
                                             endHour: 8, endMinute: 0, isActive: true)),
            .deleteClimateTimer(id: "1"),
            .scheduleOTA(delayMinutes: 120),
            .installOTANow,
            .cancelOTA,
            .createChargeLocationAtCar(alias: "Home", ampLimit: 16, minimumSoc: 40, optimisedCharging: true),
            .updateChargeLocationAlias(id: "1", alias: "Home"),
            .updateChargeLocationAmpLimit(id: "1", amps: 16),
            .updateChargeLocationMinimumSoc(id: "1", soc: 40),
            .setChargeLocationOptimisedCharging(id: "1", enabled: true),
            .deleteChargeLocation(id: "1"),
            .startEngine(runtimeMinutes: 10),
            .stopEngine,
        ]
    }

    @Test
    func everyRemoteCommandCanBeTyped() {
        let typed = Set(CommandLineCommandTable.specs.map(\.identifier))
        let dispatchable = Set(everyCommand.map(\.identifier))
        #expect(typed == dispatchable,
                "command line and RemoteCommand disagree: \(dispatchable.symmetricDifference(typed))")
    }

    @Test
    func everyRowProbesTheCommandItNames() {
        for spec in CommandLineCommandTable.specs {
            #expect(spec.probe.identifier == spec.identifier, "\(spec.identifier) probes \(spec.probe.identifier)")
        }
    }

    @Test
    func noRowIsListedTwice() {
        let identifiers = CommandLineCommandTable.specs.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test
    func helpNamesEveryCommand() {
        for spec in CommandLineCommandTable.specs {
            #expect(CommandLineHelp.text.contains(spec.identifier))
        }
    }
}
