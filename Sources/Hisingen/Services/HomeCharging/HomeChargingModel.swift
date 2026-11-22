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
    /// Plans run inside Home Assistant; a charger read straight from its vendor has none.
    case needsHomeAssistant

    var errorDescription: String? {
        switch self {
        case .notPaired: return L10n.text("No charger is paired.")
        case .componentNotInstalled:
            return L10n.text("The Hisingen component is not installed in Home Assistant, so it cannot run a plan.")
        case .rejected(let message): return message
        case .unreachable: return L10n.text("Home Assistant could not be reached.")
        case .needsHomeAssistant:
            return L10n.text("Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history.")
        }
    }
}

/// What one charger reported the last time it was read. Kept for the chargers that do not hold the
/// live connection, so a second charger shows its own state (aged by `lastContact`) instead of
/// disappearing or borrowing the first one's readings.
struct HomeChargingChargerSnapshot: Equatable, Sendable {
    var link: HomeChargingModel.Link
    var telemetry: HomeChargerTelemetry
    var lastContact: Date?
    var planStatus: HomeChargingPlanStatus?
    var sessionPeakKw: Double?
}

/// The optional Home Charging integration: a live connection to the reader's Home Assistant, one
/// or two paired chargers, commands acknowledged by the charger, the plan Home Assistant runs, and
/// the charger's sessions flowing into charging history.
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
        /// `nil` leaves Tibber's live stream off, which is also what happens when it cannot be opened.
        var tibberSocketConnector: (any TibberSocketConnecting)? = URLSessionTibberSocketConnector()
        var now: @Sendable () -> Date = { Date() }
        var wait: AsyncTimerLoop.Wait = AsyncTimerLoop.realWait
        var spotPrices: @Sendable (ElspotZone) async -> [ElectricityPricePoint] = { zone in
            await ElectricityPriceService.shared.cachedPoints(for: zone)
        }
        var timerPrices: @Sendable (ElspotZone) async -> [ElectricityPricePoint] = { zone in
            await ElectricityPriceService.shared.prices(for: zone)
        }
        var observesWake = true
    }

    // MARK: Published state

    /// Every charger this install has paired, in the order they were added. One of them is the
    /// live connection; the others keep their last-known reading.
    @Published private(set) var pairings: [HomeChargingPairing] = []
    /// The last-known reading of chargers that are not the live one, so a second charger is still
    /// visible (with its age) while the first holds the connection.
    @Published private(set) var lastKnown: [String: HomeChargingChargerSnapshot] = [:]
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
    /// The Tibber home that prices sessions, when the reader connected one.
    @Published private(set) var tibberHome: TibberHome?
    /// Why Tibber's prices could not be read on the last import, or `nil`.
    @Published private(set) var tibberProblem: String?
    /// What the grid company charges per kWh on top of Tibber's all-in price, for the planner, for the
    /// house-load costs and for sessions whose charger has no fee of its own.
    @Published private(set) var gridTariff: GridTariff = .none
    private var consumptionCache: (homeID: String, from: Date, fetchedAt: Date, hours: [TibberConsumptionHour])?
    private var productionCache: (homeID: String, from: Date, fetchedAt: Date, hours: [TibberProductionHour])?
    @Published private(set) var lastNexBlueImport: HomeSessionSync.ImportReceipt?
    /// Bumped whenever a sync changed history, so the charging card reloads its sessions.
    @Published private(set) var historyRevision = 0
    /// Ticks while connected so ages ("updated 14 min ago") and staleness keep moving.
    @Published private(set) var clock = Date()

    // MARK: Internals

    /// The optional Perific house meter. It lives beside the charger, not inside the pairing: it reads
    /// the whole house and needs no charger, no vehicle and no Home Assistant.
    let houseMeter: HouseMeterModel
    /// Tibber's live stream, when the connected home has a Pulse (or Watty) reader paired. It reads
    /// the house the Perific meter would, and the production a grid meter cannot see.
    let tibberLive: TibberLiveModel

    private let preferences: PreferencesStore
    private let database: VehicleDatabase
    private let dependencies: Dependencies
    private var store: HomeChargingStore
    private let logger = AppLog.logger("home-charging")

    private var table: [String: HAEntityState] = [:]
    private var client: HomeAssistantClient?
    private var directProvider: (any DirectChargerProvider)?
    private var socket: HomeAssistantSocket?
    private var loopTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pollSleeper: Task<Void, Never>?
    /// Reads the chargers that are not the live connection, so a second charger keeps its own
    /// state visible. It never opens a socket and never commands anything.
    private var secondaryPollTask: Task<Void, Never>?
    private var generation = 0
    private var sessionPeakKw: Double?
    private var lastSyncAt: Date?
    private var syncInFlight = false
    private var timerWriteInFlight = false
    private var pairingRevision = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var eraseObserver: (any NSObjectProtocol)?

    static let pollInterval: TimeInterval = 60
    static let pendingPollInterval: TimeInterval = 10
    static let syncInterval: TimeInterval = 30 * 60

    init(preferences: PreferencesStore, database: VehicleDatabase, dependencies: Dependencies = Dependencies()) {
        self.preferences = preferences
        self.database = database
        self.dependencies = dependencies
        self.houseMeter = HouseMeterModel(preferences: preferences, dependencies: dependencies)
        self.tibberLive = TibberLiveModel(preferences: preferences, dependencies: dependencies)
        self.store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        self.pairings = store.pairings
        self.pairing = self.pairings.first
        self.planRecord = self.pairings.first.flatMap { store.planRecord(for: $0) }
        self.tibberHome = store.tibberHome
        // A flat network fee saved by an earlier version becomes a flat tariff, once.
        if let saved = store.gridTariff {
            self.gridTariff = saved
        } else if store.tibberNetworkFeeOrePerKwh > 0 {
            let migrated = GridTariff.flat(orePerKwh: store.tibberNetworkFeeOrePerKwh)
            store.gridTariff = migrated
            self.gridTariff = migrated
        }
        self.lastNexBlueImport = store.nexBlueImport.flatMap { receipt in
            guard store.pairing?.source == .nexBlue, store.pairing?.chargerID == receipt.chargerID,
                  store.pairing?.vin == receipt.vin else { return nil }
            return receipt
        }
        if pairing != nil { link = .connecting }
        if tibberHome != nil { tibberLive.start() }
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
        pairingRevision &+= 1
        tibberHome = store.tibberHome
        tibberLive.reset()
        pairings = store.pairings
        lastKnown = [:]
        pairing = nil
        lastNexBlueImport = nil
        syncState = .idle
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    var isConfigured: Bool { pairing != nil }

    /// Whether the reader is signed in to the paired charger's service: the stored token for Home
    /// Assistant, the stored account login for a charger Hisingen talks to directly. A login the
    /// service has since rejected still counts, because the card then says so and where to fix it.
    var isSignedIn: Bool {
        guard let pairing else { return false }
        return pairing.source.isDirect ? store.hasCredentials(for: pairing.source) : store.hasToken
    }
    var hasToken: Bool { store.hasToken }
    var savedAddress: String? { store.address }

    /// The stored token, read only when the reader reconnects without typing a new one.
    func savedToken() -> String? { (try? store.token()) ?? nil }

    // MARK: - Lifecycle

    func start() {
        guard pairing != nil, loopTask == nil else { return }
        installWakeObserver()
        launchLoop()
        launchSecondaryPolls()
    }

    func stop() {
        if let pairing { publishSnapshot(for: pairing) }
        generation &+= 1
        secondaryPollTask?.cancel(); secondaryPollTask = nil
        loopTask?.cancel(); loopTask = nil
        eventTask?.cancel(); eventTask = nil
        clockTask?.cancel(); clockTask = nil
        pollSleeper?.cancel(); pollSleeper = nil
        if let socket { Task { await socket.close() } }
        socket = nil
        client = nil
        directProvider = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        link = pairing == nil ? .notConfigured : .reconnecting
    }

    /// Reconnects from scratch and re-reads every reading: after the Mac wakes, and whenever the
    /// reader asks. The readings on screen keep their own timestamps until fresh ones arrive.
    func refreshNow() {
        guard pairing != nil else { return }
        if pairing?.source == .nexBlue { link = .reconnecting }
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
        if let pairing, pairing.source.isDirect {
            await runDirectLoop(generation: current, pairing: pairing)
            return
        }
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
                try await poll(generation: current) {
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
                logger.notice("Home Assistant unavailable: \(String(describing: error), privacy: .private)")
            } catch {
                link = .reconnecting
                tick()
            }
            guard !Task.isCancelled, current == generation else { return }
            try? await dependencies.wait(backoff)
            backoff = min(backoff * 2, 60)
        }
    }

    private func poll(generation current: Int, read: () async throws -> Void) async throws {
        while !Task.isCancelled, current == generation {
            if shouldSyncSessions() { Task { await syncAndReprice() } }
            let interval = command.isPending ? Self.pendingPollInterval : Self.pollInterval
            await sleepForPoll(interval)
            guard !Task.isCancelled, current == generation else { return }
            try await read()
        }
    }

    private func sleepForPoll(_ interval: TimeInterval) async {
        let wait = dependencies.wait
        let sleeper = Task<Void, Never> { _ = try? await wait(interval) }
        pollSleeper = sleeper
        await sleeper.value
    }

    private func nudgePoll() { pollSleeper?.cancel() }

    /// The loop for a charger read straight from its vendor: one read a minute (every ten seconds
    /// while a command waits), the same freshness and confirmation rules as the Home Assistant path.
    private func runDirectLoop(generation current: Int, pairing: HomeChargingPairing) async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled, current == generation {
            guard let provider = directProvider ?? makeDirectProvider(for: pairing) else {
                link = .unauthorized
                return
            }
            directProvider = provider
            do {
                if link != .live { link = .connecting }
                try await readDirect(provider: provider, pairing: pairing)
                backoff = 2
                try await poll(generation: current) {
                    try await readDirect(provider: provider, pairing: pairing)
                }
            } catch DirectChargerError.unauthorized {
                link = .unauthorized
                tick()
                return
            } catch is CancellationError {
                return
            } catch let error as DirectChargerError {
                link = lastContact == nil ? .unreachable(error.localizedDescription) : .reconnecting
                tick()
                logger.notice("\(pairing.source.providerName, privacy: .public) unavailable: \(String(describing: error), privacy: .private)")
                if case .rateLimited(let retryAfter) = error {
                    let delay = retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.pollInterval
                    backoff = max(backoff, min(delay, 86_400))
                }
            } catch {
                link = .reconnecting
                tick()
            }
            guard !Task.isCancelled, current == generation else { return }
            try? await dependencies.wait(backoff)
            backoff = min(backoff * 2, 120)
        }
    }

    private func readDirect(provider: any DirectChargerProvider, pairing: HomeChargingPairing) async throws {
        let now = dependencies.now()
        let fresh = try await provider.telemetry(chargerID: pairing.chargerID, now: now)
        try Task.checkCancellation()
        telemetry = fresh
        lastContact = now
        link = .live
        clock = now
        trackSessionPeak()
        command.observe(telemetry, now: now)
        publishSnapshot(for: pairing)
    }

    private func makeDirectProvider(for pairing: HomeChargingPairing) -> (any DirectChargerProvider)? {
        if pairing.source == .nexBlue {
            let store = store
            guard let token = try? store.nexBlueRefreshToken(), !token.isEmpty else { return nil }
            return nexBlueProvider()
        }
        guard let credentials = (try? store.credentials(for: pairing.source)) ?? nil, credentials.isComplete else { return nil }
        return DirectChargerProviders.make(pairing.source, credentials: credentials, transport: dependencies.transport)
    }

    /// A NexBlue provider that signs in from the saved refresh token, so no password is held.
    private func nexBlueProvider() -> NexBlueProvider {
        let store = store
        return NexBlueProvider(transport: dependencies.transport, now: dependencies.now) { transport in
            guard let previous = try await store.nexBlueRefreshToken() else { throw DirectChargerError.unauthorized }
            let result = try await NexBlueProvider.refresh(previous, transport: transport)
            try await store.updateNexBlueRefreshToken(result.rotatedRefreshToken, previous: previous)
            return result.bearer
        }
    }

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
        let latest = try await fetchStates(client: client, pairing: pairing)
        for id in trackedEntityIDs(pairing) {
            if let state = latest[id] { apply(state) } else { table[id] = nil }
        }
        lastContact = dependencies.now()
        recompute()
    }

    /// One read of a charger's tracked entities, without touching the live connection's table. Used
    /// by the poll that keeps a second charger visible and by the live path itself.
    private func fetchStates(client: HomeAssistantClient,
                             pairing: HomeChargingPairing) async throws -> [String: HAEntityState] {
        let ids = trackedEntityIDs(pairing)
        let fetched = try await withThrowingTaskGroup(of: (String, HAEntityState?).self) { group -> [(String, HAEntityState?)] in
            for id in ids { group.addTask { (id, try await client.state(of: id)) } }
            var all: [(String, HAEntityState?)] = []
            for try await entry in group { all.append(entry) }
            return all
        }
        var latest: [String: HAEntityState] = [:]
        for (id, state) in fetched { if let state { latest[id] = state } }
        return latest
    }

    private func openSocket(pairing: HomeChargingPairing) async {
        guard let connector = dependencies.socketConnector, client != nil else { return }
        if let previous = socket { socket = nil; await previous.close() }
        let address = store.address ?? pairing.baseURL
        guard case .success(let url) = HomeAssistantAddress.normalise(address), let token = (try? store.token()) ?? nil else { return }
        guard let opened = try? await HomeAssistantSocket.open(baseURL: url, token: token, connector: connector) else {
            // Polling carries on alone; the socket only makes updates arrive sooner.
            return
        }
        let tracked = Set(trackedEntityIDs(pairing))
        guard let stream = try? await opened.stateChanges(entityIDs: tracked) else { await opened.close(); return }
        socket = opened
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
            store.setPlanRecord(updated, for: pairing)
        }
        publishSnapshot(for: pairing)
    }

    private func trackSessionPeak() {
        guard let status = telemetry.status?.value else { return }
        switch status {
        case .charging:
            if let power = telemetry.powerKw?.value {
                sessionPeakKw = max(sessionPeakKw ?? 0, power)
                recordChargerPower(power, at: telemetry.powerKw?.timestamp)
            }
        case .unplugged, .finished:
            sessionPeakKw = nil
        default:
            break
        }
    }

    /// Keeps what the charger itself reported, beside the car's own series, so the two can be
    /// laid over each other. Only a reading the charger timestamped, for a car this charger is
    /// paired to, and no more than once a minute.
    private func recordChargerPower(_ kilowatts: Double, at timestamp: Date?) {
        guard preferences.storeChargingHistory, let vin = pairing?.vin, !vin.isEmpty, let timestamp else { return }
        database.history.recordChargerPower(vin: vin, kilowatts: kilowatts, timestamp: timestamp)
    }

    // MARK: - More than one charger

    /// Reads the chargers that are not the live connection every few minutes. One connection keeps
    /// the sockets, the plan and the command feedback; the others stay visible with their own
    /// readings and their age, without a second stream of network traffic.
    static let secondaryPollInterval: TimeInterval = 5 * 60

    private func launchSecondaryPolls() {
        secondaryPollTask?.cancel()
        guard pairings.count > 1 else { secondaryPollTask = nil; return }
        secondaryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled else { return }
                await self.pollOtherChargers()
                do { try await self.dependencies.wait(Self.secondaryPollInterval) } catch { return }
            }
        }
    }

    func pollOtherChargers() async {
        for candidate in pairings where candidate.identity != pairing?.identity {
            if let snapshot = try? await readSnapshot(for: candidate) {
                lastKnown[candidate.identity] = snapshot
            }
        }
    }

    private func readSnapshot(for candidate: HomeChargingPairing) async throws -> HomeChargingChargerSnapshot {
        let now = dependencies.now()
        if candidate.source.isDirect {
            guard let provider = makeDirectProvider(for: candidate) else { throw DirectChargerError.unauthorized }
            let telemetry = try await provider.telemetry(chargerID: candidate.chargerID, now: now)
            return HomeChargingChargerSnapshot(
                link: .live, telemetry: telemetry, lastContact: now, planStatus: nil, sessionPeakKw: nil)
        }
        guard let client = makeClient(for: candidate) else { throw HomeAssistantError.unauthorized }
        let states = try await fetchStates(client: client, pairing: candidate)
        let telemetry = HomeChargerTelemetry.make(from: states, map: candidate.entities)
        let plan = states[HomeChargingPlanEntity.id(chargerID: candidate.chargerID)]
            .flatMap { HomeChargingPlanStatus(entity: $0) }
        return HomeChargingChargerSnapshot(
            link: .live, telemetry: telemetry, lastContact: now, planStatus: plan, sessionPeakKw: nil)
    }

    /// Keeps the snapshot of the live charger current, so switching away and back does not lose its
    /// last reading.
    private func publishSnapshot(for active: HomeChargingPairing) {
        guard pairings.count > 1 else { return }
        lastKnown[active.identity] = HomeChargingChargerSnapshot(
            link: link, telemetry: telemetry, lastContact: lastContact,
            planStatus: planStatus, sessionPeakKw: sessionPeakKw)
    }

    /// What one charger last reported. The live charger answers from its published state; every
    /// other from the snapshot taken when it was last read.
    func snapshot(for target: HomeChargingPairing) -> HomeChargingChargerSnapshot? {
        if pairing?.identity == target.identity {
            return HomeChargingChargerSnapshot(
                link: link, telemetry: telemetry, lastContact: lastContact,
                planStatus: planStatus, sessionPeakKw: sessionPeakKw)
        }
        return lastKnown[target.identity]
    }

    func telemetry(for target: HomeChargingPairing) -> HomeChargerTelemetry {
        snapshot(for: target)?.telemetry ?? HomeChargerTelemetry()
    }

    func link(for target: HomeChargingPairing) -> Link {
        snapshot(for: target)?.link ?? .connecting
    }

    func lastContact(for target: HomeChargingPairing) -> Date? {
        snapshot(for: target)?.lastContact
    }

    func planStatus(for target: HomeChargingPairing) -> HomeChargingPlanStatus? {
        snapshot(for: target)?.planStatus
    }

    /// Which charger holds the live connection. Switching stops the old loop, publishes its last
    /// reading and connects the chosen one; a charger with no saved login stays unselected.
    @discardableResult
    func selectCharger(identity: String) -> Bool {
        guard let target = pairings.first(where: { $0.identity == identity }) else { return false }
        guard pairing?.identity != target.identity else { return true }
        stop()
        pairingRevision &+= 1
        pairing = target
        planRecord = store.planRecord(for: target)
        table = [:]
        telemetry = HomeChargerTelemetry()
        lastContact = nil
        planStatus = nil
        sessionPeakKw = nil
        if let known = lastKnown[target.identity] {
            telemetry = known.telemetry
            lastContact = known.lastContact
            planStatus = known.planStatus
            sessionPeakKw = known.sessionPeakKw
        }
        command = HomeChargerCommandTracker()
        link = .connecting
        lastSyncAt = nil
        syncState = .idle
        start()
        return true
    }

    /// Forgets one charger, keeping the others. The live connection moves to the next charger.
    func unpair(identity: String) {
        guard pairings.contains(where: { $0.identity == identity }) else { return }
        let wasLive = pairing?.identity == identity
        if wasLive { stop() }
        pairingRevision &+= 1
        store.removePairing(identity: identity)
        pairings = store.pairings
        lastKnown.removeValue(forKey: identity)
        lastNexBlueImport = nil
        syncState = .idle
        guard wasLive else { return }
        pairing = nil
        planRecord = nil
        planStatus = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        lastContact = nil
        if let next = pairings.first {
            _ = selectCharger(identity: next.identity)
        } else {
            link = .notConfigured
        }
    }

    /// Whether a charger paired to this vehicle belongs on its card, and which one. A charger at
    /// the vehicle's saved location wins; otherwise the live one; otherwise the first that could
    /// show for the car.
    func chargingPairing(for state: VehicleState) -> HomeChargingPairing? {
        guard isSignedIn else { return nil }
        let candidates = pairings.filter { $0.isPaired(toVehicle: state.identity.vin) }
        if let located = candidates.first(where: { $0.isAtPairedLocation(state.chargeLocationPresence) }) {
            return located
        }
        if let live = candidates.first(where: { $0.identity == pairing?.identity }) { return live }
        return candidates.first
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

    func connectDirect(_ source: ChargerSource, credentials: DirectChargerCredentials) async throws -> [DirectChargerSummary] {
        guard credentials.isComplete else { throw DirectChargerError.unauthorized }
        if source == .nexBlue {
            let result = try await NexBlueProvider.signIn(credentials, transport: dependencies.transport)
            try Task.checkCancellation()
            try store.saveNexBlueRefreshToken(result.refreshToken)
            return result.chargers
        }
        guard let provider = DirectChargerProviders.make(source, credentials: credentials, transport: dependencies.transport) else {
            throw DirectChargerError.unauthorized
        }
        let chargers = try await provider.chargers()
        try Task.checkCancellation()
        try store.saveCredentials(credentials, for: source)
        return chargers
    }

    func hasSavedCredentials(for source: ChargerSource) -> Bool { store.hasCredentials(for: source) }

    /// The chargers on an account that signed in earlier, read with the saved login. Signing in
    /// stores the login before a charger is paired, so a reader who leaves Settings between the two
    /// steps picks up here instead of typing the account again. `nil` when no login is saved.
    func resumeDirect(_ source: ChargerSource) async throws -> [DirectChargerSummary]? {
        guard source.isDirect, store.hasCredentials(for: source) else { return nil }
        if source == .nexBlue {
            guard let token = try store.nexBlueRefreshToken(), !token.isEmpty else { return nil }
            return try await nexBlueProvider().chargers()
        }
        guard let credentials = try store.credentials(for: source), credentials.isComplete,
              let provider = DirectChargerProviders.make(source, credentials: credentials, transport: dependencies.transport) else {
            return nil
        }
        return try await provider.chargers()
    }

    /// Forgets a login that was saved before any charger was paired. A paired vendor keeps its login:
    /// the pairing needs it, and Remove Connection is the way out of that.
    func forgetDirectLogin(_ source: ChargerSource) {
        guard pairing?.source != source else { return }
        store.deleteCredentials(for: source)
    }

    func savedUsername(for source: ChargerSource) -> String? {
        ((try? store.credentials(for: source)) ?? nil)?.username
    }

    /// New login for the existing pairing and a fresh start. For an account whose password changed.
    func replaceCredentials(_ credentials: DirectChargerCredentials) async throws {
        guard let pairing, pairing.source.isDirect, credentials.isComplete else { return }
        if pairing.source == .nexBlue {
            let result = try await NexBlueProvider.signIn(credentials, transport: dependencies.transport)
            try Task.checkCancellation()
            guard pairing == self.pairing else { return }
            guard result.chargers.contains(where: { $0.id == pairing.chargerID }) else {
                throw DirectChargerError.forbidden
            }
            try store.saveNexBlueRefreshToken(result.refreshToken)
        } else {
            try store.saveCredentials(credentials, for: pairing.source)
        }
        directProvider = nil
        link = .connecting
        refreshNow()
        start()
    }

    var supportsPlans: Bool { pairing?.source.supportsPlans ?? false }

    // MARK: - Electricity supplier (Tibber)

    var hasTibberToken: Bool { store.hasTibberToken }

    /// Reads the homes a Tibber token can see, without saving anything.
    func testTibber(token: String) async -> Result<[TibberHome], DirectChargerError> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.unauthorized) }
        do {
            return .success(try await TibberClient(token: trimmed, transport: dependencies.transport).homes())
        } catch let error as DirectChargerError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    func connectTibber(token: String, home: TibberHome) throws {
        try store.saveTibberToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
        store.tibberHome = home
        tibberHome = home
        tibberProblem = nil
        tibberLive.reset()
        tibberLive.start()
        seedRegionIfUnset(for: home)
        // Sessions already imported were priced without it; the next import prices them again.
        lastSyncAt = nil
        if pairing != nil { Task { await syncAndReprice() } }
    }

    /// Reads the connected home again for the price area and grid company, which a home saved by an
    /// earlier version does not carry. Best effort: a failure keeps what is saved.
    func refreshTibberHome() async {
        guard let saved = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else { return }
        // Settings asks every time the card appears; Tibber is only worth asking while something is missing.
        guard saved.priceArea == nil || saved.gridCompany == nil || saved.mainFuseSize == nil else { return }
        guard let homes = try? await TibberClient(token: token, transport: dependencies.transport).homes(),
              let fresh = homes.first(where: { $0.id == saved.id }),
              store.tibberHome?.id == saved.id else { return }
        var updated = saved
        updated.priceArea = fresh.priceArea ?? saved.priceArea
        updated.gridCompany = fresh.gridCompany ?? saved.gridCompany
        updated.mainFuseSize = fresh.mainFuseSize ?? saved.mainFuseSize
        guard updated != store.tibberHome else { return }
        store.tibberHome = updated
        tibberHome = updated
    }

    /// Hourly whole-home consumption from Tibber's meter data for `[from, to]`, or `nil` when Tibber is
    /// not connected or does not answer. Tibber rate-limits, and the meter data moves once an hour, so
    /// one answer is reused for `consumptionCacheLifetime`.
    func houseConsumption(from: Date, to: Date) async -> [TibberConsumptionHour]? {
        guard let home = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else { return nil }
        let now = Date()
        if let cache = consumptionCache, cache.homeID == home.id, cache.from <= from,
           now.timeIntervalSince(cache.fetchedAt) < Self.consumptionCacheLifetime {
            return cache.hours.filter { $0.end > from && $0.start < to }
        }
        let client = TibberClient(token: token, transport: dependencies.transport)
        // Fetch the widest window the client reads, so a narrower period later is served from this.
        let widest = now.addingTimeInterval(-Double(TibberClient.consumptionPageSize * TibberClient.maximumConsumptionPages) * 3_600)
        let fetchFrom = min(from, widest)
        guard let hours = try? await client.consumption(homeID: home.id, from: fetchFrom, to: now.addingTimeInterval(3_600)),
              store.tibberHome?.id == home.id else { return nil }
        consumptionCache = (home.id, fetchFrom, now, hours)
        return hours.filter { $0.end > from && $0.start < to }
    }

    static let consumptionCacheLifetime: TimeInterval = 30 * 60

    /// Hourly production from the connected Tibber home's production metering point for `[from,
    /// to]`, or `nil` when Tibber is not connected or does not answer. Cached beside the
    /// consumption answer, because a completed hour never changes.
    func houseProduction(from: Date, to: Date) async -> [TibberProductionHour]? {
        guard let home = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else { return nil }
        let now = Date()
        if let cache = productionCache, cache.homeID == home.id, cache.from <= from,
           now.timeIntervalSince(cache.fetchedAt) < Self.consumptionCacheLifetime {
            return cache.hours.filter { $0.end > from && $0.start < to }
        }
        let client = TibberClient(token: token, transport: dependencies.transport)
        // Fetch the widest window the client reads, so a narrower period later is served from this.
        let widest = now.addingTimeInterval(-Double(TibberClient.productionPageSize * TibberClient.maximumProductionPages) * 3_600)
        let fetchFrom = min(from, widest)
        guard let hours = try? await client.production(homeID: home.id, from: fetchFrom, to: now.addingTimeInterval(3_600)),
              store.tibberHome?.id == home.id else { return nil }
        productionCache = (home.id, fetchFrom, now, hours)
        return hours.filter { $0.end > from && $0.start < to }
    }

    /// Whether any whole-house meter is connected, so the car-share rows have something to read.
    var hasHouseMeterSource: Bool { tibberHome != nil || houseMeter.isConnected }

    /// The car's share of the house's metered electricity. Tibber's hourly readings are used when
    /// they answer, because they carry what Tibber billed; otherwise the Perific meter's hourly
    /// import. The share says which one it came from. Production is Tibber's alone to report, so it
    /// rides along only with the Tibber share.
    func houseLoadShare(from: Date, to: Date, sessions: [HistoricalChargingSession]) async -> HouseLoadShare? {
        if tibberHome != nil, let hours = await houseConsumption(from: from, to: to),
           let share = HouseLoad.share(hours: hours, sessions: sessions, gridTariff: gridTariff) {
            var share = share
            // An empty answer is a home without a production metering point, so the row stays out.
            if let production = await houseProduction(from: from, to: to), !production.isEmpty {
                share.productionKwh = production.reduce(0) { $0 + $1.kwh }
            }
            return share
        }
        guard houseMeter.isConnected, let hours = await houseMeter.hourlyImport(from: from, to: to),
              var share = HouseLoad.share(hours: hours, sessions: sessions) else { return nil }
        share.meter = .perific
        return share
    }

    func updateGridTariff(_ tariff: GridTariff) {
        store.gridTariff = tariff
        gridTariff = tariff
    }

    /// Names the grid market from the home's own time zone, so the country picker is already answered
    /// for anyone whose home is where they say it is. It runs only while no tariff has been saved, so
    /// a setup the reader already made is never repriced behind their back.
    private func seedRegionIfUnset(for home: TibberHome) {
        guard store.gridTariff == nil,
              let region = GridTariffRegion.matching(timeZoneIdentifier: home.timeZone),
              region != gridTariff.region else { return }
        var seeded = gridTariff
        seeded.region = region
        updateGridTariff(seeded)
    }

    func disconnectTibber() {
        store.clearTibber()
        consumptionCache = nil
        productionCache = nil
        tibberHome = nil
        tibberProblem = nil
        tibberLive.reset()
    }

    /// The connected Tibber home as the charging planner's price source, or `nil` when none is
    /// connected or its prices are not in kronor (the planner is built for Swedish spot prices).
    func plannerTibberSource() -> PlannerPriceProvider.TibberSource? {
        guard let home = store.tibberHome, home.currency == nil || home.currency == "SEK",
              let fetch = tibberPriceSource() else { return nil }
        return PlannerPriceProvider.TibberSource(homeID: home.id, gridTariff: gridTariff, fetch: fetch)
    }

    /// Tibber's prices across a past session with the grid fee added, the same way the session sync
    /// prices it: a fee set on the paired charger wins over the grid tariff. `nil` when Tibber is not
    /// connected, does not answer, or has no slots that far back.
    func sessionPriceSeries(from start: Date, to end: Date) async -> SessionPriceSeries? {
        guard let fetch = tibberPriceSource(), end > start else { return nil }
        let fee = pairing?.networkFeeOrePerKwh ?? 0
        let tariff = fee > 0 ? GridTariff.flat(orePerKwh: fee) : gridTariff
        guard let points = try? await fetch(start.addingTimeInterval(-900), end.addingTimeInterval(900)) else { return nil }
        return SessionPriceSeries.tibber(points, gridTariff: tariff, contract: preferences.electricityRatePolicy.contract,
                                         from: start, to: end)
    }

    /// Tibber's own price source for a sync, or `nil` when none is connected.
    private func tibberPriceSource() -> (@Sendable (Date, Date) async throws -> [HomePricePoint])? {
        guard let home = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else { return nil }
        let client = TibberClient(token: token, transport: dependencies.transport)
        let homeID = home.id
        return { from, to in try await client.prices(homeID: homeID, from: from, to: to) }
    }

    /// Unpairs a direct charger and forgets its login. Signing in again is all it takes to come back.
    func signOutDirect() {
        guard let source = pairing?.source, source.isDirect else { return }
        unpair()
        store.deleteCredentials(for: source)
    }

    func pair(_ newPairing: HomeChargingPairing) {
        stop()
        pairingRevision &+= 1
        if newPairing.source != .nexBlue || newPairing.chargerID != lastNexBlueImport?.chargerID ||
            newPairing.vin != lastNexBlueImport?.vin {
            lastNexBlueImport = nil
            store.nexBlueImport = nil
        }
        store.upsert(newPairing)
        pairings = store.pairings
        if newPairing.source == .homeAssistant { store.address = newPairing.baseURL }
        pairing = newPairing
        planRecord = store.planRecord(for: newPairing)
        table = [:]
        telemetry = HomeChargerTelemetry()
        lastContact = nil
        lastSyncAt = nil
        syncState = .idle
        command = HomeChargerCommandTracker()
        planStatus = nil
        link = .connecting
        start()
    }

    /// Saves a new token for the existing pairing and reconnects. For a token that was rejected or revoked.
    func replaceToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.saveToken(trimmed)
        link = .connecting
        refreshNow()
        start()
    }

    func updateNetworkFee(_ orePerKwh: Double) {
        guard var current = pairing else { return }
        current.networkFeeOrePerKwh = max(0, orePerKwh)
        store.upsert(current)
        pairings = store.pairings
        pairing = current
    }

    /// Unpairs. A plan Home Assistant is still running for this charger is cancelled first, best effort,
    /// so nothing keeps commanding a charger Hisingen no longer controls; the charger is left as it is.
    func unpairCancellingPlan() async {
        if let status = planStatus, !status.phase.isTerminal {
            try? await cancelPlan()
        }
        unpair()
    }

    /// Removes the live charger; another pairing, if any, takes over the connection.
    func unpair() {
        guard let pairing else {
            stop()
            pairingRevision &+= 1
            store.clearPairing()
            pairings = []
            lastKnown = [:]
            link = .notConfigured
            return
        }
        unpair(identity: pairing.identity)
    }

    /// Everything Home Charging holds, the token included. History rows already written stay.
    func eraseEverything() {
        stop()
        houseMeter.disconnect()
        pairingRevision &+= 1
        store.eraseAll()
        consumptionCache = nil
        gridTariff = .none
        tibberHome = nil
        tibberProblem = nil
        pairings = []
        lastKnown = [:]
        pairing = nil
        lastNexBlueImport = nil
        syncState = .idle
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    // MARK: - Where the card shows

    /// Whether the charger section belongs on this vehicle's card. The paired vehicle only. At the
    /// saved location it always shows; elsewhere only a dedicated charger that itself reports a cable.
    /// Never without a saved login.
    func shouldShow(for state: VehicleState) -> Bool {
        guard let target = chargingPairing(for: state) else { return false }
        return shows(target, for: state)
    }

    private func shows(_ target: HomeChargingPairing, for state: VehicleState) -> Bool {
        guard target.isPaired(toVehicle: state.identity.vin) else { return false }
        if target.isAtPairedLocation(state.chargeLocationPresence) { return true }
        if target.locationID == nil { return true }
        if target.isSharedCharger { return false }
        let evidence = telemetry(for: target).connectorEvidence(now: clock, vehicleConnection: nil)
        return evidence.connected == true && evidence.evidence == .confirmedByCharger
    }

    func cardInput(for state: VehicleState) -> HomeChargingCardInput? {
        guard let target = chargingPairing(for: state), shows(target, for: state) else { return nil }
        let name = state.identity.modelName ?? state.model.brand.displayName
        let reading = snapshot(for: target)
        let isLive = target.identity == pairing?.identity
        return HomeChargingCardInput(
            pairing: target, telemetry: reading?.telemetry ?? HomeChargerTelemetry(), now: clock,
            link: reading?.link ?? .connecting, lastContact: reading?.lastContact,
            vehicleName: name, vehicleBatteryPercent: state.energy.batteryPercentage,
            vehicleTargetPercent: state.energy.targetPercentage, vehicleConnection: state.energy.connection,
            plan: reading?.planStatus, command: isLive ? command.phase : .idle,
            vehicleFinish: state.estimatedChargingCompletion,
            currency: preferences.currencySymbol, sessionPeakKw: reading?.sessionPeakKw,
            // Always offered with the planner on: when the component is missing the editor says how to install it.
            canEditPlan: target.source.supportsPlans && preferences.features.contains(.smartChargingPlanner)
        )
    }

    /// Read by the vehicle-side scheduler: while Home Assistant owns a plan for this vehicle – on
    /// any of the paired chargers – it must not send commands.
    func ownsPlan(for vin: String) -> Bool {
        let now = dependencies.now()
        return pairings.contains { candidate in
            let record = candidate.identity == pairing?.identity
                ? (planRecord ?? store.planRecord(for: candidate))
                : store.planRecord(for: candidate)
            return HomeChargingOwnership.isHomeAssistantOwned(vin: vin, record: record, now: now)
        }
    }

    // MARK: - Charger commands

    /// Sends a start or pause through Home Assistant and keeps the card pending until the charger
    /// answers. With a plan active the plan service is used so the plan and the charger agree.
    func send(_ kind: HomeChargerCommandKind) async {
        guard let pairing else { return }
        guard !command.isPending, !timerWriteInFlight else { return }
        let now = dependencies.now()
        if pairing.source.isDirect {
            await sendDirect(kind, pairing: pairing, now: now)
            return
        }
        guard let client else {
            command.begin(kind, now: now)
            command.rejected(reason: L10n.text("Hisingen is not connected to Home Assistant yet."), now: now)
            objectWillChange.send()
            return
        }
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

    /// Commands one named charger, switching the live connection to it first when needed. The
    /// second charger is commanded on its own reading, never through the first one's state.
    ///
    /// Switching primes the connection with one read before the command goes out: the command
    /// tracker compares against that charger's own readings, and a Home Assistant command needs a
    /// client. A reader tapping a charger that has never connected still gets the same spoken
    /// rejection as before, because priming a failed connection leaves the client absent.
    func send(_ kind: HomeChargerCommandKind, for identity: String) async {
        guard let target = pairings.first(where: { $0.identity == identity }) else { return }
        if pairing?.identity != identity {
            guard selectCharger(identity: identity) else { return }
            if target.source.isDirect {
                if let provider = directProvider ?? makeDirectProvider(for: target) {
                    directProvider = provider
                    try? await readDirect(provider: provider, pairing: target)
                }
            } else if let client = client ?? makeClient(for: target) {
                self.client = client
                try? await refreshStates(client: client, pairing: target)
            }
        }
        await send(kind)
    }

    private func sendDirect(_ kind: HomeChargerCommandKind, pairing: HomeChargingPairing, now: Date) async {
        if kind == .start, telemetry.isDisabled?.value == true,
           telemetry.isFresh(telemetry.isDisabled, now: now) {
            command.begin(kind, now: now)
            command.rejected(reason: L10n.text("Charging is disabled on this charger."), now: now)
            objectWillChange.send()
            return
        }
        if pairing.source == .nexBlue,
           !HomeChargingCardInput.nexBlueControlsAvailable(link: link, telemetry: telemetry, now: now) {
            command.begin(kind, now: now)
            command.rejected(reason: L10n.text("Current charger status is required to send this command."), now: now)
            return
        }
        guard let provider = directProvider ?? makeDirectProvider(for: pairing) else {
            command.begin(kind, now: now)
            command.rejected(reason: L10n.format("Hisingen is not signed in to %@ yet.", pairing.source.providerName), now: now)
            objectWillChange.send()
            return
        }
        if HomeChargerCommandTracker.alreadySatisfied(kind, telemetry: telemetry, now: now) {
            command.confirmedWithoutSending(kind, telemetry: telemetry, now: now)
            return
        }
        command.begin(kind, now: now)
        let sentPhase = command.phase
        let revision = pairingRevision
        do {
            try await provider.send(kind, chargerID: pairing.chargerID, telemetry: telemetry)
            guard pairingRevision == revision, command.phase == sentPhase else { return }
            command.accepted(now: dependencies.now())
            nudgePoll()
        } catch let error as DirectChargerError {
            guard pairingRevision == revision, command.phase == sentPhase else { return }
            if pairing.source == .nexBlue {
                if error == .unauthorized {
                    link = .unauthorized
                } else if error.isTransient {
                    link = .reconnecting
                    nudgePoll()
                }
            }
            command.rejected(reason: error.errorDescription ?? "", now: dependencies.now())
        } catch {
            guard pairingRevision == revision, command.phase == sentPhase else { return }
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

    // MARK: - NexBlue timer

    private func nexBlueTimerConnection() throws -> (HomeChargingPairing, NexBlueProvider) {
        guard let pairing, pairing.source == .nexBlue else { throw NexBlueTimerError.changed }
        guard link == .live, let provider = directProvider as? NexBlueProvider else {
            throw DirectChargerError.unreachable
        }
        return (pairing, provider)
    }

    func readNexBlueSchedule() async throws -> NexBlueSchedule {
        let (pairing, provider) = try nexBlueTimerConnection()
        let revision = pairingRevision
        let schedule = try await provider.schedule(chargerID: pairing.chargerID)
        guard pairingRevision == revision, link == .live else { throw NexBlueTimerError.changed }
        return schedule
    }

    func previewNexBlueTimer(hours: Int) async throws -> NexBlueTimerPreview {
        let (pairing, provider) = try nexBlueTimerConnection()
        let revision = pairingRevision
        let zone = preferences.electricityPriceZone
        let schedule = try await provider.schedule(chargerID: pairing.chargerID)
        try schedule.checkAvailable()
        let prices = await dependencies.timerPrices(zone)
        guard pairingRevision == revision, link == .live, preferences.electricityPriceZone == zone else {
            throw NexBlueTimerError.changed
        }
        return try NexBlueTimerPreview.make(chargerID: pairing.chargerID, schedule: schedule, zone: zone,
                                           prices: prices, hours: hours, now: dependencies.now())
    }

    func saveNexBlueTimer(_ preview: NexBlueTimerPreview) async throws {
        let (pairing, provider) = try nexBlueTimerConnection()
        guard pairing.chargerID == preview.chargerID, !timerWriteInFlight, !command.isPending else {
            throw NexBlueTimerError.changed
        }
        timerWriteInFlight = true
        defer { timerWriteInFlight = false }
        let revision = pairingRevision
        try await provider.saveTimer(preview, now: dependencies.now) {
            self.pairingRevision == revision && self.link == .live && self.preferences.electricityPriceZone == preview.zone
        }
        nudgePoll()
    }

    // MARK: - Plans (Home Assistant executes)

    static let componentDomain = "hisingen_home_charging"

    private func planCall(_ service: String, _ data: HAJSONValue) async throws -> HomeChargingPlanStatus? {
        if pairing?.source.supportsPlans == false { throw HomeChargingPlanError.needsHomeAssistant }
        guard let pairing, let resolved = client ?? makeClient(for: pairing) else {
            throw HomeChargingPlanError.unreachable
        }
        if client == nil { self.client = resolved }
        let client = resolved
        do {
            let result = try await client.callService(domain: Self.componentDomain, service: service, data: data, returnResponse: true)
            componentInstalled = true
            return Self.planStatus(from: result.response, chargerID: pairing.chargerID)
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
        // A vehicle-specific plan runs only for the vehicle the charger was explicitly paired with.
        guard let pairing, pairing.isPaired(toVehicle: vin), pairing.chargerID == request.chargerID else {
            throw HomeChargingPlanError.notPaired
        }
        let status = try await planCall("submit_plan", request.actionData)
        let now = dependencies.now()
        let record = HomeChargingPlanRecord(planID: request.planID, vin: vin, chargerID: request.chargerID,
                                            deadline: request.deadline, submittedAt: now)
        planRecord = record
        store.setPlanRecord(record, for: pairing)
        if let status { planStatus = status }
        nudgePoll()
    }

    func cancelPlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        let status = try await planCall("cancel_plan", .object(["charger_id": .string(pairing.chargerID)]))
        if var record = planRecord, record.endedAt == nil {
            record.endedAt = dependencies.now()
            planRecord = record
            store.setPlanRecord(record, for: pairing)
        }
        planStatus = status
    }

    func holdPlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        if let status = try await planCall("pause_plan", .object(["charger_id": .string(pairing.chargerID)])) { planStatus = status }
        nudgePoll()
    }

    /// The range the app will write for a charger current limit. Chargers differ, but every Home
    /// Assistant charger integration exposes a `number` entity whose own min/max is the authority;
    /// this is the outer bound the app is willing to send at all.
    static let chargerCurrentLimitRange = 6...32

    static func clampedCurrentLimit(_ amps: Int, within range: ClosedRange<Int> = chargerCurrentLimitRange) -> Int {
        min(max(amps, range.lowerBound), range.upperBound)
    }

    /// What the paired charger's current-limit entity accepts right now: the entity's own range
    /// inside the outer bound, or the outer bound until the poll has read the entity.
    var currentLimitRange: ClosedRange<Int> {
        Self.currentLimitRange(in: table, entity: pairing?.entities.currentLimitNumber)
    }

    static func currentLimitRange(in table: [String: HAEntityState], entity: String?) -> ClosedRange<Int> {
        entity.flatMap { table[$0] }
            .map { currentLimitRange(fromEntityAttributes: $0.attributes) }
            ?? chargerCurrentLimitRange
    }

    /// The outer bound narrowed to what the charger's own `number` entity accepts. Home Assistant
    /// publishes that as `min` and `max` attributes; a missing, non-numeric or contradictory pair
    /// leaves the outer bound alone.
    static func currentLimitRange(fromEntityAttributes attributes: [String: HAJSONValue]) -> ClosedRange<Int> {
        let outer = chargerCurrentLimitRange
        guard let minimum = attributes["min"]?.doubleValue, let maximum = attributes["max"]?.doubleValue,
              abs(minimum) < 1_000_000, abs(maximum) < 1_000_000 else { return outer }
        let lower = max(outer.lowerBound, Int(minimum.rounded(.up)))
        let upper = min(outer.upperBound, Int(maximum.rounded(.down)))
        return lower <= upper ? lower...upper : outer
    }

    /// Sets the charger's current limit through Home Assistant.
    ///
    /// This is the only charger write the app performs beyond charge/pause, and it exists because
    /// it is the one that needs no vendor API: Home Assistant already models the limit as a
    /// writable `number` entity. Returns the reason when it cannot send, and nil on success.
    @discardableResult
    func setChargerCurrentLimit(_ amps: Int) async -> String? {
        guard let pairing else {
            return L10n.text("Hisingen is not connected to a charger yet.")
        }
        guard let entity = pairing.entities.currentLimitNumber else {
            return L10n.text("No writable current-limit entity is mapped for this charger.")
        }
        guard let client else {
            return L10n.text("Hisingen is not connected to Home Assistant yet.")
        }
        // The entity's own range is the authority; the outer bound only caps what is ever sent.
        // The poll already holds the entity, so the write needs no read of its own. Without it, a
        // failed read is not a failed write, and the outer bound applies.
        var range = currentLimitRange
        if table[entity] == nil, let state = (try? await client.state(of: entity)) ?? nil {
            range = Self.currentLimitRange(fromEntityAttributes: state.attributes)
        }
        let clamped = Self.clampedCurrentLimit(amps, within: range)
        do {
            _ = try await client.callService(
                domain: "number",
                service: "set_value",
                data: .object([
                    "entity_id": .string(entity),
                    "value": .number(Double(clamped)),
                ])
            )
            nudgePoll()
            return nil
        } catch let error as HomeAssistantError {
            return Self.reasonText(error)
        } catch {
            return error.localizedDescription
        }
    }

    func resumePlan() async throws {
        guard let pairing else { throw HomeChargingPlanError.notPaired }
        if let status = try await planCall("resume_plan", .object(["charger_id": .string(pairing.chargerID)])) { planStatus = status }
        nudgePoll()
    }

    private func loadComponentInfo() async {
        guard let pairing, pairing.source.supportsPlans else { return }
        do {
            _ = try await planCall("get_status", .object(["charger_id": .string(pairing.chargerID)]))
        } catch HomeChargingPlanError.componentNotInstalled {
            componentInstalled = false
        } catch {
            // Leave it unknown: a transient failure says nothing about the install.
        }
    }

    /// What the charger really delivers while charging, from its recent sessions, for planning.
    func recentChargingRateKw() -> Double? {
        guard let pairing else { return nil }
        let rate = HomeChargingRate.estimate(fromSessions: database.charging.recentWallboxIntervals(chargerID: pairing.chargerID))
        return rate.flatMap { $0 >= 1 ? $0 : nil }
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
    /// How far back the one-time re-price reaches: Tibber keeps about a month of prices, and a
    /// session older than that would be priced from a weaker source than it has now.
    static let repriceReach: TimeInterval = 30 * 86_400

    /// The regular import, then once per install a second pass over the NexBlue sessions already
    /// stored, so they are priced by when their energy flowed (the hourly readings) and not by the
    /// time the cable was in. A session already stored keeps its key, so the pass rewrites the cost.
    func syncAndReprice() async {
        await syncSessions()
        guard let pairing, pairing.source == .nexBlue, !store.nexBlueRepriced, preferences.storeChargingHistory,
              case .finished = syncState else { return }
        let now = dependencies.now()
        guard let earliest = database.charging.earliestWallboxStart(chargerID: pairing.chargerID) else {
            store.nexBlueRepriced = true
            return
        }
        let start = max(earliest.addingTimeInterval(-86_400), now.addingTimeInterval(-Self.repriceReach))
        await syncSessions(backfill: DateInterval(start: start, end: now), recordsReceipt: false)
        if case .finished = syncState { store.nexBlueRepriced = true }
    }

    /// `recordsReceipt` is false for the re-price, which rewrites costs and imports nothing new, so the
    /// range Settings reports as imported stays the reader's own.
    func syncSessions(backfill: DateInterval? = nil, recordsReceipt: Bool = true) async {
        guard let pairing, !syncInFlight else { return }
        let now = dependencies.now()
        if let backfill {
            guard pairing.source == .nexBlue, backfill.duration > 0,
                  backfill.duration <= Self.maxNexBlueBackfill, backfill.end <= now else { return }
        }
        let client = pairing.source.isDirect ? nil : client
        let direct = pairing.source.isDirect ? (directProvider ?? makeDirectProvider(for: pairing)) : nil
        guard client != nil || direct != nil else { return }
        let revision = pairingRevision
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
            now: now, direct: direct, backfill: backfill,
            canWrite: { self.pairingRevision == revision && self.preferences.storeChargingHistory },
            tibberPrices: tibberPriceSource(), defaultGridTariff: gridTariff)
        do {
            let summary = try await HomeSessionSync.run(environment)
            guard pairingRevision == revision else { return }
            tibberProblem = summary.tibberProblem
            let importedAt = dependencies.now()
            if backfill == nil { lastSyncAt = importedAt }
            if pairing.source == .nexBlue, recordsReceipt, !summary.skippedByPrivacy,
               let start = summary.windowStart, let end = summary.windowEnd {
                let receipt = HomeSessionSync.ImportReceipt(chargerID: pairing.chargerID, vin: pairing.vin,
                                                           importedAt: importedAt, range: DateInterval(start: start, end: end))
                store.nexBlueImport = receipt
                lastNexBlueImport = receipt
            }
            if summary.captureComponentAnswered { store.captureComponentSeen = true; componentInstalled = true }
            syncState = .finished(summary)
            if summary.changedRows > 0 { historyRevision += 1 }
        } catch is CancellationError {
            if pairingRevision == revision { syncState = .idle }
        } catch let error as HomeAssistantError {
            guard pairingRevision == revision else { return }
            syncState = .failed(Self.reasonText(error))
            logger.notice("Charger session sync failed: \(String(describing: error), privacy: .private)")
        } catch let error as DirectChargerError {
            guard pairingRevision == revision else { return }
            syncState = .failed(error.errorDescription ?? "")
            logger.notice("Charger session sync failed: \(String(describing: error), privacy: .private)")
        } catch {
            guard pairingRevision == revision else { return }
            syncState = .failed(error.localizedDescription)
        }
    }

    static let maxNexBlueBackfill: TimeInterval = 366 * 86_400

    var canBackfillNexBlue: Bool {
        pairing?.source == .nexBlue && preferences.storeChargingHistory && link == .live && syncState != .running
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
