import AppKit
import Foundation
import OSLog
import SwiftUI

/// What the plan sensor is called for a charger. The Home Assistant component builds the same
/// name from the same rule, so neither side has to ask the other.
enum HomeChargingPlanEntity {
    static func id(chargerID: String) -> String {
        "sensor.hisingen_home_charging_plan_\(slug(chargerID))"
    }

    static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            let isAlphanumeric = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlphanumeric { result.unicodeScalars.append(scalar) } else if !result.hasSuffix("_") { result.append("_") }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

enum HomeChargingPlanError: Error, Equatable, LocalizedError {
    case notPaired
    case componentNotInstalled
    case rejected(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notPaired: return L10n.text("No charger is paired.")
        case .componentNotInstalled:
            return L10n.text("The Hisingen component is not installed in Home Assistant, so it cannot run a plan.")
        case .rejected(let message): return message
        case .unreachable: return L10n.text("Home Assistant could not be reached.")
        }
    }
}

/// The optional Home Charging integration: a live connection to the reader's Home Assistant, one
/// paired charger, commands acknowledged by the charger, the plan Home Assistant runs, and the
/// charger's sessions flowing into charging history.
///
/// Nothing here is required. With no pairing the model is inert, and when Home Assistant cannot be
/// reached the rest of the app keeps working from the vehicle's own data.
@MainActor
final class HomeChargingModel: ObservableObject {
    enum Link: Equatable, Sendable {
        case notConfigured
        case connecting
        case live
        case reconnecting
        case unreachable(String)
        case unauthorized
    }

    enum SyncState: Equatable {
        case idle
        case running
        case finished(HomeSessionSync.Summary)
        case failed(String)
    }

    @MainActor
    struct Dependencies {
        var transport: any HomeAssistantTransport = URLSessionHomeAssistantTransport()
        /// `nil` runs on polling alone, which is also what happens when the WebSocket cannot be opened.
        var socketConnector: (any HomeAssistantSocketConnecting)? = URLSessionSocketConnector()
        var now: @Sendable () -> Date = { Date() }
        var wait: AsyncTimerLoop.Wait = AsyncTimerLoop.realWait
        var spotPrices: @Sendable (ElspotZone) async -> [ElectricityPricePoint] = { zone in
            await ElectricityPriceService.shared.cachedPoints(for: zone)
        }
        var observesWake = true
    }

    // MARK: Published state

    @Published private(set) var pairing: HomeChargingPairing?
    @Published private(set) var link: Link = .notConfigured
    @Published private(set) var telemetry = HomeChargerTelemetry()
    @Published private(set) var lastContact: Date?
    @Published private(set) var command = HomeChargerCommandTracker()
    @Published private(set) var planStatus: HomeChargingPlanStatus?
    @Published private(set) var planRecord: HomeChargingPlanRecord?
    @Published private(set) var capabilities = HomeChargingCapabilities()
    @Published private(set) var componentInstalled: Bool?
    @Published private(set) var syncState: SyncState = .idle
    /// Bumped whenever a sync changed history, so the charging card reloads its sessions.
    @Published private(set) var historyRevision = 0
    /// Ticks while connected so ages ("updated 14 min ago") and staleness keep moving.
    @Published private(set) var clock = Date()

    // MARK: Internals

    private let preferences: PreferencesStore
    private let database: VehicleDatabase
    private let dependencies: Dependencies
    private var store: HomeChargingStore
    private let logger = AppLog.logger("home-charging")

    private var table: [String: HAEntityState] = [:]
    private var client: HomeAssistantClient?
    private var socket: HomeAssistantSocket?
    private var loopTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pollSleeper: Task<Void, Never>?
    private var generation = 0
    private var sessionPeakKw: Double?
    private var lastSyncAt: Date?
    private var syncInFlight = false
    private var wakeObserver: (any NSObjectProtocol)?
    private var eraseObserver: (any NSObjectProtocol)?

    static let pollInterval: TimeInterval = 60
    static let pendingPollInterval: TimeInterval = 10
    static let syncInterval: TimeInterval = 30 * 60

