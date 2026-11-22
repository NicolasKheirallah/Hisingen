import Foundation
import Testing
@testable import Hisingen

/// The status-item menu's timer, OTA and charge-location rows.
///
/// The menu is an AppKit surface with no testable view tree, so the rules that decide what a
/// row says and whether it is offered live in `MenuBarQuickControls`, and these tests are what
/// keeps the menu from drifting away from the Controls tab it borrows its gate from.
@MainActor
struct MenuBarQuickControlsTests {
    private let everyRelevantFeature: Set<AppFeature> = [
        .remoteSchedules, .remoteOTA, .chargeLocations, .remoteCharging
    ]

    private func makeGate(
        for state: VehicleState,
        inFlight: Bool = false,
        features: Set<AppFeature>? = nil,
        brand: VehicleBrand = .polestar
    ) -> (ScopedPreferences, ControlsCommandGate) {
        let scoped = ScopedPreferences(label: "menubar-quick-controls")
        var selection = scoped.store.features
        for feature in features ?? everyRelevantFeature {
            selection.set(feature, enabled: true)
        }
        scoped.store.features = selection
        let gate = ControlsCommandGate(
            state: state,
            brand: brand,
            preferences: scoped.store,
            remoteCommandInProgress: inFlight,
            inFlightCommandID: nil,
            onRemoteCommand: { _ in }
        )
        return (scoped, gate)
    }

    private func chargingWindow(isActive: Bool = true) -> VehicleSchedule {
        VehicleSchedule(
            backendID: "charge-window", index: 0, kind: .globalCharging,
            startHour: 22, startMinute: 0, endHour: 6, endMinute: 0,
            weekdays: [], isActive: isActive
        )
    }

    private func climateTimer(
        backendID: String? = "climate-1",
        oneShotDate: Date? = nil,
        isActive: Bool = true
    ) -> VehicleSchedule {
        VehicleSchedule(
            backendID: backendID, index: 1, kind: .climate,
            startHour: 7, startMinute: 30, endHour: nil, endMinute: nil,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            isActive: isActive, oneShotDate: oneShotDate
        )
    }

    private func state(
        schedules: [VehicleSchedule] = [],
        climateTimers: [VehicleSchedule] = [],
        software: VehicleSoftwareInfo? = nil,
        locations: [ChargeLocationSnapshot] = []
    ) -> VehicleState {
        var state = vehicle()
        state.energy.schedules = schedules
        state.climateTimers = climateTimers
        state.softwareInfo = software
        state.energy.locations = locations
        return state
    }

