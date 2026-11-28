import Foundation
import OSLog

/// Where a price series came from. The two are not the same quantity: a Tibber price is the
/// all-in price per kWh (energy, taxes, Tibber's markup), a market price is the bare spot price
/// that the rate policy still has to add markup and VAT to.
enum PlannerPriceOrigin: Equatable, Sendable {
    case tibber
    case elpriser
}

/// A price series with the origin that decides how it is read.
struct PlannerPrices: Equatable, Sendable {
    var points: [ElectricityPricePoint]
    var origin: PlannerPriceOrigin
    var fetchedAt: Date?
    /// A Tibber token is saved, whether or not Tibber answered this time. With `origin == .elpriser`
    /// it means the market series is standing in for a provider that failed.
    var tibberConnected: Bool
    /// Why Tibber is not the source, in words for the reader, when it is connected and not.
    var tibberProblem: String?
    /// The reader's network fee is inside these prices.
    var includesNetworkFee: Bool = false
    /// Active grid tariff applied to market prices (kept separate from retail markup/VAT).
    var gridTariff: GridTariff = .none
    /// Underlying untransformed market points when a grid tariff was added to `points`.
    var rawMarketPoints: [ElectricityPricePoint]? = nil
    /// ISO currency code advertised by the price source (e.g. "SEK", "NOK", "EUR").
    var currency: String? = nil
    /// IANA time zone identifier of the price source (e.g. "Europe/Stockholm", "Europe/Oslo").
    var timeZoneIdentifier: String? = nil

    var isAllIn: Bool { origin == .tibber }

    var calendar: Calendar {
        var result = ElectricityPriceService.stockholmCalendar
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            result.timeZone = timeZone
        }
        return result
    }

    func currencySymbol(fallback: String) -> String {
        switch currency?.uppercased() {
        case "SEK", "NOK", "DKK": return "kr"
        case "EUR": return "€"
        case "GBP": return "£"
        case let other? where !other.isEmpty: return other
        default: return fallback
        }
    }

    /// Tibber's level for the slot that covers `date`. `nil` for market prices and for a slot Tibber did not rate.
    func level(at date: Date) -> TibberPriceLevel? {
        guard origin == .tibber else { return nil }
        return points.first { $0.startDate <= date && date < $0.endDate }?.level
    }

    /// The level most of a window sits at: the average of its slots' positions on the five-step
    /// scale, rounded. `nil` unless every slot in the window carries a level.
    func level(from start: Date, to end: Date) -> TibberPriceLevel? {
        guard origin == .tibber, end > start else { return nil }
        let slots = points.filter { $0.startDate < end && $0.endDate > start }
        let ranks = slots.compactMap { $0.level?.rank }
        guard !slots.isEmpty, ranks.count == slots.count else { return nil }
        return TibberPriceLevel(rank: Int((Double(ranks.reduce(0, +)) / Double(ranks.count)).rounded()))
    }

    var isFallback: Bool { tibberConnected && origin == .elpriser }

    /// What a kWh costs the user right now. An all-in price is used as it is, because the rate
    /// policy's markup and VAT are already inside it; a market price gets the policy applied and
    /// any configured grid transfer fee added once without double-applying VAT.
    func currentRate(policy: ElectricityRatePolicy, at date: Date) -> Double? {
        let basePoints = isAllIn ? points : (rawMarketPoints ?? points)
        let settled = policy.contract.settle(basePoints, calendar: calendar)
        guard let slot = settled.first(where: { $0.startDate <= date && date < $0.endDate }) else {
            return nil
        }
        if isAllIn { return slot.sekPerKwh }
        return policy.retailPrice(spotSekPerKwh: slot.sekPerKwh)
            + gridTariff.averageFeePerKwh(from: slot.startDate, to: slot.endDate)
    }
}

