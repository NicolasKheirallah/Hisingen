import Foundation

/// The house meter: live whole-house power from a Perific monitor, today's import, and the hourly
/// import history that the car-share rows read when Tibber is not connected.
///
/// It is read only and optional. With no meter chosen the model is inert, and when Perific cannot be
/// reached the rest of the app keeps working. It never writes to Perific and never touches the
/// load balancer: Perific stays in charge of limiting the charger.
@MainActor
final class HouseMeterModel: ObservableObject {
    enum Link: Equatable, Sendable {
        case notConfigured
        case connecting
        case live
        case reconnecting
        case unreachable(String)
        case unauthorized
        /// The account answered but no longer lists the chosen meter.
        case meterMissing
    }

    @Published private(set) var meter: HouseMeter?
    @Published private(set) var link: Link = .notConfigured
    @Published private(set) var reading: HouseMeterReading?
    @Published private(set) var today: HouseMeterSpan?
    @Published private(set) var lastContact: Date?
    /// Ticks with each read so ages ("last read 4 min ago") keep moving.
    @Published private(set) var clock = Date()

    private let dependencies: HomeChargingModel.Dependencies
    private let store: HouseMeterStore
    private let logger = AppLog.logger("house-meter")
    private var client: PerificClient?
    private var loopTask: Task<Void, Never>?
    private var generation = 0
    private var lastTodayRead: Date?
    private var hourlyCache: (meterID: String, from: Date, fetchedAt: Date, hours: [TibberConsumptionHour])?
    private var eraseObserver: (any NSObjectProtocol)?

    /// The meter reports about every ten seconds. Three reads a minute would add nothing the
    /// reader can see, and the cloud's rate limit is not published.
    static let pollInterval: TimeInterval = 30
    /// Today's import moves slowly and costs a history request, so it is read this often.
    static let todayInterval: TimeInterval = 300
    static let hourlyCacheLifetime: TimeInterval = 30 * 60