    private func savedLocation(
        id: String,
        alias: String,
        optimisedCharging: Bool,
        mode: Int
    ) -> ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: id, alias: alias, latitude: nil, longitude: nil,
            ampLimit: 16, minimumSoc: 0,
            optimisedChargingEnabled: optimisedCharging,
            optimisedChargingMode: mode, kind: 2
        )
    }

    // MARK: - Timers

    @Test func chargingWindowAndCabinTimersBecomeRows() throws {
        try withPinnedInterfaceLanguage {
            let car = state(
                schedules: [chargingWindow()],
                climateTimers: [climateTimer()]
            )
            let (scoped, gate) = makeGate(for: car)
            _ = scoped

            let rows = MenuBarQuickControls.timerRows(for: car, gate: gate)

            #expect(rows.count == 2)
            let window = try #require(rows.first { $0.title.hasPrefix(ScheduleKind.globalCharging.title) })
            #expect(window.isOn == true)
            #expect(window.title.contains(Format.clockTime(hour: 22)))
            let climate = try #require(rows.first { $0.title.hasPrefix(ScheduleKind.climate.title) })
            #expect(climate.title.contains("Mon, Tue, Wed, Thu, Fri"))
        }
    }

    @Test func pausingATimerFlipsOnlyItsEnabledState() {
        let car = state(schedules: [chargingWindow(isActive: true)])
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        let row = MenuBarQuickControls.timerRows(for: car, gate: gate).first

        #expect(row?.command == .setGlobalChargeTimer(chargingWindow(isActive: false)))
        // The row is offered as a switch: pressing it disables the timer without losing its
        // backend identity, its window or its index.
        #expect(row?.isOn == true)
    }

    @Test func aPausedTimerIsOfferedAsAFreshEnable() {
        let car = state(schedules: [chargingWindow(isActive: false)])
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        let row = MenuBarQuickControls.timerRows(for: car, gate: gate).first

        #expect(row?.isOn == false)
        #expect(row?.command == .setGlobalChargeTimer(chargingWindow(isActive: true)))
    }

    @Test func timersTheAppCannotWriteAreLeftOut() {
        let locationTimer = VehicleSchedule(
            backendID: "location-1", index: 0, kind: .locationCharging,
            startHour: 1, startMinute: 0, endHour: 5, endMinute: 0,
            weekdays: [], isActive: true
        )
        let departure = VehicleSchedule(
            backendID: "departure-1", index: 1, kind: .departure,
            startHour: 8, startMinute: 0, endHour: nil, endMinute: nil,
            weekdays: [], isActive: true
        )
        let car = state(
            schedules: [locationTimer, departure],
            climateTimers: [
                climateTimer(backendID: nil),
                climateTimer(backendID: "one-shot", oneShotDate: Date().addingTimeInterval(3_600))
            ]
        )
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        #expect(MenuBarQuickControls.timerRows(for: car, gate: gate).isEmpty)
    }

    @Test func aBusyCommandKeepsTheRowVisibleWithItsReason() {
        let car = state(schedules: [chargingWindow()])
        let (scoped, gate) = makeGate(for: car, inFlight: true)
        _ = scoped

        let row = MenuBarQuickControls.timerRows(for: car, gate: gate).first

        #expect(row != nil)
        #expect(row?.availability == .unavailableWhileBusy)
        // The sentence the menu shows as the row's tooltip.
        #expect(row?.availability.shortReason?.isEmpty == false)
    }

    @Test func aStaleReadingBlocksTheRowWithoutHidingIt() {
        var car = state(schedules: [chargingWindow()])
        car.freshness.fetchedAt = Date().addingTimeInterval(-20 * 60)
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        let row = MenuBarQuickControls.timerRows(for: car, gate: gate).first

        #expect(row?.availability == .unavailableUntilRefresh)
    }

    @Test func turningTheSchedulesFeatureOffLeavesTheMenuOut() {
        let car = state(schedules: [chargingWindow()])
        let (scoped, gate) = makeGate(for: car, features: [.remoteOTA, .chargeLocations])
        _ = scoped

        #expect(MenuBarQuickControls.timerRows(for: car, gate: gate).isEmpty)
    }

    @Test func theTimersSectionOnlyAppearsWhenTheGateCouldAllowATimer() {
        let car = state(schedules: [chargingWindow()])
        let (enabled, enabledGate) = makeGate(for: car)
        _ = enabled
        #expect(MenuBarQuickControls.canOfferTimers(gate: enabledGate))

        let (scoped, gate) = makeGate(for: car, features: [.remoteOTA, .chargeLocations])
        _ = scoped
        #expect(!MenuBarQuickControls.canOfferTimers(gate: gate))
    }

    @Test func aProviderThatCannotWriteTimersGetsNoTimersSection() {
        var car = vehicle(brand: .volvo)
        car.energy.schedules = [chargingWindow()]
        let (scoped, gate) = makeGate(for: car, brand: .volvo)
        _ = scoped

        // Volvo's command surface has no timer write, so the section is left out rather than
        // shown with an empty "No timers reported." row.
        #expect(!MenuBarQuickControls.canOfferTimers(gate: gate))
        #expect(MenuBarQuickControls.timerRows(for: car, gate: gate).isEmpty)
    }

    // MARK: - Software updates

    @Test func aDownloadedUpdateOffersInstallAndTheCardsDelays() {
        withPinnedInterfaceLanguage {
            let car = state(software: VehicleSoftwareInfo(version: "3.1", state: .downloaded))
            let (scoped, gate) = makeGate(for: car)
            _ = scoped

            let rows = MenuBarQuickControls.softwareRows(for: car.softwareInfo, gate: gate)

            #expect(rows.map(\.kind) == [
                .installNow,
                .schedule(delayMinutes: 120),
                .schedule(delayMinutes: 480),
                .schedule(delayMinutes: 720)
            ])
            #expect(rows.map(\.title) == ["Install Update Now", "In 2 h", "In 8 h", "In 12 h"])
            #expect(rows[1].command == .scheduleOTA(delayMinutes: 120))
        }
    }

    @Test func aScheduledUpdateOffersInstallNowAndCancel() {
        let car = state(software: VehicleSoftwareInfo(
            version: "3.1", state: .scheduled, scheduledAt: Date().addingTimeInterval(7_200)
        ))
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        let rows = MenuBarQuickControls.softwareRows(for: car.softwareInfo, gate: gate)

        #expect(rows.map(\.kind) == [.installNow, .cancel])
        #expect(rows.last?.command == .cancelOTA)
    }

    @Test func statesWithNothingToDoOfferNoRows() {
        let (scoped, gate) = makeGate(for: vehicle())
        _ = scoped

        for softwareState: SoftwareUpdateState in [
            .available, .downloading, .installing, .failed, .completed, .unknown
        ] {
            let software = VehicleSoftwareInfo(version: "3.1", state: softwareState)
            #expect(MenuBarQuickControls.softwareRows(for: software, gate: gate).isEmpty)
        }
        #expect(MenuBarQuickControls.softwareRows(for: nil, gate: gate).isEmpty)
    }

    @Test func theMenuScheduleDelaysAreTheCardsDelays() {
        #expect(MenuBarQuickControls.softwareScheduleDelays == [120, 480, 720])
    }

    @Test func turningTheOTAFeatureOffLeavesTheMenuOut() {
        let car = state(software: VehicleSoftwareInfo(version: "3.1", state: .downloaded))
        let (scoped, gate) = makeGate(for: car, features: [.remoteSchedules, .chargeLocations, .remoteCharging])
        _ = scoped

        #expect(MenuBarQuickControls.softwareRows(for: car.softwareInfo, gate: gate).isEmpty)
    }

    // MARK: - Charge locations

    @Test func eachSavedLocationOffersItsOptimisedChargingSwitch() {
        withPinnedInterfaceLanguage {
            let car = state(locations: [
                savedLocation(id: "home", alias: "Home", optimisedCharging: true, mode: 1),
                savedLocation(id: "work", alias: "Work", optimisedCharging: false, mode: 2)
            ])
            let (scoped, gate) = makeGate(for: car)
            _ = scoped

            let rows = MenuBarQuickControls.locationRows(for: car, gate: gate)

            #expect(rows.map(\.id) == ["home", "work"])
            #expect(rows.map(\.isOn) == [true, false])
            #expect(rows[0].title == "Optimised charging · Home")
            #expect(rows[0].command == .setChargeLocationOptimisedCharging(id: "home", enabled: false))
            #expect(rows[1].command == .setChargeLocationOptimisedCharging(id: "work", enabled: true))
        }
    }

    @Test func aLocationWithoutOptimisedChargingIsNotAListedSwitch() {
        let car = state(locations: [
            savedLocation(id: "home", alias: "Home", optimisedCharging: false, mode: 0)
        ])
        let (scoped, gate) = makeGate(for: car)
        _ = scoped

        #expect(MenuBarQuickControls.locationRows(for: car, gate: gate).isEmpty)
    }

    @Test func privacyRedactionHidesTheLocationName() {
        let car = state(locations: [
            savedLocation(id: "home", alias: "Home", optimisedCharging: true, mode: 1)
        ])
        let (scoped, gate) = makeGate(for: car)
        scoped.store.privacyRedactionEnabled = true

        let row = MenuBarQuickControls.locationRows(for: car, gate: gate).first

        #expect(row?.title == L10n.text("Optimised charging") + " · " + L10n.text("Saved charge location"))
    }

    @Test func theChargeLocationsFeatureGatesBothSavingAndSwitching() {
        let car = state(locations: [
            savedLocation(id: "home", alias: "Home", optimisedCharging: true, mode: 1)
        ])
        let (scoped, gate) = makeGate(for: car, features: [.remoteSchedules, .remoteOTA, .remoteCharging])
        _ = scoped

        #expect(MenuBarQuickControls.locationRows(for: car, gate: gate).isEmpty)
        #expect(!MenuBarQuickControls.canSaveCurrentLocation(in: car, gate: gate))
    }

    @Test func savingTheCurrentLocationNeedsTheSameGateAsTheCardsAddHereButton() {
        let car = state()
        let (allowed, allowedGate) = makeGate(for: car)
        _ = allowed
        #expect(MenuBarQuickControls.canSaveCurrentLocation(in: car, gate: allowedGate))

        // `createChargeLocationAtCar` belongs to the remote-charging feature, and the card's
        // "Add here" is disabled by the same question.
        let (scoped, gate) = makeGate(for: car, features: [.remoteSchedules, .remoteOTA, .chargeLocations])
        _ = scoped
        #expect(!MenuBarQuickControls.canSaveCurrentLocation(in: car, gate: gate))
    }

    // MARK: - Row visibility rule

    @Test func permanentRefusalsAreHiddenAndTemporaryOnesStayVisible() {
        #expect(MenuBarQuickControls.offersRow(.available))
        #expect(MenuBarQuickControls.offersRow(.unavailableWhileBusy))
        #expect(MenuBarQuickControls.offersRow(.unavailableUntilRefresh))
        #expect(!MenuBarQuickControls.offersRow(.disabledBySettings))
        #expect(!MenuBarQuickControls.offersRow(.unsupportedByVehicle))
        #expect(!MenuBarQuickControls.offersRow(.unimplementedByProvider(reason: nil)))
        #expect(!MenuBarQuickControls.offersRow(.notVehicleOwner))
        #expect(!MenuBarQuickControls.offersRow(.requiresAccountApproval))
        #expect(!MenuBarQuickControls.offersRow(.invalidSettings("nope")))
    }

    /// The menu sends through `gate.send`, which refuses anything the gate would disable. That
    /// guard is what makes a row and its command agree even if the vehicle changed while the
    /// menu was open.
    @Test func theGateRefusesTheCommandItsRowWouldDisable() {
        var car = state(schedules: [chargingWindow()])
        car.freshness.fetchedAt = Date().addingTimeInterval(-20 * 60)
        let (scoped, _) = makeGate(for: car)
        _ = scoped
        var sent: [RemoteCommand] = []
        let sendingGate = ControlsCommandGate(
            state: car, brand: .polestar, preferences: scoped.store,
            remoteCommandInProgress: false, inFlightCommandID: nil,
            onRemoteCommand: { sent.append($0) }
        )

        sendingGate.send(.setGlobalChargeTimer(chargingWindow(isActive: false)))

        #expect(sent.isEmpty)
    }
}
