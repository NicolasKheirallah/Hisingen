import Foundation
import Testing
@testable import Hisingen

// MARK: - Mock Home Assistant

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// A Home Assistant that answers single-state reads, switch actions, the component's actions and
/// recorder history from values the test sets.
private final class MockHomeAssistant: @unchecked Sendable {
    let transport = MockHomeAssistantTransport()
    private let lock = NSLock()
    private var states: [String: HAEntityState] = [:]
    private var stateReads: [String: Int] = [:]
    private(set) var switchCalls: [String] = []
    private(set) var componentCalls: [String] = []
    private var switchReply: MockHomeAssistantTransport.Reply = .json("[]")
    private var componentReplies: [String: MockHomeAssistantTransport.Reply] = [:]
    private var historyBody = Data("[]".utf8)
    private var authRejected = false

    init() {
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0).hasPrefix("/api/states/") }) { [weak self] request in
            guard let self else { return .json("{}", status: 503) }
            let id = String(MockHomeAssistantTransport.encodedPath(request).dropFirst("/api/states/".count))
            self.lock.lock(); defer { self.lock.unlock() }
            self.stateReads[id, default: 0] += 1
            if self.authRejected { return .json("{\"message\":\"Unauthorized\"}", status: 401) }
            guard let state = self.states[id] else { return .json("{\"message\":\"Entity not found.\"}", status: 404) }
            return .json(Self.json(state))
        }
        transport.route({ $0.httpMethod == "POST" && MockHomeAssistantTransport.encodedPath($0).hasPrefix("/api/services/switch/") }) { [weak self] request in
            guard let self else { return .json("{}", status: 503) }
            self.lock.lock(); defer { self.lock.unlock() }
            self.switchCalls.append(String(MockHomeAssistantTransport.encodedPath(request).split(separator: "/").last ?? ""))
            return self.switchReply
        }
        transport.route({ $0.httpMethod == "POST" && MockHomeAssistantTransport.encodedPath($0).hasPrefix("/api/services/hisingen_home_charging/") }) { [weak self] request in
            guard let self else { return .json("{}", status: 503) }
            let service = String(MockHomeAssistantTransport.encodedPath(request).split(separator: "/").last ?? "")
            self.lock.lock(); defer { self.lock.unlock() }
            self.componentCalls.append(service)
            return self.componentReplies[service] ?? .json("{\"message\":\"Service not found.\"}", status: 400)
        }
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0).hasPrefix("/api/history/period/") }) { [weak self] _ in
            guard let self else { return .json("[]", status: 503) }
            self.lock.lock(); defer { self.lock.unlock() }
            return MockHomeAssistantTransport.Reply(status: 200, body: self.historyBody)
        }
    }

    func setStates(_ table: [String: HAEntityState]) { lock.lock(); states = table; lock.unlock() }
    func setAuthRejected(_ rejected: Bool) { lock.lock(); authRejected = rejected; lock.unlock() }
    func setSwitchReply(_ reply: MockHomeAssistantTransport.Reply) { lock.lock(); switchReply = reply; lock.unlock() }
    func setComponentReply(_ service: String, _ reply: MockHomeAssistantTransport.Reply) { lock.lock(); componentReplies[service] = reply; lock.unlock() }
    func setHistory(_ groups: [[(entity: String?, state: String, at: Date)]]) {
        let array = groups.map { group in
            group.map { entry -> [String: Any] in
                var item: [String: Any] = ["state": entry.state, "last_changed": HATimestamp.format(entry.at)]
                if let entity = entry.entity { item["entity_id"] = entity }
                return item
            }
        }
        lock.lock(); historyBody = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8); lock.unlock()
    }
    func reads(of entity: String) -> Int { lock.lock(); defer { lock.unlock() }; return stateReads[entity, default: 0] }
    var switchCallCount: Int { lock.lock(); defer { lock.unlock() }; return switchCalls.count }

    private static func json(_ state: HAEntityState) -> String {
        var object: [String: Any] = ["entity_id": state.entityID, "state": state.state, "attributes": [String: Any]()]
        var attributes: [String: Any] = [:]
        if let unit = state.unit { attributes["unit_of_measurement"] = unit }
        for (key, value) in state.attributes where key != "unit_of_measurement" {
            if let text = value.stringValue { attributes[key] = text } else if let number = value.doubleValue { attributes[key] = number }
        }
        object["attributes"] = attributes
        if let changed = state.lastChanged { object["last_changed"] = HATimestamp.format(changed) }
        if let updated = state.lastUpdated { object["last_updated"] = HATimestamp.format(updated) }
        if let reported = state.lastReported { object["last_reported"] = HATimestamp.format(reported) }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

@MainActor
private final class ModelHarness {
    let scoped: ScopedPreferences
    let database = VehicleDatabase.inMemory()
    let server = MockHomeAssistant()
    let clock = ClockBox(t0)
    private(set) var model: HomeChargingModel
    let vin = "YSMTEST"

    init(paired: Bool = true, shared: Bool = false, token: String? = "tok",
         socketConnector: (any HomeAssistantSocketConnecting)? = nil) throws {
        scoped = ScopedPreferences(label: "home-model")
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        if let token { try store.saveToken(token) }
        if paired { store.pairing = NexBlueFixture.pairing(vin: "YSMTEST", shared: shared) }
        store.address = "http://homeassistant.local:8123"
        scoped.store.features = FeatureSelection(enabled: [.smartChargingPlanner, .remoteCharging])
        // Local charging history is opt-in in the app; the sync only writes when the reader turned it on.
        scoped.store.storeChargingHistory = true
        model = ModelHarness.makeModel(scoped: scoped, database: database, server: server, clock: clock,
                                      socketConnector: socketConnector)
        server.setStates(NexBlueFixture.table(status: "connected", powerKw: "0", energyKwh: "0", reportedAt: t0))
    }

    private static func makeModel(scoped: ScopedPreferences, database: VehicleDatabase, server: MockHomeAssistant, clock: ClockBox,
                                  socketConnector: (any HomeAssistantSocketConnecting)? = nil) -> HomeChargingModel {
        let clock = clock
        return HomeChargingModel(
            preferences: scoped.store, database: database,
            dependencies: HomeChargingModel.Dependencies(
                transport: server.transport, socketConnector: socketConnector, now: { clock.now },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) },
                spotPrices: { _ in [] }, observesWake: false))
    }

    /// A new model over the same stored settings: what a relaunch of the app does.
    func relaunch() {
        model.stop()
        model = ModelHarness.makeModel(scoped: scoped, database: database, server: server, clock: clock)
    }

    func connect() async {
        model.start()
        await eventually { self.model.link == .live && self.model.lastContact != nil }
    }

    func setCharger(_ status: String, power: String = "0", energy: String = "0", reportedAfter seconds: TimeInterval = 0) {
        server.setStates(NexBlueFixture.table(status: status, powerKw: power, energyKwh: energy, reportedAt: clock.now.addingTimeInterval(seconds)))
    }

    func refresh(until condition: @escaping @MainActor () -> Bool) async {
        model.refreshNow()
        await eventually(condition)
    }

    func state(battery: Double = 62, presence: Bool = true) -> VehicleState {
        var state = vehicle(vin: vin, battery: battery, connection: .connected, target: 80)
        if presence { state.chargeLocationPresence = ChargeLocationPresence(locationID: "home-loc", alias: "Home", since: nil, source: .proximity) }
        return state
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

private func planReply(phase: String = "scheduled", planID: String = "plan-1") -> MockHomeAssistantTransport.Reply {
    .json("""
    {"changed_states": [], "service_response": {"state": "\(phase)", "attributes": {
      "plan_id": "\(planID)", "target": {"type": "add_kwh", "value": 18.0},
      "deadline": "2026-11-17T06:00:00+00:00", "windows": [], "delivered_kwh": 0.0, "hold": false, "override": false}}}
    """)
}

/// A WebSocket whose handshake is held until the test lets it through, so a run can be retired
/// while its connection is still being opened. Subscriptions are answered as Home Assistant would.
private final class GatedSocketConnection: HomeAssistantSocketConnection, @unchecked Sendable {
    private let inner = ScriptedSocketConnection()
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var closes = 0
    private var arrivedAtGate = false

    init() {
        inner.push(#"{"type":"auth_required"}"#)
        inner.push(#"{"type":"auth_ok"}"#)
    }

    var closeCount: Int { lock.withLock { closes } }
    var isWaitingAtGate: Bool { lock.withLock { arrivedAtGate && !released } }

    func release() {
        lock.lock()
        released = true
        let pending = gate
        gate = nil
        lock.unlock()
        pending?.resume()
    }

    func send(_ text: String) async throws {
        try await inner.send(text)
        if text.contains("subscribe_events"),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let id = object["id"] as? Int {
            inner.push(#"{"type":"result","id":\#(id),"success":true,"result":null}"#)
        }
    }

    func receive() async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivedAtGate = true
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                gate = continuation
                lock.unlock()
            }
        }
        return try await inner.receive()
    }

    func close() {
        lock.withLock { closes += 1 }
        inner.close()
    }
}

private struct GatedSocketConnector: HomeAssistantSocketConnecting {
    let connection: GatedSocketConnection
    func connect(to url: URL) -> any HomeAssistantSocketConnection { connection }
}

// MARK: - Tests

@Suite("Home charging model", .serialized)
@MainActor
struct HomeChargingModelTests {
    @Test("Without a pairing the model is inert and nothing is requested")
    func inertWithoutPairing() async throws {
        let harness = try ModelHarness(paired: false)
        harness.model.start()
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.model.link == .notConfigured)
        #expect(harness.server.transport.requests.isEmpty)
    }

    @Test("It reads the charger on connect and keeps working with no WebSocket")
    func connectsAndReads() async throws {
        let harness = try ModelHarness()
        harness.setCharger("charging", power: "7.3", energy: "4.2")
        await harness.connect()
        #expect(harness.model.telemetry.status?.value == .charging)
        #expect(harness.model.telemetry.powerKw?.value == 7.3)
        #expect(harness.model.telemetry.sessionEnergyKwh?.value == 4.2)
        harness.model.stop()
    }

    @Test("A socket that finishes opening after the connection was stopped is closed, not installed")
    func aSocketOpenedAfterStopIsClosed() async throws {
        let connection = GatedSocketConnection()
        let harness = try ModelHarness(socketConnector: GatedSocketConnector(connection: connection))
        harness.model.start()
        await eventually { connection.isWaitingAtGate }
        #expect(connection.isWaitingAtGate)

        harness.model.stop()
        connection.release()
        await eventually { connection.closeCount > 0 }
        #expect(connection.closeCount > 0, "A socket opened for a retired run must not stay open")
    }

    // MARK: Command acknowledgment

    @Test("An accepted command stays pending until the charger's own reading confirms it")
    func acceptanceThenConfirmation() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        await harness.model.send(.start)
        #expect(harness.server.switchCalls == ["turn_on"])
        #expect(harness.model.command.isPending)

        // The card says it is waiting for the charger, not that charging started.
        let input = try #require(harness.model.cardInput(for: harness.state()))
        let card = HomeChargingCardModel.make(input)
        #expect(card.notice?.text == L10n.text("Home Assistant accepted the command. Waiting for the charger to confirm."))
        #expect(card.actions.allSatisfy { $0.kind == .editPlan || !$0.isEnabled })

        // A refresh that still shows the old state, stamped before the command, does not confirm it.
        await harness.refresh(until: { harness.server.reads(of: "sensor.nx1234567_charging_state") >= 2 })
        #expect(harness.model.command.isPending)

        harness.clock.now = t0.addingTimeInterval(40)
        harness.setCharger("charging", power: "7.2", energy: "0.1", reportedAfter: 40)
        await harness.refresh(until: { !harness.model.command.isPending })
        guard case .confirmed(.start, _, .charging) = harness.model.command.phase else {
            Issue.record("expected confirmed charging, got \(harness.model.command.phase)")
            return
        }
        harness.model.stop()
    }

    @Test("A rejected command is reported as rejected with Home Assistant's reason")
    func rejection() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        harness.server.setSwitchReply(.text("Charger NX1234567 is offline", status: 500))
        await harness.model.send(.start)
        #expect(!harness.model.command.isPending)
        guard case .rejected(.start, let reason, _) = harness.model.command.phase else {
            Issue.record("expected rejected, got \(harness.model.command.phase)")
            return
        }
        #expect(reason == "Charger NX1234567 is offline")
        let card = HomeChargingCardModel.make(try #require(harness.model.cardInput(for: harness.state())))
        #expect(card.notice?.level == .error)
        #expect(card.tone == .error)
        harness.model.stop()
    }

    @Test("A command the charger never confirms is reported as unconfirmed, not as success")
    func unconfirmedResult() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        await harness.model.send(.start)
        harness.clock.now = t0.addingTimeInterval(HomeChargerCommandTracker.confirmationWindow + 30)
        harness.setCharger("connected", power: "0", reportedAfter: HomeChargerCommandTracker.confirmationWindow + 20)
        await harness.refresh(until: { !harness.model.command.isPending })
        guard case .unconfirmed(.start, _, _) = harness.model.command.phase else {
            Issue.record("expected unconfirmed, got \(harness.model.command.phase)")
            return
        }
        let card = HomeChargingCardModel.make(try #require(harness.model.cardInput(for: harness.state())))
        #expect(card.notice?.text == L10n.text("The charger has not confirmed the command"))
        harness.model.stop()
    }

    @Test("Enabled with a car drawing no power is confirmed as exactly that")
    func zeroPowerConfirmation() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        await harness.model.send(.start)
        harness.clock.now = t0.addingTimeInterval(30)
        harness.setCharger("charging", power: "0", energy: "0", reportedAfter: 30)
        await harness.refresh(until: { !harness.model.command.isPending })
        #expect(harness.model.command.phase == .confirmed(.start, at: t0.addingTimeInterval(30), outcome: .enabledNoDraw))
        let card = HomeChargingCardModel.make(try #require(harness.model.cardInput(for: harness.state())))
        #expect(card.notice?.text == L10n.text("Charging is enabled but the car is drawing no power"))
        harness.model.stop()
    }

    @Test("A command is not sent when the charger already answers that way")
    func noRedundantCommand() async throws {
        let harness = try ModelHarness()
        harness.setCharger("charging", power: "7.2", energy: "2")
        await harness.connect()
        await harness.model.send(.start)
        #expect(harness.server.switchCallCount == 0)
        #expect(!harness.model.command.isPending)
    }

    // MARK: Stale and unreachable

    @Test("Telemetry older than the window is shown as stale, never as live")
    func staleTelemetryOnTheCard() async throws {
        let harness = try ModelHarness()
        harness.setCharger("charging", power: "7.2", energy: "2", reportedAfter: -3_600)
        await harness.connect()
        let card = HomeChargingCardModel.make(try #require(harness.model.cardInput(for: harness.state())))
        #expect(card.tone == .unavailable)
        #expect(card.notice?.text == L10n.text("The charger has not reported recently"))
        // The last readings are kept, labelled as such, and never presented as live.
        #expect(card.sessionIsLive == false)
        #expect(card.sessionLine?.hasPrefix(L10n.format("Last known: %@", "").trimmingCharacters(in: .whitespaces)) == true)
        harness.model.stop()
    }

    @Test("When Home Assistant is unreachable the last readings stay, labelled, and nothing else breaks")
    func unreachableKeepsLastReadings() async throws {
        let harness = try ModelHarness()
        harness.setCharger("charging", power: "7.2", energy: "3.1")
        await harness.connect()
        harness.server.transport.unreachable = true
        await harness.refresh(until: { harness.model.link != .live })
        #expect(harness.model.telemetry.sessionEnergyKwh?.value == 3.1)
        let card = HomeChargingCardModel.make(try #require(harness.model.cardInput(for: harness.state())))
        #expect(card.notice?.text == L10n.text("Home Assistant is unreachable"))
        #expect(card.freshnessLine != nil)
        harness.model.stop()
    }

    @Test("A rejected token is reported and stops retrying")
    func tokenRejected() async throws {
        let harness = try ModelHarness()
        harness.server.transport.route("GET", "/api/states/", .json("{\"message\":\"Unauthorized\"}", status: 401))
        harness.model.start()
        await eventually { harness.model.link == .unauthorized }
        #expect(harness.model.link == .unauthorized)
        harness.model.stop()
    }

    @Test("Replacing a rejected token reconnects and keeps the pairing")
    func replaceRejectedToken() async throws {
        let harness = try ModelHarness()
        harness.server.setAuthRejected(true)
        harness.model.start()
        await eventually { harness.model.link == .unauthorized }
        #expect(harness.model.link == .unauthorized)
        #expect(harness.model.pairing != nil)

        harness.server.setAuthRejected(false)
        try harness.model.replaceToken("  fresh-token \n")
        await eventually { harness.model.link == .live }
        #expect(harness.model.link == .live)
        #expect(harness.model.savedToken() == "fresh-token")
        #expect(harness.model.pairing != nil)
        harness.model.stop()
    }

    @Test("A command tapped before the first connection is rejected out loud, not dropped")
    func commandBeforeConnection() async throws {
        let harness = try ModelHarness()
        await harness.model.send(.start)
        guard case .rejected(.start, let reason, _) = harness.model.command.phase else {
            Issue.record("expected rejected, got \(harness.model.command.phase)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(harness.server.switchCallCount == 0)
    }

    @Test("Refreshing after a wake re-reads every reading")
    func refreshAfterWake() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        let before = harness.server.reads(of: "sensor.nx1234567_charging_state")
        harness.clock.now = t0.addingTimeInterval(3_600)
        harness.setCharger("finished", power: "0", energy: "9.9", reportedAfter: 3_590)
        await harness.refresh(until: { harness.model.telemetry.status?.value == .finished })
        #expect(harness.server.reads(of: "sensor.nx1234567_charging_state") > before)
        #expect(harness.model.telemetry.sessionEnergyKwh?.value == 9.9)
        harness.model.stop()
    }

    // MARK: Pairing decides where and for whom

    @Test("The card belongs to the paired vehicle only")
    func cardOnlyForPairedVehicle() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        #expect(harness.model.cardInput(for: harness.state()) != nil)
        var other = harness.state()
        other.identity.vin = "YSMOTHER"
        #expect(harness.model.cardInput(for: other) == nil)
        harness.model.stop()
    }

    @Test("The card needs a saved login")
    func cardNeedsALogin() async throws {
        let signedOut = try ModelHarness(token: nil)
        #expect(!signedOut.model.isSignedIn)
        #expect(!signedOut.model.shouldShow(for: signedOut.state()))
        #expect(signedOut.model.cardInput(for: signedOut.state()) == nil)

        let signedIn = try ModelHarness()
        #expect(signedIn.model.isSignedIn)
        #expect(signedIn.model.shouldShow(for: signedIn.state()))

        // A charger that was never paired has no login to speak of, whatever is stored.
        let unpaired = try ModelHarness(paired: false)
        #expect(!unpaired.model.isSignedIn)
        #expect(unpaired.model.cardInput(for: unpaired.state()) == nil)
    }

    @Test("A shared charger shows its card only where the vehicle is at the saved location")
    func sharedChargerNeedsPresence() async throws {
        let shared = try ModelHarness(shared: true)
        shared.setCharger("connected")
        await shared.connect()
        #expect(shared.model.cardInput(for: shared.state(presence: false)) == nil)
        #expect(shared.model.cardInput(for: shared.state(presence: true)) != nil)
        shared.model.stop()

        // A dedicated charger that itself confirms a cable may show elsewhere, a shared one may not.
        let dedicated = try ModelHarness(shared: false)
        dedicated.setCharger("connected")
        await dedicated.connect()
        #expect(dedicated.model.cardInput(for: dedicated.state(presence: false)) != nil)
        dedicated.model.stop()
    }

    // MARK: Plans, ownership, recovery

    @Test("Submitting a plan makes Home Assistant the owner, across a relaunch, until it ends")
    func ownershipAcrossRelaunch() async throws {
        let harness = try ModelHarness()
        harness.server.setComponentReply("submit_plan", planReply())
        harness.server.setComponentReply("get_status", planReply())
        await harness.connect()
        let request = HomeChargingPlanRequest(
            planID: "plan-1", chargerID: "NX1234567", entities: NexBlueFixture.map,
            target: HomePlanTarget(kind: .addKwh, value: 18), deadline: t0.addingTimeInterval(8 * 3_600),
            timeZoneIdentifier: "Europe/Stockholm", vehicleName: "Polestar 2", usableCapacityKwh: 75,
            chargingLossFactor: 1.1, tibberHome: nil, networkFeeOrePerKwh: 0, rateHintKw: 7.4)
        #expect(!harness.model.ownsPlan(for: harness.vin))
        try await harness.model.submitPlan(request, vin: harness.vin)
        #expect(harness.model.ownsPlan(for: harness.vin))
        #expect(harness.model.planStatus?.phase == .scheduled)

        harness.relaunch()
        #expect(harness.model.ownsPlan(for: harness.vin))
        #expect(!harness.model.ownsPlan(for: "YSMOTHER"))
        harness.model.stop()
    }

    @Test("Without the Hisingen component a plan is refused clearly and nothing is owned")
    func componentMissing() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        let request = HomeChargingPlanRequest(
            planID: "plan-1", chargerID: "NX1234567", entities: NexBlueFixture.map,
            target: HomePlanTarget(kind: .addKwh, value: 18), deadline: t0.addingTimeInterval(8 * 3_600),
            timeZoneIdentifier: "Europe/Stockholm", vehicleName: "Polestar 2", usableCapacityKwh: 75,
            chargingLossFactor: 1.1, tibberHome: nil, networkFeeOrePerKwh: 0, rateHintKw: 7.4)
        await #expect(throws: HomeChargingPlanError.componentNotInstalled) {
            try await harness.model.submitPlan(request, vin: harness.vin)
        }
        #expect(!harness.model.ownsPlan(for: harness.vin))
        #expect(harness.model.componentInstalled == false)
        harness.model.stop()
    }

    private func request() -> HomeChargingPlanRequest {
        HomeChargingPlanRequest(
            planID: "plan-1", chargerID: "NX1234567", entities: NexBlueFixture.map,
            target: HomePlanTarget(kind: .addKwh, value: 18), deadline: t0.addingTimeInterval(8 * 3_600),
            timeZoneIdentifier: "Europe/Stockholm", vehicleName: "Polestar 2", usableCapacityKwh: 75,
            chargingLossFactor: 1.1, tibberHome: nil, networkFeeOrePerKwh: 0, rateHintKw: 7.4)
    }

    @Test("A plan is refused for any vehicle other than the one the charger is paired with")
    func planOnlyForThePairedVehicle() async throws {
        let harness = try ModelHarness()
        harness.server.setComponentReply("submit_plan", planReply())
        await harness.connect()
        await #expect(throws: HomeChargingPlanError.notPaired) {
            try await harness.model.submitPlan(request(), vin: "YSMOTHER")
        }
        #expect(!harness.server.componentCalls.contains("submit_plan"))
        #expect(!harness.model.ownsPlan(for: "YSMOTHER"))
        harness.model.stop()
    }

    @Test("With no plan running, Pause goes straight to the charging switch")
    func pauseWithoutPlanUsesTheSwitch() async throws {
        let harness = try ModelHarness()
        harness.setCharger("charging", power: "7.2", energy: "2")
        await harness.connect()
        await harness.model.send(.pause)
        #expect(harness.server.switchCalls == ["turn_off"])
        #expect(!harness.server.componentCalls.contains("pause_plan"))
        harness.model.stop()
    }

    @Test("With a plan running, Pause holds the plan so it stays paused until resumed or edited")
    func pauseWithPlanHoldsThePlan() async throws {
        let harness = try ModelHarness()
        harness.server.setComponentReply("submit_plan", planReply())
        harness.server.setComponentReply("get_status", planReply())
        harness.server.setComponentReply("pause_plan", planReply(phase: "holding"))
        harness.server.setComponentReply("resume_plan", planReply(phase: "scheduled"))
        harness.setCharger("charging", power: "7.2", energy: "2")
        await harness.connect()
        try await harness.model.submitPlan(request(), vin: harness.vin)
        // Home Assistant now serves the plan sensor the component publishes.
        var table = NexBlueFixture.table(status: "charging", powerKw: "7.2", energyKwh: "2", reportedAt: harness.clock.now)
        let planEntity = HomeChargingPlanEntity.id(chargerID: "NX1234567")
        table[planEntity] = HAEntityState(entityID: planEntity, state: "scheduled",
                                          attributes: ["plan_id": .string("plan-1")], lastUpdated: harness.clock.now)
        harness.server.setStates(table)
        await harness.refresh(until: { harness.model.planStatus?.phase == .scheduled })

        await harness.model.send(.pause)
        #expect(harness.server.componentCalls.contains("pause_plan"))
        #expect(harness.server.switchCallCount == 0)
        try await harness.model.resumePlan()
        #expect(harness.server.componentCalls.contains("resume_plan"))
        harness.model.stop()
    }

    @Test("Unpairing cancels the plan Home Assistant is running and releases the car")
    func unpairCancelsThePlan() async throws {
        let harness = try ModelHarness()
        harness.server.setComponentReply("submit_plan", planReply())
        harness.server.setComponentReply("get_status", planReply())
        harness.server.setComponentReply("cancel_plan", planReply(phase: "cancelled"))
        await harness.connect()
        try await harness.model.submitPlan(request(), vin: harness.vin)
        var table = NexBlueFixture.table(status: "connected", powerKw: "0", energyKwh: "0", reportedAt: harness.clock.now)
        let planEntity = HomeChargingPlanEntity.id(chargerID: "NX1234567")
        table[planEntity] = HAEntityState(entityID: planEntity, state: "scheduled",
                                          attributes: ["plan_id": .string("plan-1")], lastUpdated: harness.clock.now)
        harness.server.setStates(table)
        await harness.refresh(until: { harness.model.planStatus?.phase == .scheduled })
        #expect(harness.model.ownsPlan(for: harness.vin))

        await harness.model.unpairCancellingPlan()
        #expect(harness.server.componentCalls.contains("cancel_plan"))
        #expect(harness.model.pairing == nil)
        #expect(!harness.model.ownsPlan(for: harness.vin))
    }

    // MARK: Session sync

    private func seedHistory(_ harness: ModelHarness, kwhPerStep: Double = 1.8) {
        let status = [(entity: Optional("sensor.nx1234567_charging_state"), state: "connected", at: t0.addingTimeInterval(-3_600 * 5)),
                      (entity: nil, state: "charging", at: t0.addingTimeInterval(-3_600 * 4)),
                      (entity: nil, state: "finished", at: t0.addingTimeInterval(-3_600 * 4 + 135 * 60))]
        var energy: [(entity: String?, state: String, at: Date)] = [("sensor.nx1234567_energy", "0.0", t0.addingTimeInterval(-3_600 * 4 - 1_800))]
        energy.append((nil, "0.0", t0.addingTimeInterval(-3_600 * 4)))
        for step in 1...9 {
            energy.append((nil, String(format: "%.2f", kwhPerStep * Double(step)), t0.addingTimeInterval(-3_600 * 4 + Double(step) * 900)))
        }
        harness.server.setHistory([status, energy])
    }

    @Test("Repeated syncs, a reconnect and a wake never create a second session")
    func repeatedSyncsDoNotDuplicate() async throws {
        let harness = try ModelHarness()
        seedHistory(harness)
        await harness.connect()
        // The model imports once on connecting; wait for that pass, which is the one that adds the session.
        await eventually { if case .finished = harness.model.syncState { return true } else { return false } }
        guard case .finished(let first) = harness.model.syncState else { Issue.record("sync did not finish"); return }
        #expect(first.inserted == 1)
        for _ in 0..<3 {
            await harness.model.syncSessions()
            harness.model.refreshNow()
            await eventually { harness.model.link == .live }
        }
        #expect(harness.database.charging.wallboxSessionCount(chargerID: "NX1234567") == 1)
        let row = try #require(harness.database.charging.recentChargingSessions(for: harness.vin).first)
        #expect(abs((row.wallbox?.energyKwh ?? 0) - 16.2) < 0.001)
        harness.model.stop()
    }

    @Test("Sessions finished while Hisingen was closed are recovered on the next connect")
    func recoversSessionsFromWhileClosed() async throws {
        let harness = try ModelHarness()
        seedHistory(harness)
        // The app "launches" hours after the session ended and imports it from Home Assistant's history.
        harness.clock.now = t0
        await harness.connect()
        await harness.model.syncSessions()
        #expect(harness.database.charging.recentChargingSessions(for: harness.vin).count == 1)
        harness.model.stop()
    }

    @Test("A session the durable capture component recorded is imported with its interval record")
    func importsCaptureSessions() async throws {
        let harness = try ModelHarness()
        harness.server.setComponentReply("get_sessions", .fixture("home-assistant-capture-sessions"))
        harness.server.setComponentReply("get_status", planReply(phase: "idle"))
        await harness.connect()
        await harness.model.syncSessions()
        let row = try #require(harness.database.charging.recentChargingSessions(for: harness.vin).first)
        #expect(row.wallbox?.keyKind == "ha_capture_id")
        #expect(row.wallbox?.energyKwh == 16.2)
        #expect(row.startSoc == 41)
        #expect(harness.database.charging.wallboxIntervals(rowID: row.id).count == 2)
        harness.model.stop()
    }

    @Test("Nothing is written when local charging history is switched off")
    func privacyGate() async throws {
        let harness = try ModelHarness()
        harness.scoped.store.storeChargingHistory = false
        seedHistory(harness)
        await harness.connect()
        await harness.model.syncSessions()
        guard case .finished(let summary) = harness.model.syncState else { Issue.record("sync did not finish"); return }
        #expect(summary.skippedByPrivacy)
        #expect(harness.database.charging.wallboxSessionCount(chargerID: "NX1234567") == 0)
        harness.model.stop()
    }

    // MARK: Erase

    @Test("Erasing everything removes the pairing and the token, and the model lets go")
    func eraseEverything() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        #expect(harness.model.hasToken)
        let eraser = LocalDataEraser(
            database: harness.database, preferences: harness.scoped.store,
            imageCache: CarImageCache(), clearAccounts: {})
        try eraser.perform(.everything(.all))
        await eventually { harness.model.pairing == nil }
        #expect(harness.model.pairing == nil)
        #expect(harness.model.link == .notConfigured)
        #expect(!harness.model.hasToken)
        harness.model.stop()
    }

    @Test("A sign-out leaves Home Assistant alone")
    func signOutKeepsHomeAssistant() async throws {
        let harness = try ModelHarness()
        await harness.connect()
        let eraser = LocalDataEraser(database: harness.database, preferences: harness.scoped.store, imageCache: CarImageCache())
        try eraser.perform(.session(.all))
        #expect(harness.model.pairing != nil)
        #expect(harness.model.hasToken)
        harness.model.stop()
    }
}
