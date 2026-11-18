import Foundation
import Testing
@testable import Hisingen

@Suite("Home charger telemetry")
struct HomeChargerTelemetryTests {
    private let reported = Date(timeIntervalSince1970: 1_780_000_000)

    private func telemetry(status: String = "charging", power: String = "7.31", reportedAt: Date? = nil,
                           powerUnit: String = "kW") -> HomeChargerTelemetry {
        var table = NexBlueFixture.table(status: status, powerKw: power, reportedAt: reportedAt ?? reported)
        table["sensor.nx1234567_power"] = HAEntityState(
            entityID: "sensor.nx1234567_power", state: power, attributes: ["unit_of_measurement": .string(powerUnit)],
            lastReported: reportedAt ?? reported)
        return HomeChargerTelemetry.make(from: table, map: NexBlueFixture.map)
    }

    // MARK: - Decoding

    @Test("The NexBlue fixture decodes, including microsecond timestamps and the freshest timestamp")
    func fixtureDecodes() throws {
        let states = try fixtureStates()
        let charging = try #require(states.first { $0.entityID == "sensor.nx1234567_charging_state" })
        #expect(charging.state == "charging")
        let reportedAt = try #require(charging.lastReported)
        let changedAt = try #require(charging.lastChanged)
        #expect(reportedAt > changedAt)
        #expect(charging.freshestTimestamp == reportedAt)
        #expect(abs(reportedAt.timeIntervalSince1970 - HATimestamp.parse("2026-11-16T01:41:08.100+00:00")!.timeIntervalSince1970) < 0.001)
        let telemetry = HomeChargerTelemetry.make(from: Dictionary(uniqueKeysWithValues: states.map { ($0.entityID, $0) }),
                                                  map: NexBlueFixture.map)
        #expect(telemetry.status?.value == .charging)
        #expect(telemetry.powerKw?.value == 7.31)
        #expect(telemetry.sessionEnergyKwh?.value == 12.42)
        #expect(telemetry.vehicleBatteryPercent?.value == 62)
        // A lock-class binary sensor is on when unlocked, so "off" means locked.
        #expect(telemetry.cableLocked?.value == true)
    }