    init(preferences: PreferencesStore, dependencies: HomeChargingModel.Dependencies) {
        self.dependencies = dependencies
        self.store = HouseMeterStore(defaults: preferences.d, keychain: preferences.keychain)
        self.meter = store.meter
        if meter != nil { link = .connecting }
        eraseObserver = NotificationCenter.default.addObserver(
            forName: .homeChargingDataErased, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.storeWasErased() }
        }
    }

    var isConnected: Bool { meter != nil }
    var hasSavedCredentials: Bool { store.hasCredentials }
    func savedUsername() -> String? { ((try? store.credentials()) ?? nil)?.username }

    /// What the card and the settings readout show right now.
    func presentation(carKw: Double?) -> HouseMeterPresentation {
        HouseMeterPresentation.make(reading: reading, span: today, carKw: carKw, now: max(clock, dependencies.now()))
    }

    // MARK: Setup

    /// Signs in and lists the meters on the account. The login is saved only once it works.
    func connect(credentials: DirectChargerCredentials) async throws -> [HouseMeter] {
        guard credentials.isComplete else { throw DirectChargerError.unauthorized }
        let candidate = PerificClient(credentials: credentials, transport: dependencies.transport, now: dependencies.now)
        let meters = try await candidate.meters()
        try Task.checkCancellation()
        try store.saveCredentials(credentials)
        return meters
    }

    func select(_ meter: HouseMeter) {
        stop()
        store.meter = meter
        self.meter = meter
        reading = nil
        today = nil
        lastContact = nil
        lastTodayRead = nil
        hourlyCache = nil
        client = nil
        link = .connecting
        start()
    }

    /// A new login for the chosen meter, for an account whose password changed.
    func replaceCredentials(_ credentials: DirectChargerCredentials) async throws {
        guard let meter, credentials.isComplete else { return }
        let candidate = PerificClient(credentials: credentials, transport: dependencies.transport, now: dependencies.now)
        let meters = try await candidate.meters()
        try Task.checkCancellation()
        guard meters.contains(where: { $0.id == meter.id }) else { throw DirectChargerError.forbidden }
        try store.saveCredentials(credentials)
        client = nil
        stop()
        link = .connecting
        start()
    }

    func disconnect() {
        stop()
        store.eraseAll()
        meter = nil
        reading = nil
        today = nil
        lastContact = nil
        lastTodayRead = nil
        hourlyCache = nil
        client = nil
        link = .notConfigured
    }

    private func storeWasErased() {
        guard store.meter == nil else { return }
        stop()
        meter = nil
        reading = nil
        today = nil
        lastContact = nil
        hourlyCache = nil
        client = nil
        link = .notConfigured
    }

    // MARK: Lifecycle

    func start() {
        guard meter != nil, loopTask == nil else { return }
        generation &+= 1
        let current = generation
        loopTask = Task { [weak self] in await self?.run(generation: current) }
    }

    func stop() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        if meter != nil, link != .unauthorized { link = .reconnecting }
    }

    /// Restarts the loop so the next read happens now.
    func refreshNow() {
        guard meter != nil else { return }
        stop()
        start()
    }

    // MARK: Loop

    private func run(generation current: Int) async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled, current == generation {
            guard let meter, let client = client ?? makeClient() else {
                link = meter == nil ? .notConfigured : .unauthorized
                return
            }
            self.client = client
            do {
                if link != .live { link = .connecting }
                try await read(client: client, meter: meter)
                backoff = 2
                while !Task.isCancelled, current == generation {
                    try? await dependencies.wait(Self.pollInterval)
                    guard !Task.isCancelled, current == generation else { return }
                    try await read(client: client, meter: meter)
                }
                return
            } catch DirectChargerError.unauthorized {
                link = .unauthorized
                return
            } catch is CancellationError {
                return
            } catch let error as DirectChargerError {
                link = lastContact == nil ? .unreachable(error.localizedDescription) : .reconnecting
                logger.notice("Perific unavailable: \(String(describing: error), privacy: .private)")
                if case .rateLimited(let retryAfter) = error {
                    let delay = retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.pollInterval
                    backoff = max(backoff, min(delay, 86_400))
                }
            } catch {
                link = .reconnecting
            }
            guard !Task.isCancelled, current == generation else { return }
            try? await dependencies.wait(backoff)
            backoff = min(backoff * 2, 300)
        }
    }

    private func read(client: PerificClient, meter: HouseMeter) async throws {
        let now = dependencies.now()
        let fresh = try await client.latest(meterID: meter.id)
        try Task.checkCancellation()
        clock = now
        guard let fresh else {
            link = .meterMissing
            return
        }
        reading = fresh
        lastContact = now
        link = .live
        if lastTodayRead == nil || now.timeIntervalSince(lastTodayRead ?? now) >= Self.todayInterval {
            lastTodayRead = now
            await refreshToday(client: client, meter: meter, now: now)
        }
    }

    /// Today's import, from the first register reading after local midnight to the newest. A failure
    /// here leaves yesterday's figure for the next read and does not fail the live reading.
    private func refreshToday(client: PerificClient, meter: HouseMeter, now: Date) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = meter.timeZone
        let midnight = calendar.startOfDay(for: now)
        guard let points = try? await client.registers(meterID: meter.id, timeZone: meter.timeZone,
                                                       from: midnight.addingTimeInterval(-120), to: now),
              !Task.isCancelled else { return }
        today = HouseMeterHistory.span(points)
    }

    private func makeClient() -> PerificClient? {
        guard let credentials = (try? store.credentials()) ?? nil, credentials.isComplete else { return nil }
        return PerificClient(credentials: credentials, transport: dependencies.transport, now: dependencies.now)
    }

    // MARK: History

    /// Whole-house hourly import for `[from, to]`, or `nil` when no meter is connected or Perific does
    /// not answer. The history moves a minute at a time, so one answer is reused for half an hour.
    func hourlyImport(from: Date, to: Date) async -> [TibberConsumptionHour]? {
        guard let meter, let client = client ?? makeClient() else { return nil }
        let now = dependencies.now()
        if let cache = hourlyCache, cache.meterID == meter.id, cache.from <= from,
           now.timeIntervalSince(cache.fetchedAt) < Self.hourlyCacheLifetime {
            return cache.hours.filter { $0.end > from && $0.start < to }
        }
        guard let points = try? await client.hourlyRegisters(meterID: meter.id, timeZone: meter.timeZone,
                                                             from: from, to: min(to, now)),
              self.meter?.id == meter.id else { return nil }
        let hours = HouseMeterHistory.hourlyImport(points)
        hourlyCache = (meter.id, from, now, hours)
        return hours.filter { $0.end > from && $0.start < to }
    }
}
