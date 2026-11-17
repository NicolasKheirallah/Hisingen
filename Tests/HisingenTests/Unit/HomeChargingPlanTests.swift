import Foundation
import Testing
@testable import Hisingen

@Suite("Home Assistant charging plan models")
struct HomeChargingPlanTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func planStatus() throws -> HomeChargingPlanStatus {
        let entity = try JSONDecoder().decode(HAEntityState.self, from: fixtureData("home-assistant-plan-status"))
        return try #require(HomeChargingPlanStatus(entity: entity))
    }

    @Test("The plan status sensor decodes into windows, target, deadline and warnings")
    func statusDecodes() throws {
        let status = try planStatus()
        #expect(status.phase == .scheduled)
        #expect(status.planID == "plan-7f3a")
        #expect(status.target == HomePlanTarget(kind: .addKwh, value: 18.0))
        #expect(status.deadline == HATimestamp.parse("2026-11-17T06:00:00+00:00"))
        #expect(status.windows.count == 1)
        #expect(status.windows[0].end.timeIntervalSince(status.windows[0].start) == 150 * 60)
        #expect(status.windows[0].averagePricePerKwh == 0.43)
        #expect(status.rateKw == 7.2)
        #expect(status.estimatedCost == 7.74)
        #expect(status.warnings == ["prices_missing"])
        #expect(!status.isHeld && !status.hasOverride)
    }

    @Test("An unknown phase is not guessed")
    func unknownPhase() {
        #expect(HomeChargingPlanStatus(entity: HAEntityState(entityID: "sensor.x", state: "bananas")) == nil)
    }

    @Test("The submit payload carries the charger entities, an absolute deadline and the target")
    func requestPayload() throws {
        let request = HomeChargingPlanRequest(
            planID: "plan-1", chargerID: "NX1234567", entities: NexBlueFixture.map,
            target: HomePlanTarget(kind: .reachPercent, value: 80),
            deadline: HATimestamp.parse("2026-11-17T06:00:00+00:00")!, timeZoneIdentifier: "Europe/Stockholm",
            vehicleName: "Polestar 2", usableCapacityKwh: 75, chargingLossFactor: 1.1,
            tibberHome: nil, networkFeeOrePerKwh: 25, rateHintKw: 7.4)
        let object = try #require(request.actionData.objectValue)
        #expect(object["deadline"]?.stringValue == "2026-11-17T06:00:00Z")
        #expect(object["time_zone"]?.stringValue == "Europe/Stockholm")
        #expect(object["target"]?.objectValue?["type"]?.stringValue == "reach_percent")
        let charger = try #require(object["charger"]?.objectValue)
        #expect(charger["switch"]?.stringValue == "switch.nx1234567_charging")
        #expect(charger["vehicle_battery"]?.stringValue == "sensor.polestar_2_battery")
        // Nothing secret travels with a plan.
        let text = String(decoding: try JSONEncoder().encode(request.actionData), as: UTF8.self)
        #expect(!text.lowercased().contains("token"))
    }

    // MARK: - Capabilities

    private func battery(_ value: String = "62", unit: String? = "%", age: TimeInterval) -> HAEntityState {
        HAEntityState(entityID: "sensor.polestar_2_battery", state: value,
                      attributes: unit.map { ["unit_of_measurement": .string($0)] } ?? [:], lastUpdated: now.addingTimeInterval(-age))
    }

    @Test("Reach a percentage is offered only for a fresh, verified battery sensor")
    func reachPercentCapability() {
        #expect(HomeChargingCapabilities.evaluate(batterySensor: battery(age: 60), configured: true, now: now).supportsReachPercent)
        #expect(HomeChargingCapabilities.evaluate(batterySensor: nil, configured: false, now: now).reachPercentGap == .noSensorConfigured)
        #expect(HomeChargingCapabilities.evaluate(batterySensor: nil, configured: true, now: now).reachPercentGap == .sensorUnavailable)
        #expect(HomeChargingCapabilities.evaluate(batterySensor: battery("unavailable", age: 60), configured: true, now: now)
            .reachPercentGap == .sensorUnavailable)
        #expect(HomeChargingCapabilities.evaluate(batterySensor: battery(unit: "kWh", age: 60), configured: true, now: now)
            .reachPercentGap == .sensorNotABattery)
        #expect(HomeChargingCapabilities.evaluate(batterySensor: battery("140", age: 60), configured: true, now: now)
            .reachPercentGap == .sensorNotABattery)
        let stale = HomeChargingCapabilities.evaluate(batterySensor: battery(age: 3 * 3_600), configured: true, now: now)
        guard case .sensorStale(let age) = stale.reachPercentGap else { Issue.record("expected stale"); return }
        #expect(age >= 3 * 3_600)
        #expect(!stale.supportsReachPercent)
        #expect(stale.supportsAddKwh)
        #expect(stale.reachPercentExplanation != nil)
        #expect(HomeChargingCapabilities().reachPercentExplanation == nil)
    }

    // MARK: - Scheduler ownership

    private func record(deadlineIn: TimeInterval = 8 * 3_600) -> HomeChargingPlanRecord {
        HomeChargingPlanRecord(planID: "plan-1", vin: "YSMTEST", chargerID: "NX1234567",
                               deadline: now.addingTimeInterval(deadlineIn), submittedAt: now)
    }

    @Test("While Home Assistant runs a plan for the vehicle, the vehicle-side scheduler must defer")
    func ownership() {
        #expect(HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: record(), now: now))
        #expect(HomeChargingOwnership.isHomeAssistantOwned(vin: "ysmtest", record: record(), now: now))
        // Another vehicle's scheduler is not held back.
        #expect(!HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMOTHER", record: record(), now: now))
        #expect(!HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: nil, now: now))
        // Ownership outlives an unreachable Home Assistant and runs a little past the deadline.
        let afterDeadline = now.addingTimeInterval(8 * 3_600 + 1_800)
        #expect(HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: record(), now: afterDeadline))
        let longAfter = now.addingTimeInterval(8 * 3_600 + HomeChargingOwnership.graceAfterDeadline + 1)
        #expect(!HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: record(), now: longAfter))
    }

    @Test("A finished, cancelled or expired plan hands the scheduler back; a stale or foreign status does not")
    func ownershipEnds() {
        let done = HomeChargingPlanStatus(phase: .complete, planID: "plan-1")
        let closed = HomeChargingOwnership.updated(record(), with: done, now: now.addingTimeInterval(600))
        #expect(closed?.endedAt != nil)
        #expect(!HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: closed, now: now.addingTimeInterval(601)))

        let running = HomeChargingPlanStatus(phase: .charging, planID: "plan-1")
        #expect(HomeChargingOwnership.updated(record(), with: running, now: now)?.endedAt == nil)
        // A different plan's terminal status is not ours.
        let foreign = HomeChargingPlanStatus(phase: .cancelled, planID: "older-plan")
        #expect(HomeChargingOwnership.updated(record(), with: foreign, now: now)?.endedAt == nil)
        // An idle sensor with no plan id from before the submission is the previous plan's leftovers.
        let leftover = HomeChargingPlanStatus(phase: .idle, updatedAt: now.addingTimeInterval(-60))
        #expect(HomeChargingOwnership.updated(record(), with: leftover, now: now)?.endedAt == nil)
        let cancelled = HomeChargingPlanStatus(phase: .idle, updatedAt: now.addingTimeInterval(60))
        #expect(HomeChargingOwnership.updated(record(), with: cancelled, now: now.addingTimeInterval(61))?.endedAt != nil)
    }

    @Test("The plan record survives a relaunch through the store, and the token is kept apart")
    @MainActor
    func recordPersistsAcrossRelaunch() throws {
        let scoped = ScopedPreferences(label: "home-plan-record")
        var store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        store.planRecord = record()
        store.pairing = NexBlueFixture.pairing()
        store.address = "http://homeassistant.local:8123"
        try store.saveToken("secret-token")

        // A new store over the same defaults is a relaunch.
        store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        #expect(store.planRecord == record())
        #expect(store.pairing == NexBlueFixture.pairing())
        #expect(try store.token() == "secret-token")
        #expect(HomeChargingOwnership.isHomeAssistantOwned(vin: "YSMTEST", record: store.planRecord, now: now))

        // Nothing credential-like sits in UserDefaults, and the settings archive carries none of it.
        let blob = scoped.defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!blob.contains("secret-token"))
        let archive = try scoped.store.exportSettingsPropertyList()
        let archiveText = String(decoding: archive, as: UTF8.self)
        #expect(!archiveText.contains("home_charging"))
        #expect(!archiveText.contains("secret-token"))
        #expect(!archiveText.contains("NX1234567"))

        store.clearPairing()
        #expect(store.pairing == nil && store.planRecord == nil)
        #expect(store.address != nil)
        store.eraseAll()
        #expect(store.address == nil)
        #expect(try store.token() == nil)
    }
}
