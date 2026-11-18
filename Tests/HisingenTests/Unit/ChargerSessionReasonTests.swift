import Foundation
import Testing
@testable import Hisingen

private let base = Date(timeIntervalSince1970: 1_780_000_000)
private let vin = "YSMTEST"

private func candidate(start: String? = nil, stop: String? = nil, key: String = "nexblue:NX1:window") -> HomeChargingSessionCandidate {
    HomeChargingSessionCandidate(
        key: key, keyKind: .vendorWindow, chargerID: "NX1",
        startedAt: base, endedAt: base.addingTimeInterval(3_600), energyKwh: 9.5,
        energySource: "nexblue_session_api", measuredAt: base.addingTimeInterval(3_600),
        startReason: start, stopReason: stop)
}

private func storedMeasurement(_ ledger: ChargingSessionLedger) throws -> WallboxMeasurement {
    try #require(ledger.recentChargingSessions(for: vin).first?.wallbox)
}

@Suite("Charger session start and stop reasons")
struct ChargerSessionReasonTests {
    // Every token NexBlue's OpenAPI lists for ChargerSession.start_reason and stop_reason.
    static let documentedStarts = ["Local", "Remote", "Admin", "Schedule", "ErrorRecover", "PlugAndCharge"]
    static let documentedStops = ["EmergencyStop", "EVDisconnected", "HardReset", "Local", "PowerLoss", "Reboot", "Remote",
                                  "SoftReset", "UnlockCommand", "DeAuthorized", "Admin", "Schedule", "LB_Required", "Complete"]

    @Test("Every documented token has words, and the vendor's no-reason values have none")
    func wording() {
        for token in Self.documentedStarts { #expect(ChargerSessionStart(token: token)?.text.isEmpty == false, "\(token)") }
        for token in Self.documentedStops { #expect(ChargerSessionEnd(token: token)?.text.isEmpty == false, "\(token)") }
        for token in ["_None", "_Other", "SomethingNew", ""] {
            #expect(ChargerSessionStart(token: token) == nil)
            #expect(ChargerSessionEnd(token: token) == nil)
        }
        #expect(ChargerSessionStart(token: nil) == nil)
        #expect(ChargerSessionEnd(token: nil) == nil)
    }

    @Test("Only a power loss and an emergency stop ask for attention")
    func attention() {
        let flagged = Self.documentedStops.filter { ChargerSessionEnd(token: $0)?.needsAttention == true }
        #expect(Set(flagged) == ["PowerLoss", "EmergencyStop"])
    }

    @Test("The three restart tokens read the same")
    func restartsShareWording() {
        let words = Set(["Reboot", "SoftReset", "HardReset"].compactMap { ChargerSessionEnd(token: $0)?.text })
        #expect(words == [L10n.text("Charger restarted")])
    }

    @Test("The reasons are stored with the session and read back")
    func persists() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        #expect(ledger.recordWallboxSession(candidate(start: "Schedule", stop: "EVDisconnected"),
                                            decision: decision, cost: nil, locationName: "Home")?.kind == .inserted)
        let stored = try storedMeasurement(ledger)
        #expect(stored.startReason == "Schedule")
        #expect(stored.stopReason == "EVDisconnected")
    }

    @Test("A session stored before reasons existed gains them once, then stays unchanged")
    func backfillsOnce() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        #expect(ledger.recordWallboxSession(candidate(), decision: decision, cost: nil, locationName: "Home")?.kind == .inserted)
        let before = try storedMeasurement(ledger)
        #expect(before.startReason == nil && before.stopReason == nil)

        let withReasons = candidate(start: "Remote", stop: "Remote")
        #expect(ledger.recordWallboxSession(withReasons, decision: decision, cost: nil, locationName: "Home")?.kind == .updated)
        #expect(ledger.recordWallboxSession(withReasons, decision: decision, cost: nil, locationName: "Home")?.kind == .unchanged)
        #expect(ledger.wallboxSessionCount(chargerID: "NX1") == 1)
        #expect(try storedMeasurement(ledger).stopReason == "Remote")
    }

    @Test("A later import with no reasons never erases the ones already stored")
    func missingReasonsDoNotErase() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        _ = ledger.recordWallboxSession(candidate(start: "Local", stop: "Complete"), decision: decision, cost: nil, locationName: "Home")
        #expect(ledger.recordWallboxSession(candidate(), decision: decision, cost: nil, locationName: "Home")?.kind == .unchanged)
        let stored = try storedMeasurement(ledger)
        #expect(stored.startReason == "Local")
        #expect(stored.stopReason == "Complete")
    }

    @Test("The session row words the stored reasons and leaves out one it cannot word")
    func presentation() {
        func measurement(start: String?, stop: String?) -> WallboxMeasurement {
            WallboxMeasurement(chargerID: "NX1", sessionKey: "k", keyKind: "vendor_window", energyKwh: 9.5,
                               energySource: "nexblue_session_api", measuredAt: base, costAssumptions: [],
                               startReason: start, stopReason: stop)
        }
        let routine = WallboxSessionPresentation(measurement(start: "Schedule", stop: "EVDisconnected"), currencyFallback: "kr")
        #expect(routine.startedBy == L10n.text("By schedule"))
        #expect(routine.endedBy == L10n.text("Cable unplugged"))
        #expect(!routine.endedByNeedsAttention)

        let outage = WallboxSessionPresentation(measurement(start: "Remote", stop: "PowerLoss"), currencyFallback: "kr")
        #expect(outage.endedBy == L10n.text("Power loss"))
        #expect(outage.endedByNeedsAttention)

        let unknown = WallboxSessionPresentation(measurement(start: "_None", stop: "SomethingNew"), currencyFallback: "kr")
        #expect(unknown.startedBy == nil)
        #expect(unknown.endedBy == nil)
    }
}

