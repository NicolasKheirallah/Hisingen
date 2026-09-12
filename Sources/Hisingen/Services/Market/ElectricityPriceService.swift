import Foundation
import OSLog

/// Fetches Swedish spot prices from the free elprisetjustnu.se API — one static JSON
/// file per zone and day, `https://www.elprisetjustnu.se/api/v1/prices/{YYYY}/{MM-DD}_{ZONE}.json`.
///
/// Fetch cadence: tomorrow's prices are published the day before, so a single pass per
/// day any time after 14:15 Stockholm time retrieves that day's file plus the next one,
/// and the app then never needs to ask again until the following publication. The cache
/// persists in the SQLite database (`ElectricityPriceStore`), so a relaunch mid-day
/// serves from disk without touching the network.
actor ElectricityPriceService {
    static let shared = ElectricityPriceService()

    struct CachedPrices: Codable, Equatable, Sendable {
        var zone: ElspotZone
        var points: [ElectricityPricePoint]
        var fetchedAt: Date
    }

    enum PriceFetchError: Error, Equatable {
        /// Tomorrow's file appears at publication time; before that a 404 is expected, not a failure.
        case notPublished
        case badResponse
        case httpStatus(Int)
    }

    static let publicationHour = 14
    static let publicationMinute = 15

    private let session: URLSession
    private let store: ElectricityPriceStore
    private let logger = AppLog.logger("elpriser")

    private var cache: [ElspotZone: CachedPrices] = [:]
    private var cacheLoaded = false
    private var dailyTask: Task<Void, Never>?
    private var inFlight: [ElspotZone: Task<[ElectricityPricePoint], Error>] = [:]
    /// Publication can lag its nominal time; a fresh-less fetch is retried on this
    /// cadence for the rest of the evening instead of waiting a full day. The happy
    /// path still touches the network exactly once per day.
    private static let retryDelaySeconds: TimeInterval = 5_400
    private static let maxPublicationRetries = 4
    private var retryCount: [ElspotZone: Int] = [:]

    init(database: VehicleDatabase = .shared) {
        self.store = database.electricityPrices
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Date math (pure, unit-tested)

    /// Spot prices are set the day before; 14:15 Stockholm time is the safe retrieval moment.
    static let stockholmCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        return calendar
    }()

    /// The next daily publication moment at or after the given date, in Stockholm time.
    static func nextFetchDate(after date: Date, calendar: Calendar = ElectricityPriceService.stockholmCalendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = publicationHour
        components.minute = publicationMinute
        let todaysPublication = calendar.date(from: components) ?? date
        guard date >= todaysPublication else { return todaysPublication }
        return calendar.date(byAdding: .day, value: 1, to: todaysPublication) ?? date.addingTimeInterval(86_400)
    }

    static func dayPath(for date: Date, calendar: Calendar = ElectricityPriceService.stockholmCalendar)
        -> (year: String, month: String, day: String) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (
            String(format: "%04d", components.year ?? 0),
            String(format: "%02d", components.month ?? 0),
            String(format: "%02d", components.day ?? 0)
        )
    }

    static func priceURL(zone: ElspotZone, date: Date, calendar: Calendar = ElectricityPriceService.stockholmCalendar) -> URL {
        let day = dayPath(for: date, calendar: calendar)
        return URL(string: "https://www.elprisetjustnu.se/api/v1/prices/\(day.year)/\(day.month)-\(day.day)_\(zone.rawValue).json")!
    }

    /// The instant cached data must reach to count as complete: the end of today before
    /// publication, the end of tomorrow once tomorrow's prices are out.
    static func requiredCoverageEnd(after date: Date, calendar: Calendar = ElectricityPriceService.stockholmCalendar) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return date.addingTimeInterval(2 * 86_400)
        }
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = publicationHour
        components.minute = publicationMinute
        let publication = calendar.date(from: components) ?? date
        return date >= publication ? startOfDayAfter : startOfTomorrow
    }

    static func isCacheFresh(_ entry: CachedPrices, after date: Date, calendar: Calendar = ElectricityPriceService.stockholmCalendar) -> Bool {
        guard let horizon = entry.points.map(\.endDate).max() else { return false }
        return horizon >= requiredCoverageEnd(after: date, calendar: calendar)
    }

    // MARK: - Public surface

    /// Cached prices, refreshed only when stale. Safe to call on every render pass of a
    /// card: the common path is one actor hop returning the in-memory series.
    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint] {
        loadCacheIfNeeded()
        if let entry = cache[zone], Self.isCacheFresh(entry, after: Date()) {
            // Keep the once-a-day timer armed while the app is open, without fetching.
            if dailyTask == nil {
                armRefresh(zone: zone, tomorrowComplete: true)
            }
            return entry.points
        }
        return await refresh(zone: zone)
    }

    /// Force a fetch of today's and tomorrow's files. Concurrent callers for the same
    /// zone share one in-flight request.
    @discardableResult
    func refresh(zone: ElspotZone) async -> [ElectricityPricePoint] {
        loadCacheIfNeeded()
        if let running = inFlight[zone] {
            return (try? await running.value) ?? cachedPoints(for: zone)
        }
        let task = Task<[ElectricityPricePoint], Error> { [self] in
            try await fetchAndStore(zone: zone)
        }
        inFlight[zone] = task
        defer { inFlight[zone] = nil }
        do {
            let points = try await task.value
            armRefresh(zone: zone, tomorrowComplete: isTomorrowCovered(zone: zone))
            return points
        } catch {
            logger.error("Spot price refresh failed for \(zone.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            armRefresh(zone: zone, tomorrowComplete: false)
            return cachedPoints(for: zone)
        }
    }

    func cachedPoints(for zone: ElspotZone) -> [ElectricityPricePoint] {
        loadCacheIfNeeded()
        return cache[zone]?.points ?? []
    }

    /// When the zone's series was last fetched, for freshness display; informational only.
    func fetchedAt(for zone: ElspotZone) -> Date? {
        loadCacheIfNeeded()
        return cache[zone]?.fetchedAt
    }

    /// Fetches one specific day's file and merges it into the persisted series. The daily
    /// cadence only covers today and tomorrow; this is how historical charging sessions get
    /// priced after the fact. Failures return the existing series untouched.
    func historicalPrices(zone: ElspotZone, day: Date) async -> [ElectricityPricePoint] {
        loadCacheIfNeeded()
        let existing = cache[zone]?.points ?? []
        let dayStart = Self.stockholmCalendar.startOfDay(for: day)
        if let last = existing.map(\.endDate).max(), last >= dayStart.addingTimeInterval(86_400) {
            return existing // already covered
        }
        guard let fetched = try? await fetchPoints(from: Self.priceURL(zone: zone, date: day)),
              !fetched.isEmpty else { return existing }
        var seen = Set(existing.map(\.startDate))
        let merged = (existing + fetched.filter { seen.insert($0.startDate).inserted != nil })
            .sorted { $0.startDate < $1.startDate }
        cache[zone] = CachedPrices(zone: zone, points: merged, fetchedAt: Date())
        store.save(zone: zone, points: merged, fetchedAt: Date())
        return merged
    }

    // MARK: - Fetching

    private func fetchAndStore(zone: ElspotZone) async throws -> [ElectricityPricePoint] {
        let now = Date()
        var points = try await fetchPoints(from: Self.priceURL(zone: zone, date: now))
        do {
            points += try await fetchPoints(from: Self.priceURL(zone: zone, date: now.addingTimeInterval(86_400)))
        } catch PriceFetchError.notPublished {
            logger.notice("Tomorrow's prices not published yet for \(zone.rawValue, privacy: .public)")
        }
        var seen = Set<Date>()
        let merged = points
            .filter { seen.insert($0.startDate).inserted }
            .sorted { $0.startDate < $1.startDate }
        guard !merged.isEmpty else { throw PriceFetchError.badResponse }
        let entry = CachedPrices(zone: zone, points: merged, fetchedAt: now)
        cache[zone] = entry
        store.save(zone: zone, points: merged, fetchedAt: now)
        return entry.points
    }

    private func fetchPoints(from url: URL) async throws -> [ElectricityPricePoint] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw PriceFetchError.badResponse }
        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ElectricityPricePoint].self, from: data)
        case 404, 410:
            throw PriceFetchError.notPublished
        case let code:
            throw PriceFetchError.httpStatus(code)
        }
    }

    // MARK: - Daily schedule

    private func isTomorrowCovered(zone: ElspotZone) -> Bool {
        guard let entry = cache[zone] else { return false }
        return Self.isCacheFresh(entry, after: Date())
    }

    /// Tomorrow complete: sleep until the next publication. Otherwise retry this
    /// evening a bounded number of times — the file can land a little late.
    private func armRefresh(zone: ElspotZone, tomorrowComplete: Bool) {
        let delay: TimeInterval
        if tomorrowComplete {
            retryCount[zone] = nil
            delay = Self.nextFetchDate(after: Date()).timeIntervalSinceNow
        } else {
            let attempts = retryCount[zone] ?? 0
            if attempts < Self.maxPublicationRetries {
                retryCount[zone] = attempts + 1
                delay = Self.retryDelaySeconds
            } else {
                retryCount[zone] = nil
                delay = Self.nextFetchDate(after: Date()).timeIntervalSinceNow
            }
        }
        guard delay > 0 else { return }
        dailyTask?.cancel()
        dailyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((delay + 1) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refresh(zone: zone)
        }
    }

    // MARK: - Persistence

    /// Loads the persisted series once per process. Freshness is derived from interval
    /// coverage, so the stored `fetched_at` is informational only.
    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        for zone in ElspotZone.allCases {
            let points = store.prices(zone: zone)
            guard !points.isEmpty else { continue }
            cache[zone] = CachedPrices(
                zone: zone,
                points: points,
                fetchedAt: store.fetchedAt(zone: zone) ?? points[0].startDate
            )
        }
    }
}
