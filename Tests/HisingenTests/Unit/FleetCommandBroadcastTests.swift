import Foundation
import Testing
@testable import Hisingen

/// A broadcast is only useful if it either reaches every configured vehicle or says which one it
/// did not reach. These tests pin both halves, including that one failure does not stop the rest.
@Suite(.serialized)
@MainActor
struct FleetCommandBroadcastTests {
    private let volvo = FleetCommandVehicle(vin: "YSMFLEETTEST00001", displayName: "XC40")
    private let polestar = FleetCommandVehicle(vin: "YSMFLEETTEST00002", displayName: "Polestar 2")
    private let third = FleetCommandVehicle(vin: "YSMFLEETTEST00003", displayName: "Polestar 4")

    @Test
    func aBroadcastReachesEveryConfiguredVehicle() async {
        var contacted: [String] = []
        let broadcaster = FleetCommandBroadcaster(
            vehicles: { [volvo, polestar, third] },
            send: { _, vin in
                contacted.append(vin)
                return .sent
            })

        let report = await broadcaster.broadcast(.lock)

        #expect(contacted == [volvo.vin, polestar.vin, third.vin])
        #expect(report.vehiclesConsidered == 3)
        #expect(report.sentCount == 3)
        #expect(report.failed.isEmpty)
        #expect(report.summary() == L10n.format("%@ sent to %d vehicles.", RemoteCommand.lock.title, 3))
    }

    @Test
    func aFailureIsReportedByNameAndTheRestStillGetTheCommand() async {
        let failing = third
        let broadcaster = FleetCommandBroadcaster(
            vehicles: { [volvo, polestar, failing] },
            send: { _, vin in
                vin == failing.vin
                    ? .failed(reason: "The vehicle service refused the command.")
                    : .sent
            })

        let report = await broadcaster.broadcast(.lock)

        #expect(report.sentCount == 2)
        #expect(report.failed.count == 1)
        #expect(report.failed.first?.vehicle == failing)
        #expect(report.failed.first?.result == .failed(reason: "The vehicle service refused the command."))
        let summary = report.summary()
        #expect(summary.contains(failing.displayName))
        #expect(summary.contains("2"))
    }

    @Test
    func aFailureFirstDoesNotStopTheVehiclesAfterIt() async {
        var contacted: [String] = []
        let broadcaster = FleetCommandBroadcaster(
            vehicles: { [volvo, polestar] },
            send: { _, vin in
                contacted.append(vin)
                return vin == volvo.vin ? .failed(reason: "no") : .sent
            })

        let report = await broadcaster.broadcast(.closeWindows)

        #expect(contacted == [volvo.vin, polestar.vin])
        #expect(report.sentCount == 1)
        #expect(report.failed.map(\.vehicle.vin) == [volvo.vin])
    }

    @Test
    func aCooldownRefusalIsAPerVehicleFailureNotASilentSkip() async {
        let broadcaster = FleetCommandBroadcaster(
            vehicles: { [volvo, polestar] },
            send: { _, vin in
                vin == polestar.vin
                    ? .coolingDown(reason: "Wait 1min before sending Lock vehicle again.", retryAfter: 30)
                    : .sent
            })

        let report = await broadcaster.broadcast(.lock)

        #expect(report.sentCount == 1)
        #expect(report.failed.first?.result.reason?.contains("Wait") == true)
    }

    @Test
    func anAccountWithNoVehiclesSaysSoInsteadOfReportingSuccess() async {
        let broadcaster = FleetCommandBroadcaster(vehicles: { [] }, send: { _, _ in .sent })

        let report = await broadcaster.broadcast(.lock)

        #expect(report.vehiclesConsidered == 0)
        #expect(report.sentCount == 0)
        #expect(report.summary() == L10n.text("No vehicles are configured for this account."))
    }
}
