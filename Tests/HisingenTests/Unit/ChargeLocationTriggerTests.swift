import Foundation
import Testing
@testable import Hisingen

/// Arrival and departure triggers, and the at-charge-location detection they stand on.
///
/// The detection is Hisingen's own: the vehicle snapshot already carries a position and the saved
/// charge locations already carry coordinates, so nothing here needs Location Services. The last
/// test is a guardrail that keeps it that way.
@Suite(.serialized)
@MainActor
struct ChargeLocationTriggerTests {
    private let vin = "YSMLOCATIONTEST0001"
    private let home = (latitude: 57.7089, longitude: 11.9746)
    private let work = (latitude: 57.6400, longitude: 11.9400)
    private let away = (latitude: 59.3293, longitude: 18.0686)

    // MARK: - Transition

    @Test
    func theTransitionNamesWhatChangedBetweenTwoObservations() {
        let atHome = presence("home", alias: "Home")

        #expect(ChargeLocationTransition.between(previous: nil, current: nil) == .none)
        #expect(ChargeLocationTransition.between(previous: atHome, current: atHome) == .none)
        #expect(ChargeLocationTransition.between(previous: nil, current: atHome) == .arrived(atHome))
        #expect(ChargeLocationTransition.between(previous: atHome, current: nil) == .departed(from: atHome))

        let atWork = presence("work", alias: "Work")
        let moved = ChargeLocationTransition.between(previous: atHome, current: atWork)
        #expect(moved == .moved(from: atHome, to: atWork))
        #expect(moved.arrival == atWork)
        #expect(moved.departure == atHome)
    }

    // MARK: - Detection from state

    @Test
    func presenceIsResolvedFromTheStatePositionAndSavedLocations() {
        let state = vehicleState(at: home, locations: [savedHome, savedWork])

        #expect(state.chargeLocationPresence?.locationID == "home")
        #expect(state.chargeLocationPresence?.alias == "Home")
        #expect(state.chargeLocationPresence?.source == .proximity)
    }

    @Test
    func aSavedLocationWithoutCoordinatesIsSkippedRatherThanReadAsNotHere() {
        let noCoordinates = ChargeLocationSnapshot(
            id: "unknown", alias: "No coordinates", latitude: nil, longitude: nil,
            ampLimit: 0, minimumSoc: 0, optimisedChargingEnabled: false,
            optimisedChargingMode: 0, kind: 2)
        let state = vehicleState(at: home, locations: [noCoordinates])

        #expect(state.chargeLocationPresence == nil)
    }

    // MARK: - Triggers

    @Test
    func theFirstSnapshotAfterLaunchOnlyRecordsWhereTheCarIs() async {
        let harness = TriggerHarness(triggers: [trigger(.arrival, .startChargingOverride)])
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))

        #expect(harness.sent.isEmpty)
    }

    @Test
    func arrivingFiresTheArrivalTriggerOnce() async {
        let harness = TriggerHarness(triggers: [trigger(.arrival, .startChargingOverride)])

        // First observation: parked somewhere that is not a saved location.
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))
        #expect(harness.sent.isEmpty)

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))
        #expect(harness.sent == [.startChargingOverride])

        // Another refresh that still reports the same place is not a second arrival.
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))
        #expect(harness.sent == [.startChargingOverride])
    }

    @Test
    func leavingTheSavedLocationFiresTheDepartureTrigger() async {
        let harness = TriggerHarness(triggers: [trigger(.departure, .closeWindows)])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))
        #expect(harness.sent.isEmpty)

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))

        #expect(harness.sent == [.closeWindows])
    }

    @Test
    func movingBetweenTwoSavedLocationsFiresLeaveAndArrive() async {
        let harness = TriggerHarness(triggers: [
            trigger(.departure, .closeWindows),
            trigger(.arrival, .startChargingOverride),
        ])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: work, locations: [savedHome, savedWork]))

        #expect(harness.sent == [.closeWindows, .startChargingOverride])
    }

    @Test
    func aTriggerWatchingOneLocationIgnoresTheOther() async {
        let harness = TriggerHarness(triggers: [
            trigger(.arrival, .startChargingOverride, locationID: "work"),
            trigger(.departure, .closeWindows, locationID: "work"),
        ])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))
        // Leaving home for work: the arrival at work fires, the departure from work does not.
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: work, locations: [savedHome, savedWork]))

        #expect(harness.sent == [.startChargingOverride])
    }

    @Test
    func noTriggersMeansNoSendsEvenWhenTheCarMoves() async {
        let harness = TriggerHarness(triggers: [])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))

        #expect(harness.sent.isEmpty)
    }

    @Test
    func aStoredNonRoutineTriggerIsNotSentUnattended() async {
        let harness = TriggerHarness(triggers: [trigger(.arrival, .unlock)])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))

        #expect(harness.sent.isEmpty)
    }

    @Test
    func aDisabledTriggerNeverFires() async {
        var disabled = trigger(.arrival, .startChargingOverride)
        disabled.isEnabled = false
        let harness = TriggerHarness(triggers: [disabled])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))

        #expect(harness.sent.isEmpty)
    }

    @Test
    func resetObservationsMakesTheNextSnapshotABaselineAgain() async {
        let harness = TriggerHarness(triggers: [trigger(.arrival, .startChargingOverride)])

        await harness.controller.vehicleStateDidUpdate(vehicleState(at: away, locations: [savedHome, savedWork]))
        harness.controller.resetObservations()
        await harness.controller.vehicleStateDidUpdate(vehicleState(at: home, locations: [savedHome, savedWork]))

        #expect(harness.sent.isEmpty)
    }

    // MARK: - Permission guardrail

    @Test
    func detectionNeverAsksForLocationServices() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let automationSources = [
            "Sources/Hisingen/Services/Integration/ChargeLocationTriggerController.swift",
            "Sources/Hisingen/Domain/LocationTrigger.swift",
            "Sources/Hisingen/Domain/ChargeLocationPresence.swift",
            "Sources/Hisingen/App/AppDelegate+Automation.swift",
        ]
        for relative in automationSources {
            let source = try String(contentsOf: packageRoot.appendingPathComponent(relative), encoding: .utf8)
            for forbidden in ["CLLocationManager", "requestWhenInUseAuthorization",
                              "requestAlwaysAuthorization", "startUpdatingLocation"] {
                #expect(
                    !source.contains(forbidden),
                    "\(relative) uses \(forbidden); arrival detection must compare the position the app already reads, without asking for Location Services."
                )
            }
        }

        // And the bundle carries no location usage description, so a permission dialog is not
        // even possible for this feature.
        let plist = try String(
            contentsOf: packageRoot.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        #expect(!plist.contains("NSLocation"))
    }
}

