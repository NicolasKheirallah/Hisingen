import Foundation
import Testing
@testable import Hisingen

/// Two chargers per install: an existing single pairing still loads, a second is added beside it,
/// and each keeps its own plan record. The storage half is what makes the upgrade safe, so it is
/// tested directly rather than only through the model.
@Suite(.serialized)
@MainActor
struct SecondChargerStorageTests {
    private let vin = "YSMSECONDCHARGER01"
    private let otherVIN = "YSMSECONDCHARGER02"

    private func store(_ scoped: ScopedPreferences) -> HomeChargingStore {
        HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
    }

    private func pairing(
        chargerID: String, name: String, vin: String, locationID: String? = "home-loc",
        source: ChargerSource = .homeAssistant
    ) -> HomeChargingPairing {
        HomeChargingPairing(
            baseURL: "http://homeassistant.local:8123", chargerID: chargerID, chargerName: name,
            entities: HomeChargerEntityMap(chargingSwitch: "switch.\(chargerID)"),
            vin: vin, locationID: locationID, locationAlias: "Home",
            timeZoneIdentifier: "Europe/Stockholm", source: source)
    }

    // MARK: - Upgrade

    @Test
    func anInstallWithOnlyTheOldSinglePairingStillLoadsIt() {
        let scoped = ScopedPreferences(label: "SecondChargerLegacy")
        let legacy = pairing(chargerID: "nexblue-1", name: "Garage", vin: vin)
        scoped.defaults.set(
            try? JSONEncoder.sortedISO.encode(legacy), forKey: HomeChargingStore.pairingKey)

        let loaded = store(scoped)

        #expect(loaded.pairings.map(\.identity) == [legacy.identity])
        #expect(loaded.pairing?.chargerName == "Garage")
    }

    @Test
    func anInstallWithNoPairingLoadsNothing() {
        let scoped = ScopedPreferences(label: "SecondChargerEmpty")
        #expect(store(scoped).pairings.isEmpty)
    }

    @Test
    func addingASecondChargerKeepsTheFirstAndMirrorsTheLegacyKey() throws {
        let scoped = ScopedPreferences(label: "SecondChargerAdd")
        let stored = store(scoped)
        let first = pairing(chargerID: "nexblue-1", name: "Garage", vin: vin)
        let second = pairing(chargerID: "nexblue-2", name: "Carport", vin: vin)

        stored.upsert(first)
        stored.upsert(second)

        #expect(stored.pairings.map(\.chargerName) == ["Garage", "Carport"])
        // The list is authoritative, and the legacy key still names the first charger so an older
        // build reading this install finds one instead of none.
        let legacy = try #require(scoped.defaults.data(forKey: HomeChargingStore.pairingKey))
        #expect(try JSONDecoder.iso.decode(HomeChargingPairing.self, from: legacy).chargerID == "nexblue-1")
    }

    @Test
    func pairingTheSameChargerAgainReplacesItInsteadOfDuplicating() {
        let scoped = ScopedPreferences(label: "SecondChargerReplace")
        let stored = store(scoped)
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage", vin: vin))
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage renamed", vin: vin))

        #expect(stored.pairings.count == 1)
        #expect(stored.pairing?.chargerName == "Garage renamed")
    }

    @Test
    func theSameChargerOnTwoVehiclesIsTwoPairings() {
        let scoped = ScopedPreferences(label: "SecondChargerTwoCars")
        let stored = store(scoped)
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage", vin: vin))
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage", vin: otherVIN))

        #expect(stored.pairings.count == 2)
        #expect(Set(stored.pairings.map(\.identity)).count == 2)
    }