    @Test("Every NexBlue state token maps to a known status and unknown tokens stay unrecognised")
    func statusMapping() {
        #expect(HomeChargerStatus(haState: "idle") == .unplugged)
        #expect(HomeChargerStatus(haState: "connected") == .pluggedIn)
        #expect(HomeChargerStatus(haState: "charging") == .charging)
        #expect(HomeChargerStatus(haState: "finished") == .finished)
        #expect(HomeChargerStatus(haState: "error") == .error)
        #expect(HomeChargerStatus(haState: "lb_waiting") == .waitingForPower)
        #expect(HomeChargerStatus(haState: "delay_waiting") == .delayedStart)
        #expect(HomeChargerStatus(haState: "ev_waiting") == .waitingForVehicle)
        #expect(HomeChargerStatus(haState: "unavailable") == .unavailable)
        #expect(HomeChargerStatus(haState: "Quantum Mode") == .unrecognised("quantum_mode"))
        // The charging switch reads on for exactly these three, so a start is confirmed by them.
        #expect([HomeChargerStatus.charging, .waitingForPower, .waitingForVehicle]
            .allSatisfy { $0.isChargingEnabled })
        #expect([HomeChargerStatus.pluggedIn, .delayedStart, .finished, .unplugged]
            .allSatisfy { !$0.isChargingEnabled })
    }

    @Test("Existing charging states are reused where they map cleanly")
    func existingStateMapping() {
        #expect(HomeChargerStatus.charging.chargingState == .charging)
        #expect(HomeChargerStatus.finished.chargingState == .complete)
        #expect(HomeChargerStatus.delayedStart.chargingState == .scheduled)
        #expect(HomeChargerStatus.error.chargingState == .fault)
        #expect(HomeChargerStatus.pluggedIn.connection == .connected)
        #expect(HomeChargerStatus.unplugged.connection == .disconnected)
        #expect(HomeChargerStatus.unavailable.connection == .unknown)
    }

    @Test("Watt readings are converted to kilowatts")
    func unitConversion() {
        #expect(telemetry(power: "7310", powerUnit: "W").powerKw?.value == 7.31)
    }

    // MARK: - Stale and unavailable telemetry

    @Test("A reading within the window is current and one past it is stale")
    func staleTelemetry() {
        let live = telemetry()
        #expect(live.freshness(now: reported.addingTimeInterval(120)) == .current(age: 120))
        #expect(live.activity(now: reported.addingTimeInterval(120)) == .charging(powerKw: 7.31))
        let late = reported.addingTimeInterval(HomeChargerTelemetry.defaultStaleAfter + 60)
        guard case .stale(let age) = live.freshness(now: late) else {
            Issue.record("expected stale")
            return
        }
        #expect(age > HomeChargerTelemetry.defaultStaleAfter)
        // A stale charging reading must not be presented as live charging.
        #expect(live.activity(now: late) == .stale)
    }

    @Test("An unavailable charger is reported as unavailable, not as idle")
    func unavailableCharger() {
        let table = NexBlueFixture.table(status: "unavailable", reportedAt: reported)
        let telemetry = HomeChargerTelemetry.make(from: table, map: NexBlueFixture.map)
        #expect(telemetry.status?.value == .unavailable)
        #expect(telemetry.freshness(now: reported) == .unavailable)
        #expect(telemetry.activity(now: reported) == .unavailable)
        #expect(telemetry.unavailableEntities.contains("sensor.nx1234567_charging_state"))
    }

    @Test("No readings at all is no data")
    func noData() {
        let empty = HomeChargerTelemetry.make(from: [:], map: NexBlueFixture.map)
        #expect(empty.freshness(now: reported) == .noData)
        #expect(empty.activity(now: reported) == .unavailable)
    }

    @Test("Charging enabled with a car that draws no power is its own state")
    func zeroPowerWhileEnabled() {
        #expect(telemetry(status: "charging", power: "0.02").activity(now: reported) == .enabledNoDraw)
        #expect(telemetry(status: "ev_waiting", power: "0").activity(now: reported) == .waitingForVehicle)
        #expect(telemetry(status: "lb_waiting", power: "0").activity(now: reported) == .waitingForPower)
        #expect(telemetry(status: "delay_waiting", power: "0").activity(now: reported) == .delayedStart)
        #expect(telemetry(status: "finished", power: "0").activity(now: reported) == .finished)
        #expect(telemetry(status: "error", power: "0").activity(now: reported) == .fault)
    }

    @Test("A charger that is drawing power is charging, whichever waiting token it reports")
    func powerWhileWaitingIsCharging() {
        for status in ["ev_waiting", "lb_waiting", "delay_waiting", "connected", "finished"] {
            #expect(telemetry(status: status, power: "4.2").activity(now: reported) == .charging(powerKw: 4.2))
        }
        // A fault or an unplugged charger keeps its own meaning even if a power reading disagrees.
        #expect(telemetry(status: "error", power: "4.2").activity(now: reported) == .fault)
        #expect(telemetry(status: "idle", power: "4.2").activity(now: reported) == .noCable)
    }

    @Test("A stale power reading does not turn a waiting charger into charging")
    func stalePowerDoesNotOverrideWaiting() {
        var stale = telemetry(status: "ev_waiting", power: "4.2")
        stale.powerKw = .init(value: 4.2, timestamp: reported.addingTimeInterval(-HomeChargerTelemetry.defaultStaleAfter - 60))
        #expect(stale.activity(now: reported) == .waitingForVehicle)
    }

    // MARK: - Connector evidence

    @Test("A current charger reading confirms the connector; otherwise the source is named")
    func connectorEvidence() {
        let live = telemetry(status: "connected", power: "0")
        let confirmed = live.connectorEvidence(now: reported, vehicleConnection: .disconnected)
        #expect(confirmed.connected == true)
        #expect(confirmed.evidence == .confirmedByCharger)

        let late = reported.addingTimeInterval(HomeChargerTelemetry.defaultStaleAfter + 60)
        let fromVehicle = live.connectorEvidence(now: late, vehicleConnection: .connected)
        #expect(fromVehicle.connected == true)
        #expect(fromVehicle.evidence == .reportedByVehicle)

        let silent = HomeChargerTelemetry().connectorEvidence(now: reported, vehicleConnection: .unknown)
        #expect(silent.connected == nil)
        #expect(silent.evidence == .unknown)

        var powerOnly = HomeChargerTelemetry()
        powerOnly.powerKw = HomeChargerReading(value: 3.2, timestamp: reported)
        let inferred = powerOnly.connectorEvidence(now: reported, vehicleConnection: nil)
        #expect(inferred.connected == true)
        #expect(inferred.evidence == .inferred)
    }
}

@Suite("Home charger command acknowledgment")
struct HomeChargerCommandTrackerTests {
    private let sent = Date(timeIntervalSince1970: 1_780_000_000)

    private func reading(_ status: String, power: String = "7.2", at offset: TimeInterval) -> HomeChargerTelemetry {
        HomeChargerTelemetry.make(
            from: NexBlueFixture.table(status: status, powerKw: power, reportedAt: sent.addingTimeInterval(offset)),
            map: NexBlueFixture.map)
    }

    private func acceptedStart() -> HomeChargerCommandTracker {
        var tracker = HomeChargerCommandTracker()
        tracker.begin(.start, now: sent)
        tracker.accepted(now: sent.addingTimeInterval(1))
        return tracker
    }

    @Test("A successful call is only an acceptance; the card stays pending")
    func acceptanceIsNotConfirmation() {
        let tracker = acceptedStart()
        #expect(tracker.isPending)
        guard case .awaitingCharger(.start, _, _) = tracker.phase else {
            Issue.record("expected awaitingCharger")
            return
        }
    }