/// The price series the charging planner and the cost estimates read: the connected provider
/// (Tibber) first, Elpriser (elprisetjustnu.se) when no provider is connected or it cannot answer.
///
/// Tibber is rate-limited and its prices change once a day, so one fetch covers today and
/// tomorrow and is reused until the cache stops reaching the day it should. A failed or incomplete
/// fetch is retried at most every `retryInterval`, and the series that served the last good answer
/// keeps serving while it still reaches an hour ahead.
actor PlannerPriceProvider: ChargingPlannerPriceSource {
    static let shared = PlannerPriceProvider()

    typealias TibberFetch = @Sendable (Date, Date) async throws -> [HomePricePoint]

    /// A connected Tibber home. `homeID` tells the provider when the reader switched homes or
    /// accounts, so a cache from the old one is never read as the new one.
    struct TibberSource: Sendable {
        var homeID: String
        /// The reader's network fee, which Tibber's price leaves out, in kronor per kWh.
        var networkFeeSekPerKwh: Double = 0
        /// The grid tariff, which wins over `networkFeeSekPerKwh` when set: the fee then follows the clock.
        var gridTariff: GridTariff?
        var currency: String? = nil
        var timeZoneIdentifier: String? = nil
        var fetch: TibberFetch

        var tariff: GridTariff { gridTariff ?? .flat(orePerKwh: max(0, networkFeeSekPerKwh) * 100) }
    }

    static let retryInterval: TimeInterval = 15 * 60
    /// A series that does not reach this far ahead cannot hold even the shortest (one hour) plan.
    static let minimumUsableHorizon: TimeInterval = 3_600

    private let spot: any ChargingPlannerPriceSource
    private let now: @Sendable () -> Date
    private let logger = AppLog.logger("elpriser")

    private let tibberSource = OSAllocatedUnfairLock<@Sendable () async -> TibberSource?>(initialState: { nil })
    private let gridTariffSource = OSAllocatedUnfairLock<@Sendable () async -> GridTariff?>(initialState: { nil })
    private var cachedHomeID: String?
    private var tibberCache: [ElectricityPricePoint] = []
    private var tibberFetchedAt: Date?
    private var lastAttempt: Date?
    private var tibberProblem: String?
    private var refreshTask: Task<Void, Never>?
    private var lastResolved: PlannerPrices?

    init(spot: any ChargingPlannerPriceSource = ElectricityPriceService.shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.spot = spot
        self.now = now
    }

    /// The composition root says where the connected provider's prices come from. Evaluated on
    /// every resolve, so connecting or disconnecting Tibber takes effect without a relaunch.
    /// Synchronous, so it is in place before the first planner pass can ask.
    nonisolated func setTibberSource(_ source: @escaping @Sendable () async -> TibberSource?) {
        tibberSource.withLock { $0 = source }
    }

    /// Provides the user's configured grid tariff when the fallback market series is active so
    /// non-Tibber spot planning and alerts account for time-of-use distribution fees.
    nonisolated func setGridTariffSource(_ source: @escaping @Sendable () async -> GridTariff?) {
        gridTariffSource.withLock { $0 = source }
    }

    // MARK: - Public surface

    func resolve(zone: ElspotZone) async -> PlannerPrices {
        let current = now()
        let provide = tibberSource.withLock { $0 }
        guard let source = await provide() else {
            forgetTibber()
            return remember(await marketSeries(zone: zone, tibberConnected: false))
        }
        if cachedHomeID != source.homeID {
            forgetTibber()
            cachedHomeID = source.homeID
        }
        await refreshTibberIfNeeded(source, at: current)
        let usable = Self.reachesAhead(tibberCache, from: current)
        if usable {
            let tariff = source.tariff
            let points = tariff.hasFee
                ? tibberCache.map {
                    ElectricityPricePoint(startDate: $0.startDate, endDate: $0.endDate,
                                          sekPerKwh: $0.sekPerKwh + tariff.averageFeePerKwh(from: $0.startDate, to: $0.endDate),
                                          level: $0.level)
                }
                : tibberCache
            return remember(PlannerPrices(points: points, origin: .tibber, fetchedAt: tibberFetchedAt,
                                          tibberConnected: true, tibberProblem: nil,
                                          includesNetworkFee: tariff.hasFee,
                                          gridTariff: tariff,
                                          rawMarketPoints: nil,
                                          currency: source.currency,
                                          timeZoneIdentifier: source.timeZoneIdentifier))
        }
        let reason = tibberProblem ?? L10n.text("Tibber has no prices for the coming hours yet.")
        return remember(await marketSeries(zone: zone, tibberConnected: true, problem: reason))
    }

    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint] {
        await resolve(zone: zone).points
    }

    func fetchedAt(for zone: ElspotZone) async -> Date? {
        if let lastResolved { return lastResolved.fetchedAt }
        return await spot.fetchedAt(for: zone)
    }

    /// The bare market series, whatever the planner is reading. Historic cost backfill stores raw
    /// spot costs and applies the rate policy on display, so an all-in price must never reach it.
    func marketPrices(for zone: ElspotZone) async -> [ElectricityPricePoint] {
        await spot.prices(for: zone)
    }

    // MARK: - Tibber

    static func reachesAhead(_ points: [ElectricityPricePoint], from date: Date) -> Bool {
        guard let horizon = ChargingPlanner.dataHorizonEnd(prices: points) else { return false }
        return horizon >= date.addingTimeInterval(minimumUsableHorizon)
    }

    private func needsRefresh(at date: Date) -> Bool {
        let complete = ElectricityPriceService.isCacheFresh(
            ElectricityPriceService.CachedPrices(zone: .se3, points: tibberCache, fetchedAt: tibberFetchedAt ?? date),
            after: date)
        guard !complete else { return false }
        guard let lastAttempt else { return true }
        return date.timeIntervalSince(lastAttempt) >= Self.retryInterval
    }

    private func refreshTibberIfNeeded(_ source: TibberSource, at date: Date) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard needsRefresh(at: date) else { return }
        let task = Task { [self] in await fetchTibber(source, at: date) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func fetchTibber(_ source: TibberSource, at date: Date) async {
        lastAttempt = date
        let calendar = ElectricityPriceService.stockholmCalendar
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? date.addingTimeInterval(2 * 86_400)
        do {
            let fetched = try await source.fetch(start, end)
            let points = fetched
                .filter { $0.pricePerKwh.isFinite && $0.end > $0.start }
                .map { ElectricityPricePoint(startDate: $0.start, endDate: $0.end, sekPerKwh: $0.pricePerKwh, level: $0.level) }
                .sorted { $0.startDate < $1.startDate }
            guard !points.isEmpty else {
                logger.notice("Tibber returned no prices; the market series stands in")
                tibberProblem = L10n.text("Tibber returned no prices.")
                return
            }
            tibberCache = points
            tibberFetchedAt = date
            tibberProblem = nil
        } catch is CancellationError {
            lastAttempt = nil
        } catch {
            logger.error("Tibber price fetch failed: \(String(describing: error), privacy: .public)")
            tibberProblem = (error as? DirectChargerError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func forgetTibber() {
        cachedHomeID = nil
        tibberCache = []
        tibberFetchedAt = nil
        lastAttempt = nil
        tibberProblem = nil
    }

    // MARK: - Market fallback

    private func marketSeries(zone: ElspotZone, tibberConnected: Bool, problem: String? = nil) async -> PlannerPrices {
        let raw = await spot.prices(for: zone)
        let tariff = (await gridTariffSource.withLock { $0 }()) ?? .none
        let points: [ElectricityPricePoint] = tariff.hasFee
            ? raw.map {
                ElectricityPricePoint(
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    sekPerKwh: $0.sekPerKwh + tariff.averageFeePerKwh(from: $0.startDate, to: $0.endDate),
                    level: $0.level
                )
            }
            : raw
        return PlannerPrices(
            points: points,
            origin: .elpriser,
            fetchedAt: await spot.fetchedAt(for: zone),
            tibberConnected: tibberConnected,
            tibberProblem: problem,
            includesNetworkFee: tariff.hasFee,
            gridTariff: tariff,
            rawMarketPoints: tariff.hasFee ? raw : nil,
            currency: "SEK",
            timeZoneIdentifier: ElectricityPriceService.stockholmCalendar.timeZone.identifier
        )
    }

    private func remember(_ prices: PlannerPrices) -> PlannerPrices {
        lastResolved = prices
        return prices
    }
}