    @Test
    func removingOneChargerLeavesTheOtherAndItsRecord() throws {
        let scoped = ScopedPreferences(label: "SecondChargerRemove")
        let stored = store(scoped)
        let first = pairing(chargerID: "nexblue-1", name: "Garage", vin: vin)
        let second = pairing(chargerID: "nexblue-2", name: "Carport", vin: vin)
        stored.upsert(first)
        stored.upsert(second)
        let firstPlan = HomeChargingPlanRecord(
            planID: "plan-1", vin: vin, chargerID: first.chargerID,
            deadline: Date(timeIntervalSince1970: 1_790_000_000), submittedAt: Date(timeIntervalSince1970: 1_789_000_000))
        let secondPlan = HomeChargingPlanRecord(
            planID: "plan-2", vin: vin, chargerID: second.chargerID,
            deadline: Date(timeIntervalSince1970: 1_790_000_000), submittedAt: Date(timeIntervalSince1970: 1_789_000_000))
        stored.setPlanRecord(firstPlan, for: first)
        stored.setPlanRecord(secondPlan, for: second)

        stored.removePairing(identity: first.identity)

        #expect(stored.pairings.map(\.chargerID) == ["nexblue-2"])
        #expect(stored.planRecord(for: second)?.planID == "plan-2")
        #expect(stored.planRecord(for: first) == nil)
    }

    // MARK: - Plan records

    @Test
    func aLegacyPlanRecordBelongsToTheChargerThatWroteIt() {
        let scoped = ScopedPreferences(label: "SecondChargerLegacyPlan")
        let stored = store(scoped)
        let first = pairing(chargerID: "nexblue-1", name: "Garage", vin: vin)
        let second = pairing(chargerID: "nexblue-2", name: "Carport", vin: vin)
        stored.upsert(first)
        stored.upsert(second)
        let legacy = HomeChargingPlanRecord(
            planID: "plan-legacy", vin: vin, chargerID: "nexblue-2",
            deadline: Date(timeIntervalSince1970: 1_790_000_000), submittedAt: Date(timeIntervalSince1970: 1_789_000_000))
        scoped.defaults.set(try? JSONEncoder.sortedISO.encode(legacy), forKey: HomeChargingStore.planRecordKey)

        // The record names nexblue-2, so only that charger reads it – the first must not inherit a
        // plan it never ran.
        #expect(stored.planRecord(for: second)?.planID == "plan-legacy")
        #expect(stored.planRecord(for: first) == nil)
    }

    @Test
    func perChargerRecordsRoundTripIndependently() {
        let scoped = ScopedPreferences(label: "SecondChargerPlanRecords")
        let stored = store(scoped)
        let first = pairing(chargerID: "nexblue-1", name: "Garage", vin: vin)
        let second = pairing(chargerID: "nexblue-2", name: "Carport", vin: vin)
        stored.upsert(first)
        stored.upsert(second)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        stored.setPlanRecord(HomeChargingPlanRecord(planID: "a", vin: vin, chargerID: first.chargerID, deadline: now, submittedAt: now), for: first)
        stored.setPlanRecord(HomeChargingPlanRecord(planID: "b", vin: vin, chargerID: second.chargerID, deadline: now, submittedAt: now), for: second)

        // A relaunch is a second store over the same defaults.
        let reloaded = store(scoped)
        #expect(reloaded.planRecord(for: first)?.planID == "a")
        #expect(reloaded.planRecord(for: second)?.planID == "b")

        reloaded.setPlanRecord(nil, for: first)
        #expect(reloaded.planRecord(for: first) == nil)
        #expect(reloaded.planRecord(for: second)?.planID == "b")
    }

    @Test
    func theLegacySinglePairingSetterStillReplacesEverything() {
        let scoped = ScopedPreferences(label: "SecondChargerLegacySetter")
        let stored = store(scoped)
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage", vin: vin))
        stored.upsert(pairing(chargerID: "nexblue-2", name: "Carport", vin: vin))

        stored.pairing = pairing(chargerID: "zaptec-1", name: "Only one", vin: vin, source: .zaptec)

        #expect(stored.pairings.count == 1)
        #expect(stored.pairing?.chargerName == "Only one")
    }

    @Test
    func clearingPairingsErasesTheListAndTheMirror() {
        let scoped = ScopedPreferences(label: "SecondChargerClear")
        let stored = store(scoped)
        stored.upsert(pairing(chargerID: "nexblue-1", name: "Garage", vin: vin))
        stored.upsert(pairing(chargerID: "nexblue-2", name: "Carport", vin: vin))

        stored.clearPairing()

        #expect(stored.pairings.isEmpty)
        #expect(scoped.defaults.data(forKey: HomeChargingStore.pairingsKey) == nil)
        #expect(scoped.defaults.data(forKey: HomeChargingStore.pairingKey) == nil)
    }
}
