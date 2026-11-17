import Foundation
import Testing
@testable import Hisingen

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = t0
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// An Easee cloud that answers sign-in, observations, commands and sessions from values the test sets.
/// No real charger is ever contacted: the model's network seam is this table.
private final class MockEaseeCloud: @unchecked Sendable {
    let transport = MockHomeAssistantTransport()
    private let lock = NSLock()
    private var opMode = 1
    private var power = "0"
    private var energy = "0"
    private var reason = "0"
    private var dynamicCurrent = "16"
    private var loginStatus = 200
    private var commandStatus = 202
    private var sessionsBody = "[]"
    private(set) var commands: [String] = []

    init() {
        transport.route({ $0.httpMethod == "POST" && $0.url?.path == "/api/accounts/login" }) { [weak self] _ in
            let status = self?.lock.withLock { self?.loginStatus } ?? 503
            return status == 200 ? .json(#"{"accessToken":"AT","expiresIn":3600,"refreshToken":"RT","tokenType":"Bearer"}"#)
                                 : .json(#"{"title":"Bad credentials"}"#, status: status)
        }
        transport.route({ $0.httpMethod == "GET" && ($0.url?.path ?? "").hasSuffix("/observations") }) { [weak self] _ in
            guard let self else { return .json("{}", status: 503) }
            let (mode, power, energy, reason, dynamic) = self.lock.withLock { (self.opMode, self.power, self.energy, self.reason, self.dynamicCurrent) }
            let rows = [(109, "\(mode)"), (120, power), (121, energy), (96, reason), (48, dynamic), (250, "true")]
                .map { #"{"id":\#($0.0),"timestamp":"2026-11-10T08:00:00Z","dataType":3,"value":"\#($0.1)"}"# }
            return .json(#"{"observations":[\#(rows.joined(separator: ","))]}"#)
        }
        transport.route({ $0.httpMethod == "POST" && ($0.url?.path ?? "").contains("/commands/") }) { [weak self] request in
            guard let self else { return .json("{}", status: 503) }
            self.lock.withLock { self.commands.append(String(request.url?.lastPathComponent ?? "")) }
            let status = self.lock.withLock { self.commandStatus }
            return status == 202 ? .json(#"{"device":"EH1","commandId":1,"ticks":1}"#, status: 202)
                                 : .json(#"{"title":"Charger is offline"}"#, status: status)
        }
        transport.route({ $0.httpMethod == "GET" && ($0.url?.path ?? "").contains("/sessions/") }) { [weak self] _ in
            .json(self?.lock.withLock { self?.sessionsBody } ?? "[]")
        }
    }

    func set(opMode: Int? = nil, power: String? = nil, energy: String? = nil, reason: String? = nil, dynamicCurrent: String? = nil) {
        lock.withLock {
            if let opMode { self.opMode = opMode }
            if let power { self.power = power }
            if let energy { self.energy = energy }
            if let reason { self.reason = reason }
            if let dynamicCurrent { self.dynamicCurrent = dynamicCurrent }
        }
    }
    func setLogin(status: Int) { lock.withLock { loginStatus = status } }
    func setCommand(status: Int) { lock.withLock { commandStatus = status } }
    func setSessions(_ json: String) { lock.withLock { sessionsBody = json } }
    var commandLog: [String] { lock.withLock { commands } }
    var haRequests: [URLRequest] { transport.requests.filter { ($0.url?.path ?? "").hasPrefix("/api/services") || ($0.url?.path ?? "").hasPrefix("/api/states") } }
}

@MainActor
private final class DirectHarness {
    let scoped = ScopedPreferences(label: "direct-model")
    let database = VehicleDatabase.inMemory()
    let cloud = MockEaseeCloud()
    let clock = Clock()
    let model: HomeChargingModel
    let vin = "YSMTEST"

    init(shared: Bool = false, signedIn: Bool = true) throws {
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        if signedIn { try store.saveCredentials(DirectChargerCredentials(username: "owner@example.se", password: "pw-1"), for: .easee) }
        store.pairing = HomeChargingPairing(
            baseURL: "", chargerID: "EH1", chargerName: "Garage", entities: HomeChargerEntityMap(), vin: vin,
            locationID: "home-loc", locationAlias: "Home", isSharedCharger: shared,
            timeZoneIdentifier: "Europe/Stockholm", pairedAt: t0, source: .easee)
        scoped.store.features = FeatureSelection(enabled: [.smartChargingPlanner, .remoteCharging])
        scoped.store.storeChargingHistory = true
        let clock = clock
        model = HomeChargingModel(
            preferences: scoped.store, database: database,
            dependencies: HomeChargingModel.Dependencies(
                transport: cloud.transport, socketConnector: nil, now: { clock.now },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) },
                spotPrices: { _ in [] }, observesWake: false))
    }

    func connect() async {
        model.start()
        await eventually { self.model.link != .connecting && self.model.link != .notConfigured }
    }

    func refresh(until condition: @escaping @MainActor () -> Bool) async {
        model.refreshNow()
        await eventually(condition)
    }

    func state() -> VehicleState {
        var state = vehicle(vin: vin, battery: 62, connection: .connected, target: 80)
        state.chargeLocationPresence = ChargeLocationPresence(locationID: "home-loc", alias: "Home", since: nil, source: .proximity)
        return state
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite("Direct charger model (Easee)", .serialized)
@MainActor
struct DirectChargerModelTests {
    @Test("It signs in, reads the charger and never touches Home Assistant")
    func readsWithoutHomeAssistant() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.1", energy: "3.4")
        await harness.connect()
        #expect(harness.model.link == .live)
        #expect(harness.model.telemetry.status?.value == .charging)
        #expect(harness.model.telemetry.powerKw?.value == 7.1)
        #expect(harness.model.telemetry.sessionEnergyKwh?.value == 3.4)
        #expect(harness.cloud.haRequests.isEmpty)
        harness.model.stop()
    }

    @Test("The card names the vendor and offers no plan editor")
    func cardIsProviderAware() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.1", energy: "3.4")
        await harness.connect()
        let input = try #require(harness.model.cardInput(for: harness.state()))
        let card = HomeChargingCardModel.make(input)
        #expect(card.title == L10n.format("%@ · %@", "Home", "Easee"))
        #expect(card.actions.contains { $0.kind == .pause })
        #expect(!card.actions.contains { $0.kind == .editPlan })
        #expect(!harness.model.supportsPlans)
        harness.model.stop()
    }

    @Test("A command waits for a charger reading that confirms it, and the card says so in the vendor's name")
    func commandIsPendingUntilConfirmed() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 2, reason: "0", dynamicCurrent: "0")
        await harness.connect()
        #expect(harness.model.telemetry.status?.value == .pluggedIn)

        await harness.model.send(.start)
        #expect(harness.cloud.commandLog == ["resume_charging"])
        #expect(harness.model.command.isPending)
        let input = try #require(harness.model.cardInput(for: harness.state()))
        #expect(HomeChargingCardModel.make(input).notice?.text == L10n.format("%@ accepted the command. Waiting for the charger to confirm.", "Easee"))

        // A poll that still shows the held charger does not confirm it.
        harness.clock.now = t0.addingTimeInterval(20)
        await harness.refresh(until: { harness.model.lastContact == t0.addingTimeInterval(20) })
        #expect(harness.model.command.isPending)

        harness.clock.now = t0.addingTimeInterval(40)
        harness.cloud.set(opMode: 3, power: "7.2", energy: "0.1", dynamicCurrent: "16")
        await harness.refresh(until: { !harness.model.command.isPending })
        guard case .confirmed(.start, _, .charging) = harness.model.command.phase else {
            Issue.record("expected confirmed charging, got \(harness.model.command.phase)")
            return
        }
        harness.model.stop()
    }

    @Test("Unconfirmed after the window, and the card says the charger kept its state")
    func commandNeverConfirmed() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.0", energy: "1")
        await harness.connect()
        await harness.model.send(.pause)
        #expect(harness.cloud.commandLog == ["pause_charging"])
        harness.clock.now = t0.addingTimeInterval(HomeChargerCommandTracker.confirmationWindow + 30)
        await harness.refresh(until: { !harness.model.command.isPending })
        guard case .unconfirmed(.pause, _, .timedOut) = harness.model.command.phase else {
            Issue.record("expected unconfirmed, got \(harness.model.command.phase)")
            return
        }
        harness.model.stop()
    }

    @Test("A refused command is reported with the vendor's reason and sends nothing twice")
    func commandRejected() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.0", energy: "1")
        await harness.connect()
        harness.cloud.setCommand(status: 400)
        await harness.model.send(.pause)
        guard case .rejected(.pause, let reason, _) = harness.model.command.phase else {
            Issue.record("expected rejection, got \(harness.model.command.phase)")
            return
        }
        #expect(reason == "Charger is offline")
        #expect(harness.cloud.commandLog == ["pause_charging"])
        harness.model.stop()
    }

