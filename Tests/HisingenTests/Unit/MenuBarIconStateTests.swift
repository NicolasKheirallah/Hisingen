import Foundation
import Testing
@testable import Hisingen

/// The menu-bar / tray icon's priority machine: which condition wins when
/// several are true at once, when a completion is allowed to show, and how the
/// raw signals are read off a `VehicleState`. The pulse itself is judged on
/// screen; this covers the logic that decides *what* the glyph is saying.
@Suite
struct MenuBarIconStateTests {

    // MARK: - Priority

    @Test
    func nothingHappeningIsTheRestingState() {
        #expect(MenuBarIconState.resolve(MenuBarIconInputs()) == .normal)
    }

    @Test
    func pluggedInButIdleReadsAsConnected() {
        let inputs = MenuBarIconInputs(pluggedIn: true)
        #expect(MenuBarIconState.resolve(inputs) == .connected)
    }

    @Test
    func chargingOutranksClimateAndConnected() {
        let inputs = MenuBarIconInputs(
            isCharging: true, pluggedIn: true, climateActive: true
        )
        #expect(MenuBarIconState.resolve(inputs) == .charging)
    }

    @Test
    func aRemoteCommandOutranksCharging() {
        let inputs = MenuBarIconInputs(
            isCharging: true, pluggedIn: true, remoteCommandInProgress: true
        )
        #expect(MenuBarIconState.resolve(inputs) == .remoteOperation)
    }

    @Test
    func aCriticalWarningOutranksEverything() {
        let inputs = MenuBarIconInputs(
            isCharging: true,
            pluggedIn: true,
            climateActive: true,
            remoteCommandInProgress: true,
            alarmTriggered: true
        )
        #expect(MenuBarIconState.resolve(inputs) == .warning)

        // A charging fault is critical too, even though it also means "not charging".
        let faulted = MenuBarIconInputs(chargingFault: true, pluggedIn: true)
        #expect(MenuBarIconState.resolve(faulted) == .warning)
    }

    @Test
    func completionOnlyShowsAfterChargingHasActuallyStopped() {
        // Still charging: the completion flag is ignored.
        let stillCharging = MenuBarIconInputs(isCharging: true, chargingRecentlyCompleted: true, pluggedIn: true)
        #expect(MenuBarIconState.resolve(stillCharging) == .charging)

        // Stopped, target reached: the brief acknowledgement.
        let done = MenuBarIconInputs(isCharging: false, chargingRecentlyCompleted: true, pluggedIn: true)
        #expect(MenuBarIconState.resolve(done) == .chargingComplete)

        // A remote command still in flight is more current than the acknowledgement.
        let doneButBusy = MenuBarIconInputs(
            isCharging: false, chargingRecentlyCompleted: true,
            pluggedIn: true, remoteCommandInProgress: true
        )
        #expect(MenuBarIconState.resolve(doneButBusy) == .remoteOperation)
    }

    @Test
    func statesAreOrderedByPriority() {
        #expect(MenuBarIconState.allCases == MenuBarIconState.allCases.sorted())
        #expect(MenuBarIconState.allCases.max() == .warning)
        #expect(MenuBarIconState.warning > MenuBarIconState.remoteOperation)
        #expect(MenuBarIconState.remoteOperation > MenuBarIconState.charging)
        #expect(MenuBarIconState.charging > MenuBarIconState.climate)
        #expect(MenuBarIconState.climate > MenuBarIconState.connected)
        #expect(MenuBarIconState.connected > MenuBarIconState.normal)
    }

    // MARK: - What animates

    @Test
    func onlyChargingAndRemoteOperationAnimate() {
        for state in MenuBarIconState.allCases {
            let expected = (state == .charging || state == .remoteOperation)
            #expect(state.isAnimated == expected, "\(state) animation flag")
            #expect((state.pulseProfile != nil) == expected, "\(state) pulse profile presence")
        }
    }

    @Test
    func chargingBreathMatchesTheSharedTokenAndStaysFrugal() throws {
        let charging = try #require(MenuBarIconState.charging.pulseProfile)
        #expect(charging.cycle == Motion.menuBarBreathCycle)
        #expect(charging.frames == Motion.menuBarBreathFrames)
        // ~5 fps or slower.
        #expect(charging.tickInterval >= 0.15)
        // A gentle swell, never a flash: alpha stays high and moves a little.
        #expect(charging.minAlpha >= 0.4 && charging.minAlpha < charging.maxAlpha)
        #expect(charging.maxAlpha <= 1.0)

        // The remote-op shimmer is quicker and shallower, so it reads differently.
        let remote = try #require(MenuBarIconState.remoteOperation.pulseProfile)
        #expect(remote.cycle < charging.cycle)
        #expect(remote.minAlpha > charging.minAlpha)
    }

    // MARK: - Reading the signals off a snapshot

    @Test
    func inputsFromNoStateOnlyCarryTheCommandFlag() {
        let idle = MenuBarIconState.inputs(for: nil, remoteCommandInProgress: false, chargingRecentlyCompleted: true)
        #expect(idle == MenuBarIconInputs())

        let busy = MenuBarIconState.inputs(for: nil, remoteCommandInProgress: true, chargingRecentlyCompleted: false)
        #expect(MenuBarIconState.resolve(busy) == .remoteOperation)
    }

    @Test
    func inputsReadChargingClimateAndFaultFromTheSnapshot() {
        let charging = MenuBarIconState.inputs(
            for: Self.state(charging: .charging, connection: .connected),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        #expect(charging.isCharging)
        #expect(charging.pluggedIn)
        #expect(!(charging.isCritical))

        let heating = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, climate: .heating),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        #expect(heating.climateActive)
        #expect(!(heating.pluggedIn))

        let idleClimate = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, climate: .idle),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        #expect(!(idleClimate.climateActive))

        let faulted = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .fault),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        #expect(faulted.chargingFault)
        #expect(faulted.isCritical)

        let alarmed = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, alarm: true),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        #expect(alarmed.alarmTriggered)
        #expect(MenuBarIconState.resolve(alarmed) == .warning)
    }

    // MARK: - Fixture

    private static func state(
        charging: ChargingState,
        connection: ChargerConnection,
        climate: ClimateActivity? = nil,
        alarm: Bool = false
    ) -> VehicleState {
        // TESTS-12: thin wrapper over the shared TestSupport fixture builder.
        vehicle(
            vin: "YS2P2000000000042", battery: 55, rangeKm: 240,
            state: charging,
            connection: connection,
            chargingType: charging.isActivelyCharging ? .ac : .none,
            powerWatts: charging.isActivelyCharging ? 11_000 : nil,
            modelYear: "2024",
            odometerKm: 12_000,
            exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: alarm),
            climateStatus: climate.map {
                VehicleClimateStatus(activity: $0, timeRemainingMinutes: nil, timerTriggered: false)
            }
        )
    }
}