// MARK: - Fixtures

private let presenceTimestamp = Date(timeIntervalSince1970: 1_790_000_000)

extension ChargeLocationTriggerTests {
    fileprivate var savedHome: ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: "home", alias: "Home", latitude: home.latitude, longitude: home.longitude,
            ampLimit: 16, minimumSoc: 0, optimisedChargingEnabled: false,
            optimisedChargingMode: 0, kind: 2)
    }

    fileprivate var savedWork: ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: "work", alias: "Work", latitude: work.latitude, longitude: work.longitude,
            ampLimit: 11, minimumSoc: 0, optimisedChargingEnabled: false,
            optimisedChargingMode: 0, kind: 2)
    }

    fileprivate func presence(_ id: String, alias: String) -> ChargeLocationPresence {
        ChargeLocationPresence(locationID: id, alias: alias, since: presenceTimestamp, source: .proximity)
    }

    fileprivate func trigger(_ event: LocationTrigger.Event, _ command: RemoteCommand,
                             locationID: String? = nil, targetVIN: String? = nil) -> LocationTrigger {
        LocationTrigger(event: event, locationID: locationID, command: command, targetVIN: targetVIN)
    }

    /// A snapshot as the merge produces it: the position and the saved locations are what the
    /// app already holds, and the presence is worked out from them.
    fileprivate func vehicleState(at point: (latitude: Double, longitude: Double),
                                  locations: [ChargeLocationSnapshot]) -> VehicleState {
        var state = vehicle(
            vin: vin,
            location: VehicleLocation(
                latitude: point.latitude, longitude: point.longitude, timestamp: presenceTimestamp),
            fetchedAt: presenceTimestamp)
        state.energy.locations = locations
        return state.mergingLastKnown(from: nil, features: .default)
    }

    @Test
    func triggerTargetVINFiltersByVehicleAndForwardsDestinationVIN() async throws {
        let scoped = ScopedPreferences(label: "TriggerTargetVIN")
        scoped.store.locationTriggers = [
            LocationTrigger(event: .arrival, locationID: "home", command: .lock, targetVIN: "VIN-TARGET"),
            LocationTrigger(event: .arrival, locationID: "home", command: .startChargingOverride)
        ]
        let captured = LockedVINCommands()
        let controller = ChargeLocationTriggerController(preferences: scoped.store) { command, vin in
            captured.append(command: command, vin: vin)
            return .sent
        }

        // Legacy JSON without targetVIN still decodes with nil targetVIN.
        let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","event":"arrival","command":{"lock":{}},"isEnabled":true}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(LocationTrigger.self, from: legacyJSON)
        #expect(decodedLegacy.targetVIN == nil)

        var awayA = vehicle(vin: "VIN-TARGET", battery: 60)
        awayA.chargeLocationPresence = nil
        var awayB = vehicle(vin: "VIN-OTHER", battery: 60)
        awayB.chargeLocationPresence = nil
        await controller.vehicleStateDidUpdate(awayA)
        await controller.vehicleStateDidUpdate(awayB)

        var homeB = awayB
        homeB.chargeLocationPresence = ChargeLocationPresence(locationID: "home", alias: "Home", since: Date(), source: .proximity)
        await controller.vehicleStateDidUpdate(homeB)

        // Only the unpinned trigger fires for VIN-OTHER, forwarding VIN-OTHER cleanly.
        let items = captured.items
        #expect(items.count == 1)
        #expect(items.first?.vin == "VIN-OTHER")
    }
}

@MainActor
private final class TriggerHarness {
    let scoped = ScopedPreferences(label: "ChargeLocationTriggers")
    let box = TriggerSentBox()
    let controller: ChargeLocationTriggerController

    var preferences: PreferencesStore { scoped.store }
    var sent: [RemoteCommand] { box.commands }

    init(triggers: [LocationTrigger]) {
        scoped.store.locationTriggers = triggers
        let box = self.box
        controller = ChargeLocationTriggerController(
            preferences: scoped.store,
            send: { command in
                box.commands.append(command)
                return .sent
            })
    }
}

@MainActor
private final class TriggerSentBox {
    var commands: [RemoteCommand] = []
}

@MainActor
private final class LockedVINCommands {
    var items: [(command: RemoteCommand, vin: String?)] = []
    func append(command: RemoteCommand, vin: String?) { items.append((command, vin)) }
}