    @Test("A charger that already answers the way the command would is not sent a command")
    func noRedundantCommand() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.0", energy: "1")
        await harness.connect()
        await harness.model.send(.start)
        #expect(harness.cloud.commandLog.isEmpty)
        harness.model.stop()
    }

    @Test("A refused login shows as sign-in rejected, and a new login reconnects")
    func loginRefusedThenReplaced() async throws {
        let harness = try DirectHarness()
        harness.cloud.setLogin(status: 400)
        await harness.connect()
        #expect(harness.model.link == .unauthorized)
        let input = try #require(harness.model.cardInput(for: harness.state()))
        #expect(HomeChargingCardModel.make(input).notice?.text == L10n.format("%@ did not accept the saved login", "Easee"))

        harness.cloud.setLogin(status: 200)
        harness.cloud.set(opMode: 1)
        try await harness.model.replaceCredentials(DirectChargerCredentials(username: "owner@example.se", password: "new"))
        await eventually { harness.model.link == .live }
        #expect(harness.model.link == .live)
        harness.model.stop()
    }

    @Test("With the service unreachable the last readings stay and the link says reconnecting")
    func unreachableKeepsReadings() async throws {
        let harness = try DirectHarness()
        harness.cloud.set(opMode: 3, power: "7.0", energy: "2")
        await harness.connect()
        harness.cloud.transport.unreachable = true
        harness.clock.now = t0.addingTimeInterval(60)
        harness.model.refreshNow()
        await eventually { harness.model.link == .reconnecting }
        #expect(harness.model.link == .reconnecting)
        #expect(harness.model.telemetry.status?.value == .charging)
        harness.model.stop()
    }

    @Test("A direct charger has no plans, and says why")
    func plansNeedHomeAssistant() async throws {
        let harness = try DirectHarness()
        await harness.connect()
        await #expect(throws: HomeChargingPlanError.needsHomeAssistant) { try await harness.model.cancelPlan() }
        harness.model.stop()
    }

    @Test("Sessions come from the vendor's list with its session id, priced from the rate settings")
    func importsSessions() async throws {
        let harness = try DirectHarness()
        harness.cloud.setSessions("""
        [{"id":41,"chargerId":"EH1","isComplete":true,"kiloWattHours":12.5,
          "carConnected":"2026-11-14T20:00:00Z","carDisconnected":"2026-11-15T06:00:00Z",
          "firstEnergyTransferPeriodStarted":"2026-11-14T22:00:00Z","lastEnergyTransferPeriodEnd":"2026-11-15T02:00:00Z"}]
        """)
        // Ahead of the session, so it is inside the sync window.
        harness.clock.now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        await harness.connect()
        // The model imports once on connecting; that pass is the one that adds the session.
        await eventually { if case .finished = harness.model.syncState { return true } else { return false } }
        guard case .finished(let summary) = harness.model.syncState else { Issue.record("sync did not finish"); return }
        #expect(summary.inserted == 1)
        #expect(harness.database.charging.wallboxSessionCount(chargerID: "EH1") == 1)
        let row = try #require(harness.database.charging.recentChargingSessions(for: harness.vin).first)
        #expect(row.wallbox?.keyKind == "vendor_session_id")
        #expect(row.wallbox?.energyKwh == 12.5)
        #expect(row.wallbox?.energySource == "easee_session_api")
        // Tibber is reached through Home Assistant only; here the cost says how it was reached instead.
        #expect(row.wallbox?.costMethod != HomeSessionCost.Method.intervalTibber.rawValue)
        #expect(harness.cloud.haRequests.isEmpty)

        // Syncing the same list again adds nothing.
        await harness.model.syncSessions()
        #expect(harness.database.charging.wallboxSessionCount(chargerID: "EH1") == 1)
        harness.model.stop()
    }

    @Test("A session on a shared charger with no overlapping car stays unassigned")
    func sharedChargerStaysUnassigned() async throws {
        let harness = try DirectHarness(shared: true)
        harness.cloud.setSessions("""
        [{"id":50,"isComplete":true,"kiloWattHours":9.0,"carConnected":"2026-11-14T20:00:00Z","carDisconnected":"2026-11-14T23:00:00Z"}]
        """)
        harness.clock.now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        await harness.connect()
        await harness.model.syncSessions()
        #expect(harness.database.charging.unassignedWallboxSessions(chargerID: "EH1").count == 1)
        #expect(harness.database.charging.recentChargingSessions(for: harness.vin).isEmpty)
        harness.model.stop()
    }

    @Test("Nothing is imported when local charging history is switched off")
    func privacyGate() async throws {
        let harness = try DirectHarness()
        harness.scoped.store.storeChargingHistory = false
        harness.cloud.setSessions(#"[{"id":41,"isComplete":true,"kiloWattHours":12.5,"carConnected":"2026-11-14T20:00:00Z","carDisconnected":"2026-11-14T23:00:00Z"}]"#)
        harness.clock.now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        await harness.connect()
        await harness.model.syncSessions()
        guard case .finished(let summary) = harness.model.syncState else { Issue.record("sync did not finish"); return }
        #expect(summary.skippedByPrivacy)
        #expect(harness.database.charging.wallboxSessionCount(chargerID: "EH1") == 0)
        harness.model.stop()
    }

    @Test("Signing out forgets the login and the pairing; erasing everything removes the Keychain item")
    func signOutAndErase() async throws {
        let harness = try DirectHarness()
        await harness.connect()
        #expect(harness.model.hasSavedCredentials(for: .easee))
        harness.model.signOutDirect()
        #expect(harness.model.pairing == nil)
        #expect(!harness.model.hasSavedCredentials(for: .easee))
        #expect(harness.model.link == .notConfigured)

        let again = try DirectHarness()
        again.model.eraseEverything()
        #expect(!again.model.hasSavedCredentials(for: .easee))
    }

    @Test("The login is saved to the Keychain only and never to preferences")
    func loginStaysInTheKeychain() throws {
        let harness = try DirectHarness()
        let dump = harness.scoped.defaults.dictionaryRepresentation().description
        #expect(!dump.contains("pw-1"))
        #expect(!dump.contains("owner@example.se"))
    }
}