    init(preferences: PreferencesStore, database: VehicleDatabase, dependencies: Dependencies = Dependencies()) {
        self.preferences = preferences
        self.database = database
        self.dependencies = dependencies
        self.store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        self.pairing = store.pairing
        self.planRecord = store.planRecord
        if pairing != nil { link = .connecting }
        eraseObserver = NotificationCenter.default.addObserver(
            forName: .homeChargingDataErased, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.storeWasErased() }
        }
    }

    /// Settings erased the stored pairing (and perhaps the token) underneath a running model.
    private func storeWasErased() {
        guard store.pairing == nil else { return }
        stop()
        pairing = nil
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    var isConfigured: Bool { pairing != nil }
    var hasToken: Bool { store.hasToken }
    var savedAddress: String? { store.address }

    /// The stored token, read only when the reader reconnects without typing a new one.
    func savedToken() -> String? { (try? store.token()) ?? nil }
    var sessionPeak: Double? { sessionPeakKw }

    // MARK: - Lifecycle

    func start() {
        guard pairing != nil, loopTask == nil else { return }
        installWakeObserver()
        launchLoop()
    }

    func stop() {
        generation &+= 1
        loopTask?.cancel(); loopTask = nil
        eventTask?.cancel(); eventTask = nil
        clockTask?.cancel(); clockTask = nil
        pollSleeper?.cancel(); pollSleeper = nil
        if let socket { Task { await socket.close() } }
        socket = nil
        client = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        link = pairing == nil ? .notConfigured : .reconnecting
    }

    /// Reconnects from scratch and re-reads every reading: after the Mac wakes, and whenever the
    /// reader asks. The readings on screen keep their own timestamps until fresh ones arrive.
    func refreshNow() {
        guard pairing != nil else { return }
        generation &+= 1
        loopTask?.cancel(); loopTask = nil
        eventTask?.cancel(); eventTask = nil
        pollSleeper?.cancel(); pollSleeper = nil
        if let socket { Task { await socket.close() } }
        socket = nil
        launchLoop()
    }

    private func installWakeObserver() {
        guard dependencies.observesWake, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func launchLoop() {
        let current = generation
        if link == .notConfigured { link = .connecting }
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.dependencies.wait(15)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
        loopTask = Task { [weak self] in await self?.runLoop(generation: current) }
    }

    private func tick() {
        clock = dependencies.now()
        command.observe(telemetry, now: clock)
    }

    // MARK: - Connection loop

    private func runLoop(generation current: Int) async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled, current == generation {
            guard let pairing, let client = makeClient(for: pairing) else {
                link = pairing == nil ? .notConfigured : .unauthorized
                return
            }
            self.client = client
            do {
                if link != .live { link = .connecting }
                try await refreshStates(client: client, pairing: pairing)
                link = .live
                backoff = 2
                await openSocket(pairing: pairing)
                await loadComponentInfo()
                while !Task.isCancelled, current == generation {
                    if shouldSyncSessions() { Task { await syncSessions() } }
                    let interval = command.isPending ? Self.pendingPollInterval : Self.pollInterval
                    await sleepForPoll(interval)
                    guard !Task.isCancelled, current == generation else { return }
                    try await refreshStates(client: client, pairing: pairing)
                    link = .live
                }
            } catch HomeAssistantError.unauthorized {
                link = .unauthorized
                tick()
                return
            } catch is CancellationError {
                return
            } catch let error as HomeAssistantError {
                link = lastContact == nil ? .unreachable(error.localizedDescription) : .reconnecting
                tick()
                logger.notice("Home Assistant unavailable: \(String(describing: error), privacy: .public)")
            } catch {
                link = .reconnecting
                tick()
            }
            guard !Task.isCancelled, current == generation else { return }
            try? await dependencies.wait(backoff)
            backoff = min(backoff * 2, 60)
        }
    }

    private func sleepForPoll(_ interval: TimeInterval) async {
        let wait = dependencies.wait
        let sleeper = Task<Void, Never> { _ = try? await wait(interval) }
        pollSleeper = sleeper
        await sleeper.value
    }

    private func nudgePoll() { pollSleeper?.cancel() }

    private func makeClient(for pairing: HomeChargingPairing) -> HomeAssistantClient? {
        let address = store.address ?? pairing.baseURL
        guard case .success(let url) = HomeAssistantAddress.normalise(address),
              let token = (try? store.token()) ?? nil, !token.isEmpty else { return nil }
        return HomeAssistantClient(baseURL: url, token: token, transport: dependencies.transport)
    }

    private func trackedEntityIDs(_ pairing: HomeChargingPairing) -> [String] {
        pairing.entities.allEntityIDs + [HomeChargingPlanEntity.id(chargerID: pairing.chargerID)]
    }

    private func refreshStates(client: HomeAssistantClient, pairing: HomeChargingPairing) async throws {
        let ids = trackedEntityIDs(pairing)
        let fetched = try await withThrowingTaskGroup(of: (String, HAEntityState?).self) { group -> [(String, HAEntityState?)] in
            for id in ids { group.addTask { (id, try await client.state(of: id)) } }
            var all: [(String, HAEntityState?)] = []
            for try await entry in group { all.append(entry) }
            return all
        }
        for (id, state) in fetched {
            if let state { apply(state) } else { table[id] = nil }
        }
        lastContact = dependencies.now()
        recompute()
    }

    private func openSocket(pairing: HomeChargingPairing) async {
        guard let connector = dependencies.socketConnector, let client else { return }
        let address = store.address ?? pairing.baseURL
        guard case .success(let url) = HomeAssistantAddress.normalise(address), let token = (try? store.token()) ?? nil else { return }
        guard let opened = try? await HomeAssistantSocket.open(baseURL: url, token: token, connector: connector) else {
            // Polling carries on alone; the socket only makes updates arrive sooner.
            _ = client
            return
        }
        guard let stream = try? await opened.stateChanges() else { await opened.close(); return }
        socket = opened
        let tracked = Set(trackedEntityIDs(pairing))
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await change in stream {
                guard tracked.contains(change.entityID) else { continue }
                await MainActor.run {
                    guard let self else { return }
                    if let new = change.newState { self.apply(new) }
                    self.lastContact = self.dependencies.now()
                    self.recompute()
                }
            }
            await MainActor.run { [weak self] in
                // The socket ended; the poll loop keeps the readings alive and the next
                // reconnect opens a new one.
                self?.socket = nil
            }
        }
    }

    private func apply(_ state: HAEntityState) {
        if let existing = table[state.entityID], let old = existing.freshestTimestamp,
           let new = state.freshestTimestamp, new < old { return }
        table[state.entityID] = state
    }

    private func recompute() {
        guard let pairing else { return }
        let now = dependencies.now()
        clock = now
        telemetry = HomeChargerTelemetry.make(from: table, map: pairing.entities)
        trackSessionPeak()
        command.observe(telemetry, now: now)
        if let entity = table[HomeChargingPlanEntity.id(chargerID: pairing.chargerID)] {
            planStatus = HomeChargingPlanStatus(entity: entity)
        } else {
            planStatus = nil
        }
        capabilities = HomeChargingCapabilities.evaluate(
            batterySensor: pairing.entities.vehicleBattery.flatMap { table[$0] },
            configured: pairing.entities.vehicleBattery != nil, now: now)
        let updated = HomeChargingOwnership.updated(planRecord, with: planStatus, now: now)
        if updated != planRecord {
            planRecord = updated
            store.planRecord = updated
        }
    }

    private func trackSessionPeak() {
        guard let status = telemetry.status?.value else { return }
        switch status {
        case .charging:
            if let power = telemetry.powerKw?.value { sessionPeakKw = max(sessionPeakKw ?? 0, power) }
        case .unplugged, .finished:
            sessionPeakKw = nil
        default:
            break
        }
    }

    // MARK: - Setup

    /// Checks an address and token without saving either, and reports what Home Assistant holds.
    func testConnection(address: String, token: String) async -> Result<HomeAssistantDiscovery, HomeAssistantError> {
        guard case .success(let url) = HomeAssistantAddress.normalise(address) else { return .failure(.invalidAddress) }
        let client = HomeAssistantClient(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                         transport: dependencies.transport)
        do {
            try await client.ping()
            return .success(try await HomeChargerDiscovery.discover(using: client))
        } catch let error as HomeAssistantError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    func saveConnection(address: String, token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let url) = HomeAssistantAddress.normalise(address) else { throw HomeAssistantError.invalidAddress }
        try store.saveToken(trimmed)
        store.address = url.absoluteString
    }

    func pair(_ newPairing: HomeChargingPairing) {
        stop()
        store.pairing = newPairing
        store.address = newPairing.baseURL
        pairing = newPairing
        table = [:]
        telemetry = HomeChargerTelemetry()
        planStatus = nil
        link = .connecting
        start()
    }

    func updateNetworkFee(_ orePerKwh: Double) {
        guard var current = pairing else { return }
        current.networkFeeOrePerKwh = max(0, orePerKwh)
        store.pairing = current
        pairing = current
    }

    func updateBatterySensor(_ entityID: String?) {
        guard var current = pairing else { return }
        current.entities.vehicleBattery = entityID?.isEmpty == false ? entityID : nil
        store.pairing = current
        pairing = current
        refreshNow()
    }

    func unpair() {
        stop()
        store.clearPairing()
        pairing = nil
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    /// Everything Home Charging holds, the token included. History rows already written stay.
    func eraseEverything() {
        stop()
        store.eraseAll()
        pairing = nil
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    // MARK: - Where the card shows

    /// Whether the charger section belongs on this vehicle's card. The paired vehicle only. At the
    /// saved location it always shows; elsewhere only a dedicated charger that itself reports a cable.
    func shouldShow(for state: VehicleState) -> Bool {
        guard let pairing, pairing.isPaired(toVehicle: state.identity.vin) else { return false }
        if pairing.isAtPairedLocation(state.chargeLocationPresence) { return true }
        if pairing.locationID == nil { return true }
        if pairing.isSharedCharger { return false }
        let evidence = telemetry.connectorEvidence(now: clock, vehicleConnection: nil)
        return evidence.connected == true && evidence.evidence == .confirmedByCharger
    }

    func cardInput(for state: VehicleState) -> HomeChargingCardInput? {
        guard let pairing, shouldShow(for: state) else { return nil }
        let name = state.identity.modelName ?? state.model.brand.displayName
        return HomeChargingCardInput(
            pairing: pairing, telemetry: telemetry, now: clock, link: link, lastContact: lastContact,
            vehicleName: name, vehicleBatteryPercent: state.energy.batteryPercentage,
            vehicleTargetPercent: state.energy.targetPercentage, vehicleConnection: state.energy.connection,
            plan: planStatus, command: command.phase, vehicleFinish: state.estimatedChargingCompletion,
            currency: preferences.currencySymbol, sessionPeakKw: sessionPeakKw,
            canEditPlan: preferences.features.contains(.smartChargingPlanner) && componentInstalled != false
        )
    }

    /// Read by the vehicle-side scheduler: while Home Assistant owns the plan it must not send commands.
    func ownsPlan(for vin: String) -> Bool {
        HomeChargingOwnership.isHomeAssistantOwned(vin: vin, record: planRecord ?? store.planRecord, now: dependencies.now())
    }

    // MARK: - Charger commands

    /// Sends a start or pause through Home Assistant and keeps the card pending until the charger
    /// answers. With a plan active the plan service is used so the plan and the charger agree.
    func send(_ kind: HomeChargerCommandKind) async {
        guard let pairing, let client else { return }
        guard !command.isPending else { return }
        let now = dependencies.now()
        if HomeChargerCommandTracker.alreadySatisfied(kind, telemetry: telemetry, now: now) {
            command.confirmedWithoutSending(kind, telemetry: telemetry, now: now)
            return
        }
        command.begin(kind, now: now)
        do {
            if let status = planStatus, !status.phase.isTerminal, planRecord?.endedAt == nil {
                let service = kind == .start ? "charge_now" : "pause_plan"
                _ = try await client.callService(domain: Self.componentDomain, service: service,
                                                 data: .object(["charger_id": .string(pairing.chargerID)]), returnResponse: true)
            } else {
                guard let entity = pairing.entities.chargingSwitch else {
                    command.rejected(reason: L10n.text("No charging switch is mapped for this charger."), now: dependencies.now())
                    return
                }
                _ = try await client.callService(domain: "switch", service: kind == .start ? "turn_on" : "turn_off",
                                                 data: .object(["entity_id": .string(entity)]))
            }
            command.accepted(now: dependencies.now())
            nudgePoll()
        } catch let error as HomeAssistantError {
            command.rejected(reason: Self.reasonText(error), now: dependencies.now())
        } catch {
            command.rejected(reason: error.localizedDescription, now: dependencies.now())
        }
        objectWillChange.send()
    }

    func dismissCommandResult() {
        command.dismiss()
        objectWillChange.send()
    }

    private static func reasonText(_ error: HomeAssistantError) -> String {
        switch error {
        case .rejected(_, let message) where !message.isEmpty: return message
        default: return error.localizedDescription
        }
    }

    // MARK: - Plans (Home Assistant executes)

    static let componentDomain = "hisingen_home_charging"

    private func planCall(_ service: String, _ data: HAJSONValue) async throws -> HomeChargingPlanStatus? {
        guard let client else { throw HomeChargingPlanError.unreachable }
        do {
            let result = try await client.callService(domain: Self.componentDomain, service: service, data: data, returnResponse: true)
            componentInstalled = true
            return Self.planStatus(from: result.response, chargerID: pairing?.chargerID ?? "")
        } catch HomeAssistantError.notFound {
            componentInstalled = false
            throw HomeChargingPlanError.componentNotInstalled
        } catch HomeAssistantError.rejected(let status, let message) where status == 400 && message.lowercased().contains("service") {
            componentInstalled = false
            throw HomeChargingPlanError.componentNotInstalled
        } catch let error as HomeAssistantError {
            if error.isTransient { throw HomeChargingPlanError.unreachable }
            throw HomeChargingPlanError.rejected(Self.reasonText(error))
        }
    }

    /// The component answers with `{state, attributes}`, the same fields the plan sensor holds.
    static func planStatus(from response: HAJSONValue?, chargerID: String) -> HomeChargingPlanStatus? {
        guard let object = response?.objectValue, let state = object["state"]?.stringValue else { return nil }
        return HomeChargingPlanStatus(entity: HAEntityState(
            entityID: HomeChargingPlanEntity.id(chargerID: chargerID), state: state,
            attributes: object["attributes"]?.objectValue ?? [:]))
    }

    /// The plan Home Assistant would run, without starting it.
    func previewPlan(_ request: HomeChargingPlanRequest) async throws -> HomeChargingPlanStatus? {
        try await planCall("preview_plan", request.actionData)
    }

    func submitPlan(_ request: HomeChargingPlanRequest, vin: String) async throws {
        let status = try await planCall("submit_plan", request.actionData)
        let now = dependencies.now()
        let record = HomeChargingPlanRecord(planID: request.planID, vin: vin, chargerID: request.chargerID,
                                            deadline: request.deadline, submittedAt: now)
        planRecord = record
        store.planRecord = record
        if let status { planStatus = status }
        nudgePoll()
    }

    func cancelPlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        let status = try await planCall("cancel_plan", .object(["charger_id": .string(pairing.chargerID)]))
        if var record = planRecord, record.endedAt == nil {
            record.endedAt = dependencies.now()
            planRecord = record
            store.planRecord = record
        }
        planStatus = status
    }

    func holdPlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        if let status = try await planCall("pause_plan", .object(["charger_id": .string(pairing.chargerID)])) { planStatus = status }
        nudgePoll()
    }

    func resumePlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        if let status = try await planCall("resume_plan", .object(["charger_id": .string(pairing.chargerID)])) { planStatus = status }
        nudgePoll()
    }

    private func loadComponentInfo() async {
        guard let pairing else { return }
        do {
            _ = try await planCall("get_status", .object(["charger_id": .string(pairing.chargerID)]))
        } catch HomeChargingPlanError.componentNotInstalled {
            componentInstalled = false
        } catch {
            // Leave it unknown: a transient failure says nothing about the install.
        }
    }

    // MARK: - Setup conflicts

    /// Home Assistant automations that reference the charger's switch. Best effort: it needs an
    /// administrator token and the `search/related` command, and returns nothing when either is missing.
    func automationsUsingCharger() async -> [String] {
        guard let pairing, let switchID = pairing.entities.chargingSwitch, let client else { return [] }
        let address = store.address ?? pairing.baseURL
        guard case .success(let url) = HomeAssistantAddress.normalise(address), let token = (try? store.token()) ?? nil,
              let connector = dependencies.socketConnector,
              let socket = try? await HomeAssistantSocket.open(baseURL: url, token: token, connector: connector) else { return [] }
        defer { Task { await socket.close() } }
        guard let related = try? await socket.command("search/related", fields: [
            "item_type": .string("entity"), "item_id": .string(switchID)
        ]), let ids = related.objectValue?["automation"]?.arrayValue?.compactMap(\.stringValue) else { return [] }
        var names: [String] = []
        for id in ids {
            let state = try? await client.state(of: id)
            if let state, state.state == "on" { names.append(state.friendlyName ?? id) }
        }
        return names
    }

    // MARK: - Session sync

    private func shouldSyncSessions() -> Bool {
        guard !syncInFlight, pairing != nil else { return false }
        guard let last = lastSyncAt else { return true }
        return dependencies.now().timeIntervalSince(last) >= Self.syncInterval
    }

    /// Imports the charger's completed sessions into charging history. Safe to call at any time.
    func syncSessions() async {
        guard let pairing, let client, !syncInFlight else { return }
        syncInFlight = true
        syncState = .running
        defer { syncInFlight = false }
        let policy = preferences.electricityRatePolicy
        let spot = policy.isAutomatic ? await dependencies.spotPrices(preferences.electricityPriceZone) : []
        let environment = HomeSessionSync.Environment(
            client: client, pairing: pairing, ledger: database.charging,
            recordingEnabled: preferences.storeChargingHistory,
            fallback: HomeSessionPricer.Fallback(fixedPricePerKwh: preferences.electricityPricePerKwh, policy: policy,
                                                 spotPrices: spot, currency: preferences.currencySymbol),
            now: dependencies.now())
        do {
            let summary = try await HomeSessionSync.run(environment)
            lastSyncAt = dependencies.now()
            if summary.captureComponentAnswered { store.captureComponentSeen = true; componentInstalled = true }
            syncState = .finished(summary)
            if summary.changedRows > 0 { historyRevision += 1 }
        } catch let error as HomeAssistantError {
            syncState = .failed(Self.reasonText(error))
            logger.notice("Charger session sync failed: \(String(describing: error), privacy: .public)")
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }
}

extension Notification.Name {
    /// Posted after the Home Charging pairing or token was erased from storage.
    static let homeChargingDataErased = Notification.Name("io.kheirallah.hisingen.home-charging-erased")
}

private struct HomeChargingModelKey: EnvironmentKey {
    static let defaultValue: HomeChargingModel? = nil
}

extension EnvironmentValues {
    /// The optional Home Charging integration; `nil` when the app was built without one (previews, tests).
    var homeCharging: HomeChargingModel? {
        get { self[HomeChargingModelKey.self] }
        set { self[HomeChargingModelKey.self] = newValue }
    }
}
