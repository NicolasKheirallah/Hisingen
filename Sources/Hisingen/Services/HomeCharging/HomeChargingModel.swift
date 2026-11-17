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
        var timerPrices: @Sendable (ElspotZone) async -> [ElectricityPricePoint] = { zone in
            await ElectricityPriceService.shared.prices(for: zone)
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
    /// The Tibber home that prices sessions, when the reader connected one.
    @Published private(set) var tibberHome: TibberHome?
    /// Why Tibber's prices could not be read on the last import, or `nil`.
    @Published private(set) var tibberProblem: String?
    @Published private(set) var lastNexBlueImport: HomeSessionSync.ImportReceipt?
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
    private var directProvider: (any DirectChargerProvider)?
    private var socket: HomeAssistantSocket?
    private var loopTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pollSleeper: Task<Void, Never>?
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
        self.store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        self.pairing = store.pairing
        self.planRecord = store.planRecord
        self.tibberHome = store.tibberHome
        self.lastNexBlueImport = store.nexBlueImport.flatMap { receipt in
            guard store.pairing?.source == .nexBlue, store.pairing?.chargerID == receipt.chargerID,
                  store.pairing?.vin == receipt.vin else { return nil }
            return receipt
        }
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
        pairingRevision &+= 1
        tibberHome = store.tibberHome
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
                while !Task.isCancelled, current == generation {
                    if shouldSyncSessions() { Task { await syncSessions() } }
                    let interval = command.isPending ? Self.pendingPollInterval : Self.pollInterval
                    await sleepForPoll(interval)
                    guard !Task.isCancelled, current == generation else { return }
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
    }

    private func makeDirectProvider(for pairing: HomeChargingPairing) -> (any DirectChargerProvider)? {
        if pairing.source == .nexBlue {
            let store = store
            guard let token = try? store.nexBlueRefreshToken(), !token.isEmpty else { return nil }
            return NexBlueProvider(transport: dependencies.transport, now: dependencies.now) { transport in
                guard let previous = try await store.nexBlueRefreshToken() else { throw DirectChargerError.unauthorized }
                let result = try await NexBlueProvider.refresh(previous, transport: transport)
                try await store.updateNexBlueRefreshToken(result.rotatedRefreshToken, previous: previous)
                return result.bearer
            }
        }
        guard let credentials = (try? store.credentials(for: pairing.source)) ?? nil, credentials.isComplete else { return nil }
        return DirectChargerProviders.make(pairing.source, credentials: credentials, transport: dependencies.transport)
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
        guard let connector = dependencies.socketConnector, client != nil else { return }
        if let previous = socket { socket = nil; await previous.close() }
        let address = store.address ?? pairing.baseURL
        guard case .success(let url) = HomeAssistantAddress.normalise(address), let token = (try? store.token()) ?? nil else { return }
        guard let opened = try? await HomeAssistantSocket.open(baseURL: url, token: token, connector: connector) else {
            // Polling carries on alone; the socket only makes updates arrive sooner.
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
        // Sessions already imported were priced without it; the next import prices them again.
        lastSyncAt = nil
        if pairing != nil { Task { await syncSessions() } }
    }

    func disconnectTibber() {
        store.clearTibber()
        tibberHome = nil
        tibberProblem = nil
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
        store.pairing = newPairing
        if newPairing.source == .homeAssistant { store.address = newPairing.baseURL }
        pairing = newPairing
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

    /// Unpairs. A plan Home Assistant is still running for this charger is cancelled first, best effort,
    /// so nothing keeps commanding a charger Hisingen no longer controls; the charger is left as it is.
    func unpairCancellingPlan() async {
        if let status = planStatus, !status.phase.isTerminal {
            try? await cancelPlan()
        }
        unpair()
    }

    func unpair() {
        stop()
        pairingRevision &+= 1
        store.clearPairing()
        pairing = nil
        lastNexBlueImport = nil
        syncState = .idle
        planStatus = nil
        planRecord = nil
        telemetry = HomeChargerTelemetry()
        table = [:]
        link = .notConfigured
    }

    /// Everything Home Charging holds, the token included. History rows already written stay.
    func eraseEverything() {
        stop()
        pairingRevision &+= 1
        store.eraseAll()
        tibberHome = nil
        tibberProblem = nil
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
            // Always offered with the planner on: when the component is missing the editor says how to install it.
            canEditPlan: pairing.source.supportsPlans && preferences.features.contains(.smartChargingPlanner)
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

    private func sendDirect(_ kind: HomeChargerCommandKind, pairing: HomeChargingPairing, now: Date) async {
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
        // A vehicle-specific plan runs only for the vehicle the charger was explicitly paired with.
        guard let pairing, pairing.isPaired(toVehicle: vin), pairing.chargerID == request.chargerID else {
            throw HomeChargingPlanError.notPaired
        }
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
    func syncSessions(backfill: DateInterval? = nil) async {
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
            tibberPrices: tibberPriceSource())
        do {
            let summary = try await HomeSessionSync.run(environment)
            guard pairingRevision == revision else { return }
            tibberProblem = summary.tibberProblem
            let importedAt = dependencies.now()
            if backfill == nil { lastSyncAt = importedAt }
            if pairing.source == .nexBlue, !summary.skippedByPrivacy,
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
