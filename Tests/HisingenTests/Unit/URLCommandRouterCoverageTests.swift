import Foundation
import Testing
@testable import Hisingen

/// Deep-link routes beyond lock, climate and charge target. Each route hands over exactly one
/// command, values the Controls tab cannot offer are refused locally, and the destructive or
/// security-sensitive routes stay on the confirmed path. The router never gates on brand or
/// capability itself: the command coordinator does, for links and buttons alike.
@Suite("URL command router coverage")
struct URLCommandRouterCoverageTests {
    @Test
    @MainActor
    func polestarRoutesHandOverTheirCommand() {
        let cases: [(String, RemoteCommand)] = [
            ("hisingen://precleaning/start", .startPreCleaning),
            ("hisingen://precleaning/stop", .stopPreCleaning),
            ("hisingen://windows/open", .openWindows),
            ("hisingen://windows/close", .closeWindows),
            ("hisingen://tailgate/open", .openTailgate),
            ("hisingen://tailgate/close", .closeTailgate),
            ("hisingen://trunk/unlock", .unlockTrunk),
            ("hisingen://charging/override-start", .startChargingOverride),
            ("hisingen://charging/override-stop", .stopChargingOverride),
            ("hisingen://ota/install", .installOTANow),
            ("hisingen://ota/cancel", .cancelOTA),
        ]
        for (link, expected) in cases {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: link)!)
            #expect(context.commands == [expected], "\(link) should dispatch \(expected.identifier)")
            #expect(context.notices.isEmpty, "\(link) should not raise a notice")
        }
    }

    @Test
    @MainActor
    func engineRoutesHandOverTheirCommand() {
        let stop = CoverageRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: stop).route(URL(string: "hisingen://engine/stop")!)
        #expect(stop.commands == [.stopEngine])

        let start = CoverageRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: start).route(URL(string: "hisingen://engine/start?minutes=10")!)
        #expect(start.commands == [.startEngine(runtimeMinutes: 10)])
    }

    /// Without a runtime the link takes the Controls tab default, the longest option.
    @Test
    @MainActor
    func engineStartWithoutRuntimeUsesTheLongestOption() {
        let context = CoverageRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: context).route(URL(string: "hisingen://engine/start")!)
        #expect(context.commands == [.startEngine(runtimeMinutes: 15)])
    }

    @Test
    @MainActor
    func engineRuntimeOutsideThePickerIsRefused() {
        for value in ["7", "30", "0", "-5", "ten"] {
            let context = CoverageRouterContext(activeBrand: .volvo)
            URLCommandRouter(context: context).route(URL(string: "hisingen://engine/start?minutes=\(value)")!)
            #expect(context.commands.isEmpty, "minutes=\(value)")
            #expect(context.notices.count == 1, "minutes=\(value)")
        }
    }

    @Test
    @MainActor
    func chargeLimitIsPinnedToTheAppAmperageRange() {
        let cases: [(String, Int)] = [("16", 16), ("99", 32), ("1", 6), ("6", 6), ("32", 32)]
        for (value, expected) in cases {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: "hisingen://charge-limit?amps=\(value)")!)
            #expect(context.commands == [.setAmpLimit(expected)], "amps=\(value)")
        }
    }

    @Test
    @MainActor
    func chargeLimitWithoutAWholeNumberIsRefused() {
        for query in ["", "?amps=", "?amps=abc", "?amps=16.5", "?current=16"] {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: "hisingen://charge-limit\(query)")!)
            #expect(context.commands.isEmpty, "charge-limit\(query)")
            #expect(context.notices.count == 1, "charge-limit\(query)")
        }
    }

    @Test
    @MainActor
    func otaScheduleAcceptsOnlyThePickerDelays() {
        for delay in [120, 480, 720] {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: "hisingen://ota/schedule?delay=\(delay)")!)
            #expect(context.commands == [.scheduleOTA(delayMinutes: delay)], "delay=\(delay)")
        }
        for query in ["", "?delay=60", "?delay=121", "?delay=soon"] {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: "hisingen://ota/schedule\(query)")!)
            #expect(context.commands.isEmpty, "ota/schedule\(query)")
            #expect(context.notices.count == 1, "ota/schedule\(query)")
        }
    }

    /// Installing software and starting the engine are the two routes that move the car on
    /// their own. Both must keep the risk the confirmation sheet keys off.
    @Test
    func routedRiskMatchesTheConfirmationPath() {
        #expect(RemoteCommand.unlock.risk == .securitySensitive)
        #expect(RemoteCommand.unlockTrunk.risk == .securitySensitive)
        #expect(RemoteCommand.openTailgate.risk == .securitySensitive)
        #expect(RemoteCommand.openWindows.risk == .securitySensitive)
        #expect(RemoteCommand.startEngine(runtimeMinutes: 15).risk == .securitySensitive)
        #expect(RemoteCommand.installOTANow.risk == .destructive)

        #expect(RemoteCommand.unlockTrunk.risk.requiresDeviceOwnerAuthentication)
        #expect(RemoteCommand.installOTANow.risk.requiresDeviceOwnerAuthentication)
        #expect(!RemoteCommand.closeWindows.risk.requiresDeviceOwnerAuthentication)
        #expect(!RemoteCommand.cancelOTA.risk.requiresDeviceOwnerAuthentication)
    }

    @Test
    @MainActor
    func newRoutesKeepTheVehicleTargetQuery() {
        let context = CoverageRouterContext(activeBrand: .polestar)
        URLCommandRouter(context: context).route(URL(string: "hisingen://ota/cancel?vin=YSMTARGET01")!)
        #expect(context.commands == [.cancelOTA])
        #expect(context.targets == ["YSMTARGET01"])
    }

    @Test
    @MainActor
    func nearMissRoutesAreRefusedNotGuessed() {
        for link in ["hisingen://windows/open/now", "hisingen://engine/restart", "hisingen://ota", "hisingen://charging/override"] {
            let context = CoverageRouterContext(activeBrand: .polestar)
            URLCommandRouter(context: context).route(URL(string: link)!)
            #expect(context.commands.isEmpty, "\(link)")
            #expect(context.notices.count == 1, "\(link)")
        }
    }
}

@MainActor
private final class CoverageRouterContext: URLCommandRouterContext {
    let activeBrand: VehicleBrand
    var defaultRemoteClimateTemperatureCelsius: Double { 21 }
    private(set) var commands: [RemoteCommand] = []
    private(set) var targets: [String?] = []
    private(set) var notices: [(String, String)] = []

    init(activeBrand: VehicleBrand) { self.activeBrand = activeBrand }

    func handleOAuthCallback(_ url: URL) {}
    func selectVehicle(vin: String) {}
    func selectVehicleByIndex(_ index: Int) {}
    func showSettings() {}
    func toggleSettings() {}
    func togglePopover() {}
    func refreshNow() {}
    func performRemoteCommand(_ command: RemoteCommand, targetVIN: String?) {
        commands.append(command)
        targets.append(targetVIN)
    }
    func notifyCommandNotice(title: String, body: String) { notices.append((title, body)) }
}
