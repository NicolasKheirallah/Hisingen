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
        XCTAssertEqual(MenuBarIconState.resolve(MenuBarIconInputs()), .normal)
    }

    @Test
    func pluggedInButIdleReadsAsConnected() {
        let inputs = MenuBarIconInputs(pluggedIn: true)
        XCTAssertEqual(MenuBarIconState.resolve(inputs), .connected)
    }

    @Test
    func chargingOutranksClimateAndConnected() {
        let inputs = MenuBarIconInputs(
            isCharging: true, pluggedIn: true, climateActive: true
        )
        XCTAssertEqual(MenuBarIconState.resolve(inputs), .charging)
    }

    @Test
    func aRemoteCommandOutranksCharging() {
        let inputs = MenuBarIconInputs(
            isCharging: true, pluggedIn: true, remoteCommandInProgress: true
        )
        XCTAssertEqual(MenuBarIconState.resolve(inputs), .remoteOperation)
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
        XCTAssertEqual(MenuBarIconState.resolve(inputs), .warning)

        // A charging fault is critical too, even though it also means "not charging".
        let faulted = MenuBarIconInputs(chargingFault: true, pluggedIn: true)
        XCTAssertEqual(MenuBarIconState.resolve(faulted), .warning)
    }

    @Test
    func completionOnlyShowsAfterChargingHasActuallyStopped() {
        // Still charging: the completion flag is ignored.
        let stillCharging = MenuBarIconInputs(isCharging: true, chargingRecentlyCompleted: true, pluggedIn: true)
        XCTAssertEqual(MenuBarIconState.resolve(stillCharging), .charging)

        // Stopped, target reached: the brief acknowledgement.
        let done = MenuBarIconInputs(isCharging: false, chargingRecentlyCompleted: true, pluggedIn: true)
        XCTAssertEqual(MenuBarIconState.resolve(done), .chargingComplete)

        // A remote command still in flight is more current than the acknowledgement.
        let doneButBusy = MenuBarIconInputs(
            isCharging: false, chargingRecentlyCompleted: true,
            pluggedIn: true, remoteCommandInProgress: true
        )
        XCTAssertEqual(MenuBarIconState.resolve(doneButBusy), .remoteOperation)
    }

    @Test
    func statesAreOrderedByPriority() {
        XCTAssertEqual(MenuBarIconState.allCases, MenuBarIconState.allCases.sorted())
        XCTAssertEqual(MenuBarIconState.allCases.max(), .warning)
        XCTAssertTrue(MenuBarIconState.warning > MenuBarIconState.remoteOperation)
        XCTAssertTrue(MenuBarIconState.remoteOperation > MenuBarIconState.charging)
        XCTAssertTrue(MenuBarIconState.charging > MenuBarIconState.climate)
        XCTAssertTrue(MenuBarIconState.climate > MenuBarIconState.connected)
        XCTAssertTrue(MenuBarIconState.connected > MenuBarIconState.normal)
    }

    // MARK: - What animates

    @Test
    func onlyChargingAndRemoteOperationAnimate() {
        for state in MenuBarIconState.allCases {
            let expected = (state == .charging || state == .remoteOperation)
            XCTAssertEqual(state.isAnimated, expected, "\(state) animation flag")
            XCTAssertEqual(state.pulseProfile != nil, expected, "\(state) pulse profile presence")
        }
    }

    @Test
    func chargingBreathMatchesTheSharedTokenAndStaysFrugal() throws {
        let charging = try XCTUnwrap(MenuBarIconState.charging.pulseProfile)
        XCTAssertEqual(charging.cycle, Motion.menuBarBreathCycle)
        XCTAssertEqual(charging.frames, Motion.menuBarBreathFrames)
        // ~5 fps or slower.
        XCTAssertTrue(charging.tickInterval >= 0.15)
        // A gentle swell, never a flash: alpha stays high and moves a little.
        XCTAssertTrue(charging.minAlpha >= 0.4 && charging.minAlpha < charging.maxAlpha)
        XCTAssertTrue(charging.maxAlpha <= 1.0)

        // The remote-op shimmer is quicker and shallower, so it reads differently.
        let remote = try XCTUnwrap(MenuBarIconState.remoteOperation.pulseProfile)
        XCTAssertTrue(remote.cycle < charging.cycle)
        XCTAssertTrue(remote.minAlpha > charging.minAlpha)
    }

    // MARK: - Reading the signals off a snapshot

    @Test
    func inputsFromNoStateOnlyCarryTheCommandFlag() {
        let idle = MenuBarIconState.inputs(for: nil, remoteCommandInProgress: false, chargingRecentlyCompleted: true)
        XCTAssertEqual(idle, MenuBarIconInputs())

        let busy = MenuBarIconState.inputs(for: nil, remoteCommandInProgress: true, chargingRecentlyCompleted: false)
        XCTAssertEqual(MenuBarIconState.resolve(busy), .remoteOperation)
    }

    @Test
    func inputsReadChargingClimateAndFaultFromTheSnapshot() {
        let charging = MenuBarIconState.inputs(
            for: Self.state(charging: .charging, connection: .connected),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        XCTAssertTrue(charging.isCharging)
        XCTAssertTrue(charging.pluggedIn)
        XCTAssertFalse(charging.isCritical)

        let heating = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, climate: .heating),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        XCTAssertTrue(heating.climateActive)
        XCTAssertFalse(heating.pluggedIn)

        let idleClimate = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, climate: .idle),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        XCTAssertFalse(idleClimate.climateActive)

        let faulted = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .fault),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        XCTAssertTrue(faulted.chargingFault)
        XCTAssertTrue(faulted.isCritical)

        let alarmed = MenuBarIconState.inputs(
            for: Self.state(charging: .idle, connection: .disconnected, alarm: true),
            remoteCommandInProgress: false, chargingRecentlyCompleted: false
        )
        XCTAssertTrue(alarmed.alarmTriggered)
        XCTAssertEqual(MenuBarIconState.resolve(alarmed), .warning)
    }

    // MARK: - Fixture

    private static func state(
        charging: ChargingState,
        connection: ChargerConnection,
        climate: ClimateActivity? = nil,
        alarm: Bool = false
    ) -> VehicleState {
        VehicleState(
            batteryPercentage: 55,
            rangeKm: 240,
            chargingState: charging,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: charging.isActivelyCharging ? 11_000 : nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: charging.isActivelyCharging ? .ac : .none,
            chargerConnection: connection,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            vin: "YS2P2000000000042",
            ownerFirstName: nil,
            odometerKm: 12_000,
            exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: alarm),
            climateStatus: climate.map {
                VehicleClimateStatus(activity: $0, timeRemainingMinutes: nil, timerTriggered: false)
            },
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
    }
}
