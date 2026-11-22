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
    func reducedGuardAndHornHaveTheirOwnRoutes() {
        // `honk` stays an alias for honk-and-flash; `horn` is the horn-only link, and reduced
        // guard used to have no route at all even though the command exists for Volvo.
        let context = HardeningRouterContext(activeBrand: .volvo)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://lock-reduced-guard")!)
        router.route(URL(string: "hisingen://horn")!)
        #expect(context.commands == [.lockReducedGuard, .honkHorn])
    }

    // MARK: - Timer and charge-location routes

    @Test
    @MainActor
    func chargeTimerRouteBuildsTheScheduleTheAppWrites() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        URLCommandRouter(context: context)
            .route(URL(string: "hisingen://charge-timer/set?start=07:30&stop=17:00&weekdays=mon,wed,5")!)
        guard case .setGlobalChargeTimer(let timer)? = context.commands.first else {
            Issue.record("expected a charge timer, got \(context.commands)")
            return
        }
        #expect(timer.kind == .globalCharging)
        #expect(timer.startHour == 7 && timer.startMinute == 30)
        #expect(timer.endHour == 17 && timer.endMinute == 0)
        #expect(timer.weekdays == [.monday, .wednesday, .friday])
        #expect(timer.isActive)
    }

    @Test
    @MainActor
    func aTimerWithoutWeekdaysAppliesEveryDay() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        URLCommandRouter(context: context)
            .route(URL(string: "hisingen://climate-timer/set?start=06:00&stop=07:00&active=0")!)
        guard case .setClimateTimer(let timer)? = context.commands.first else {
            Issue.record("expected a climate timer, got \(context.commands)")
            return
        }
        #expect(timer.kind == .climate)
        #expect(timer.weekdays.isEmpty)
        #expect(!timer.isActive)
    }

    @Test
    @MainActor
    func aMalformedTimerIsRefusedLocally() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        let router = URLCommandRouter(context: context)
        // 24:00 and 07:60 are not times; a timer at the wrong hour is worse than no timer.
        router.route(URL(string: "hisingen://charge-timer/set?start=24:00&stop=07:00")!)
        router.route(URL(string: "hisingen://charge-timer/set?start=07:60&stop=17:00")!)
        router.route(URL(string: "hisingen://charge-timer/set?start=07:00")!)
        #expect(context.commands.isEmpty)
        #expect(context.notices.count == 3)
    }

    @Test
    @MainActor
    func climateTimerDeleteRequiresAnID() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://climate-timer/delete?id=42")!)
        router.route(URL(string: "hisingen://climate-timer/delete")!)
        #expect(context.commands == [.deleteClimateTimer(id: "42")])
        #expect(context.notices.count == 1)
    }

    @Test
    @MainActor
    func chargeLocationRoutesCarryClampedValues() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://charge-location/add?alias=Home&amps=99&soc=5&optimised=0")!)
        router.route(URL(string: "hisingen://charge-location/alias?id=7&alias=Work")!)
        router.route(URL(string: "hisingen://charge-location/amps?id=7&amps=64")!)
        router.route(URL(string: "hisingen://charge-location/soc?id=7&soc=10")!)
        router.route(URL(string: "hisingen://charge-location/optimised?id=7&enabled=1")!)
        router.route(URL(string: "hisingen://charge-location/delete?id=7")!)
        #expect(context.commands == [
            .createChargeLocationAtCar(alias: "Home", ampLimit: 32, minimumSoc: 40, optimisedCharging: false),
            .updateChargeLocationAlias(id: "7", alias: "Work"),
            .updateChargeLocationAmpLimit(id: "7", amps: 32),
            .updateChargeLocationMinimumSoc(id: "7", soc: 40),
            .setChargeLocationOptimisedCharging(id: "7", enabled: true),
            .deleteChargeLocation(id: "7"),
        ])
    }

    @Test
    @MainActor
    func chargeLocationLinksWithoutTheirKeyFieldsAreRefused() {
        let context = HardeningRouterContext(activeBrand: .polestar)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://charge-location/add?alias=")!)
        router.route(URL(string: "hisingen://charge-location/amps?id=7")!)
        router.route(URL(string: "hisingen://charge-location/delete")!)
        #expect(context.commands.isEmpty)
        #expect(context.notices.count == 3)
    }

    @Test
    @MainActor
    func chargingTimerRoutesAreRefusedOnVolvo() {
        let context = HardeningRouterContext(activeBrand: .volvo)
        URLCommandRouter(context: context)
            .route(URL(string: "hisingen://charge-timer/set?start=07:00&stop=17:00")!)
        #expect(context.commands.isEmpty)
        #expect(context.notices.count == 1)
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
