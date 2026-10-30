import Foundation
import Testing
@testable import Hisingen

/// Inbound URL hardening: OAuth is reached only through its registered callback, unknown
/// commands are refused, and deep-link values are pinned to the app's own ranges.
@Suite("URL command router hardening")
struct URLCommandRouterHardeningTests {
    @Test
    @MainActor
    func volvoOAuthCallbackRoutesOnlyThroughItsRegisteredPath() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://oauth/volvo/callback?code=abc&state=xyz")!)
        #expect(context.oauthCallbacks.count == 1)
        #expect(context.commands.isEmpty)
        #expect(context.notices.isEmpty)
    }

    /// A `code=` query on an ordinary command is not an OAuth result.
    @Test
    @MainActor
    func codeQueryOnACommandDoesNotReachSignIn() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: context).route(URL(string: "hisingen://lock?code=abc")!)
        #expect(context.oauthCallbacks.isEmpty)
        #expect(context.commands == [.lock])
    }

    @Test
    @MainActor
    func unknownHisingenCommandsAreRefusedWithANotice() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://no-such-command")!)
        router.route(URL(string: "hisingen://oauth/volvo/callback/extra?code=abc")!)
        router.route(URL(string: "hisingen://oauth/polestar/callback?code=abc")!)
        #expect(context.oauthCallbacks.isEmpty)
        #expect(context.commands.isEmpty)
        #expect(context.notices.count == 3)
    }

    /// The copy-vin command is gone: any app could open the URL and read the VIN from the pasteboard.
    @Test
    @MainActor
    func copyVINIsNoLongerAnURLCommand() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: context).route(URL(string: "hisingen://copy-vin")!)
        #expect(context.oauthCallbacks.isEmpty)
        #expect(context.commands.isEmpty)
        #expect(context.notices.count == 1)
    }

    @Test
    @MainActor
    func polestarRedirectRequiresItsRegisteredHost() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "polestar-explore://explore.polestar.com?code=abc")!)
        #expect(context.oauthCallbacks.count == 1)
        router.route(URL(string: "polestar-explore://elsewhere.example?code=abc")!)
        #expect(context.oauthCallbacks.count == 1)
    }

    @Test
    @MainActor
    func chargeTargetIsClampedToTheAppRange() {
        let high = HardeningRouterContext(activeBrand: .polestar)
        URLCommandRouter(context: high).route(URL(string: "hisingen://charge-target?percent=150")!)
        #expect(high.commands == [.setChargeTarget(100)])

        let low = HardeningRouterContext(activeBrand: .polestar)
        URLCommandRouter(context: low).route(URL(string: "hisingen://charge-target?percent=5")!)
        #expect(low.commands == [.setChargeTarget(40)])
    }

    @Test
    @MainActor
    func climateTemperatureIsClampedToTheAppRange() {
        let seats = (frontLeft: RemoteCommand.startClimate(temperatureCelsius: 30, frontLeftSeat: .off,
                                                           frontRightSeat: .off, rearLeftSeat: .off,
                                                           rearRightSeat: .off, steeringWheel: .off),
                     coldest: RemoteCommand.startClimate(temperatureCelsius: 16, frontLeftSeat: .off,
                                                         frontRightSeat: .off, rearLeftSeat: .off,
                                                         rearRightSeat: .off, steeringWheel: .off))

        let hot = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: hot).route(URL(string: "hisingen://climate/start?temp=99")!)
        #expect(hot.commands == [seats.frontLeft])

        let cold = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: cold).route(URL(string: "hisingen://climate/start?temp=-5")!)
        #expect(cold.commands == [seats.coldest])
    }

    /// A non-numeric or non-finite temperature falls back to the saved default (21 in the mock).
    @Test
    @MainActor
    func nonFiniteClimateTemperatureTakesTheSavedDefault() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: context).route(URL(string: "hisingen://climate/start?temp=nan")!)
        #expect(context.commands == [.startClimate(temperatureCelsius: 21, frontLeftSeat: .off,
                                                   frontRightSeat: .off, rearLeftSeat: .off,
                                                   rearRightSeat: .off, steeringWheel: .off)])
    }
}

@MainActor
private final class HardeningRouterContext: URLCommandRouterContext {
    let activeBrand: VehicleBrand
    var defaultRemoteClimateTemperatureCelsius: Double { 21 }
    private(set) var oauthCallbacks: [URL] = []
    private(set) var commands: [RemoteCommand] = []
    private(set) var notices: [(String, String)] = []

    init(activeBrand: VehicleBrand) { self.activeBrand = activeBrand }

    func handleOAuthCallback(_ url: URL) { oauthCallbacks.append(url) }
    func selectVehicle(vin: String) {}
    func selectVehicleByIndex(_ index: Int) {}
    func showSettings() {}
    func toggleSettings() {}
    func togglePopover() {}
    func refreshNow() {}
    func performRemoteCommand(_ command: RemoteCommand, targetVIN: String?) { commands.append(command) }
    func notifyCommandNotice(title: String, body: String) { notices.append((title, body)) }
}