    @Test("A reading from before the command cannot confirm it")
    func staleReadingDoesNotConfirm() {
        var tracker = acceptedStart()
        tracker.observe(reading("charging", at: -30), now: sent.addingTimeInterval(20))
        #expect(tracker.isPending)
        tracker.observe(reading("charging", at: 40), now: sent.addingTimeInterval(41))
        guard case .confirmed(.start, _, .charging(let power)) = tracker.phase else {
            Issue.record("expected confirmed charging, got \(tracker.phase)")
            return
        }
        #expect(power == 7.2)
    }

    @Test("Waiting for power or for the car confirms the start and says which")
    func waitingStatesConfirm() {
        var power = acceptedStart()
        power.observe(reading("lb_waiting", power: "0", at: 30), now: sent.addingTimeInterval(31))
        #expect(power.phase == .confirmed(.start, at: sent.addingTimeInterval(31), outcome: .waitingForPower))

        var car = acceptedStart()
        car.observe(reading("ev_waiting", power: "0", at: 30), now: sent.addingTimeInterval(31))
        #expect(car.phase == .confirmed(.start, at: sent.addingTimeInterval(31), outcome: .waitingForVehicle))
    }

    @Test("Enabled but drawing zero power is confirmed as enabled with no draw")
    func zeroDrawIsReported() {
        var tracker = acceptedStart()
        tracker.observe(reading("charging", power: "0.0", at: 30), now: sent.addingTimeInterval(31))
        #expect(tracker.phase == .confirmed(.start, at: sent.addingTimeInterval(31), outcome: .enabledNoDraw))
    }

    @Test("A rejected call is reported as rejected and is not pending")
    func rejection() {
        var tracker = HomeChargerCommandTracker()
        tracker.begin(.start, now: sent)
        #expect(tracker.isPending)
        tracker.rejected(reason: "Charger is offline", now: sent.addingTimeInterval(2))
        #expect(!tracker.isPending)
        #expect(tracker.phase == .rejected(.start, reason: "Charger is offline", at: sent.addingTimeInterval(2)))
    }

    @Test("No matching reading by the deadline is unconfirmed, with the reason")
    func unconfirmed() {
        var silent = acceptedStart()
        silent.observe(HomeChargerTelemetry(), now: sent.addingTimeInterval(HomeChargerCommandTracker.confirmationWindow + 5))
        #expect(silent.phase == .unconfirmed(.start, since: sent.addingTimeInterval(HomeChargerCommandTracker.confirmationWindow + 5),
                                             reason: .noFreshReading))

        var delayed = acceptedStart()
        let late = sent.addingTimeInterval(HomeChargerCommandTracker.confirmationWindow + 5)
        delayed.observe(reading("delay_waiting", power: "0", at: 100), now: late)
        #expect(delayed.phase == .unconfirmed(.start, since: late, reason: .delayedStartActive))

        var wrongWay = acceptedStart()
        wrongWay.observe(reading("connected", power: "0", at: 100), now: late)
        #expect(wrongWay.phase == .unconfirmed(.start, since: late, reason: .timedOut))
    }

    @Test("A charger error after the command is reported at once")
    func chargerErrorEndsThePendingState() {
        var tracker = acceptedStart()
        tracker.observe(reading("error", power: "0", at: 20), now: sent.addingTimeInterval(21))
        #expect(tracker.phase == .unconfirmed(.start, since: sent.addingTimeInterval(21), reason: .chargerError))
    }

    @Test("Pause is confirmed only by a fresh reading that is no longer charging")
    func pauseConfirmation() {
        var tracker = HomeChargerCommandTracker()
        tracker.begin(.pause, now: sent)
        tracker.accepted(now: sent.addingTimeInterval(1))
        // The charger still says charging, and an older plugged-in reading does not count.
        tracker.observe(reading("charging", at: 30), now: sent.addingTimeInterval(31))
        tracker.observe(reading("connected", power: "0", at: -60), now: sent.addingTimeInterval(32))
        #expect(tracker.isPending)
        tracker.observe(reading("connected", power: "0", at: 60), now: sent.addingTimeInterval(61))
        #expect(tracker.phase == .confirmed(.pause, at: sent.addingTimeInterval(61), outcome: .stopped))
    }

    @Test("A command the charger already satisfies is recognised only from a current reading")
    func alreadySatisfied() {
        let now = sent
        #expect(HomeChargerCommandTracker.alreadySatisfied(.start, telemetry: reading("charging", at: 0), now: now))
        #expect(HomeChargerCommandTracker.alreadySatisfied(.pause, telemetry: reading("connected", power: "0", at: 0), now: now))
        #expect(!HomeChargerCommandTracker.alreadySatisfied(.pause, telemetry: reading("idle", power: "0", at: 0), now: now))
        let stale = now.addingTimeInterval(HomeChargerTelemetry.defaultStaleAfter + 1)
        #expect(!HomeChargerCommandTracker.alreadySatisfied(.start, telemetry: reading("charging", at: 0), now: stale))
    }
}