@Suite("Home charger electrical details on the card")
struct HomeChargerElectricalCardTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func card(_ telemetry: HomeChargerTelemetry, command: HomeChargerCommandTracker.Phase = .idle) -> HomeChargingCardModel {
        let pairing = HomeChargingPairing(baseURL: "", chargerID: "NX1", chargerName: "NexBlue NX1", entities: .init(),
                                          vin: vin, locationID: nil, locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm",
                                          source: .nexBlue)
        return HomeChargingCardModel.make(HomeChargingCardInput(
            pairing: pairing, telemetry: telemetry, now: now, link: .live, lastContact: now, vehicleName: "Polestar 2",
            vehicleBatteryPercent: 50, vehicleTargetPercent: 80, vehicleConnection: .connected, plan: nil, command: command,
            vehicleFinish: nil, currency: "kr", sessionPeakKw: nil, canEditPlan: false))
    }

    private func telemetry(status: HomeChargerStatus = .charging, power: Double = 7.2, setting: Double = 16,
                           cable: Double? = 20, fuse: Double? = 16, amps: [Double] = [10.2, 10.1, 10.3],
                           volts: [Double] = [228, 227, 228], age: TimeInterval = 5) -> HomeChargerTelemetry {
        let at = now.addingTimeInterval(-age)
        return HomeChargerTelemetry(
            status: .init(value: status, timestamp: at), powerKw: .init(value: power, timestamp: at),
            currentLimitAmps: .init(value: setting, timestamp: at),
            phases: .init(value: zip(volts, amps).map { HomeChargerPhase(volts: $0, amps: $1) }, timestamp: at),
            cableLimitAmps: cable.map { .init(value: $0, timestamp: at) },
            circuitFuseAmps: fuse.map { .init(value: $0, timestamp: at) },
            phaseMode: .init(value: .adaptive, timestamp: at), network: .init(value: .mobile, timestamp: at))
    }

    @Test("While charging, the card shows each phase's current against the limit")
    func phaseLineWhileCharging() {
        let line = card(telemetry()).phaseLine
        let currents = [10.2, 10.1, 10.3].map { Format.number($0, decimals: 1) }.joined(separator: " · ")
        #expect(line == L10n.format("%@ per phase, limit %@", L10n.format("%@\u{00A0}A", currents), Format.amps(16)))
    }

    @Test("Without phase readings the line says nothing, and an idle charger has no phase line")
    func phaseLineIsOptional() {
        var noPhases = telemetry()
        noPhases.phases = nil
        #expect(card(noPhases).phaseLine == nil)
        #expect(card(telemetry(status: .pluggedIn, power: 0)).phaseLine == nil)
    }

    @Test("A single-phase charger shows one phase, not two empty ones")
    func singlePhase() {
        let line = card(telemetry(amps: [14.8, 0, 0], volts: [231, 0, 0])).phaseLine
        #expect(line?.contains(Format.number(14.8, decimals: 1)) == true)
        #expect(line?.contains("·") == false)
    }

    @Test("Stale phase readings are not shown as live current")
    func stalePhases() {
        let old = telemetry(age: HomeChargerTelemetry.defaultStaleAfter + 60)
        let model = card(old)
        #expect(model.phaseLine == nil)
        #expect(!model.details.contains { $0.label == L10n.text("Voltage") })
        #expect(model.details.contains { $0.label == L10n.text("Cable Rating") })
    }

    @Test("The limit row names what binds: the setting, the cable or the circuit fuse")
    func limitBinding() throws {
        func limitRow(_ model: HomeChargingCardModel) throws -> HomeChargingCardModel.Detail {
            try #require(model.details.first { $0.label == L10n.text("Current Limit") })
        }
        let setting = try limitRow(card(telemetry(setting: 16, cable: 20, fuse: 25)))
        #expect(setting.value == Format.amps(16))
        #expect(!setting.needsAttention)

        let cable = try limitRow(card(telemetry(setting: 16, cable: 10, fuse: 25)))
        #expect(cable.value == L10n.format("%@, limited by the cable", Format.amps(10)))
        #expect(cable.needsAttention)

        let fuse = try limitRow(card(telemetry(setting: 32, cable: 32, fuse: 16)))
        #expect(fuse.value == L10n.format("%@, limited by the circuit fuse", Format.amps(16)))
        #expect(fuse.needsAttention)

        let tie = try limitRow(card(telemetry(setting: 16, cable: 16, fuse: 16)))
        #expect(!tie.needsAttention)
    }

    @Test("A charger that reports none of these, such as one read through Home Assistant, gets no detail rows")
    func homeAssistantHasNoDetails() {
        var plain = telemetry()
        plain.phases = nil
        plain.cableLimitAmps = nil
        plain.circuitFuseAmps = nil
        plain.phaseMode = nil
        plain.network = nil
        plain.currentLimitAmps = nil
        #expect(card(plain).details.isEmpty)
        #expect(card(plain).phaseLine == nil)

        var limitOnly = plain
        limitOnly.currentLimitAmps = .init(value: 16, timestamp: now)
        #expect(card(limitOnly).details.isEmpty)
    }

    @Test("The detail rows read from top to bottom as spec rows")
    func rowOrder() {
        let labels = card(telemetry()).details.map(\.label)
        #expect(labels == ["Voltage", "Current per Phase", "Current Limit", "Cable Rating", "Circuit Fuse", "Phase Mode", "Network"]
            .map { L10n.text($0) })
    }

    @Test("A disabled charger says so and will not start")
    func disabledCharger() {
        var disabled = telemetry(status: .pluggedIn, power: 0)
        disabled.isDisabled = .init(value: true, timestamp: now)
        let model = card(disabled)
        #expect(model.notice?.text == L10n.text("Charging is disabled on this charger."))
        #expect(model.actions.first { $0.kind == .chargeNow }?.isEnabled == false)
    }

    @Test("A stale disabled reading does not block a start")
    func staleDisabledReading() {
        var disabled = telemetry(status: .pluggedIn, power: 0)
        disabled.isDisabled = .init(value: true, timestamp: now.addingTimeInterval(-HomeChargerTelemetry.defaultStaleAfter - 60))
        let model = card(disabled)
        #expect(model.actions.contains { $0.kind == .chargeNow && $0.isEnabled })
        #expect(model.notice?.text != L10n.text("Charging is disabled on this charger."))
    }

    @Test("A charger that is drawing power is not described as waiting for the car")
    func powerWhileWaiting() {
        let model = card(telemetry(status: .waitingForVehicle, power: 7.2))
        #expect(model.vehicleLine.contains(L10n.text("Charging")))
        #expect(model.notice?.text != L10n.text("Waiting for the car to start drawing power"))
        #expect(model.actions.contains { $0.kind == .pause })
    }
}
