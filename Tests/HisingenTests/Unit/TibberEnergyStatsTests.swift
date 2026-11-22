import Foundation
import Testing
@testable import Hisingen

private let day0 = Date(timeIntervalSince1970: 1_794_182_400)   // a UTC midnight
private let utcCalendar = Calendar(identifier: .gregorian)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// A Tibber API that serves day- and month-total meter readings and the published prices in pages
/// of `pageLimit`, newest page first, with a cursor on every edge, the way the real one pages with
/// `last` and `before`.
private final class MockTibberEnergy: @unchecked Sendable {
    let transport: MockHomeAssistantTransport
    private let lock = NSLock()
    private let pageLimit: Int
    private var consumptionDaily: [(Date, Double?)] = []
    private var consumptionMonthly: [(Date, Double?)] = []
    private var productionDaily: [(Date, Double?)] = []
    private var productionMonthly: [(Date, Double?)] = []
    /// Quarter-hour slots with their level: `(start, total, level)`.
    private var today: [(Date, Double, String?)] = []
    private var tomorrow: [(Date, Double, String?)] = []
    private var failure: String?
    private(set) var queries: [String] = []
    private(set) var beforeCursors: [String?] = []

    init(pageLimit: Int = 2) {
        self.pageLimit = pageLimit
        transport = MockHomeAssistantTransport()
        transport.route({ $0.httpMethod == "POST" && $0.url?.path == "/v1-beta/gql" }) { [weak self] request in
            self?.answer(request) ?? .json("{}", status: 503)
        }
    }

    func setConsumption(_ rows: [(Date, Double?)], resolution: TibberClient.TibberEnergyResolution) {
        lock.withLock {
            if resolution == .daily { consumptionDaily = rows } else { consumptionMonthly = rows }
        }
    }

    func setProduction(_ rows: [(Date, Double?)], resolution: TibberClient.TibberEnergyResolution) {
        lock.withLock {
            if resolution == .daily { productionDaily = rows } else { productionMonthly = rows }
        }
    }

    /// Prices Tibber has published: today in full and tomorrow when it is out, each slot with its
    /// level.
    func setPublishedPrices(today todaySlots: [(Date, Double, String?)], tomorrow tomorrowSlots: [(Date, Double, String?)]) {
        lock.withLock { self.today = todaySlots; self.tomorrow = tomorrowSlots }
    }

    func setFailure(_ errors: String?) { lock.withLock { failure = errors } }
    var requestCount: Int { lock.withLock { queries.count } }

    private func answer(_ request: URLRequest) -> MockHomeAssistantTransport.Reply {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        lock.withLock {
            queries.append(query)
            beforeCursors.append(variables["before"] as? String)
        }
        if let failure = lock.withLock({ failure }) {
            return .json(#"{"errors":[\#(failure)],"data":null}"#)
        }
        if query.contains("priceInfo(resolution") {
            let slots = lock.withLock { (today, tomorrow) }
            return .json(#"{"data":{"viewer":{"home":{"currentSubscription":{"priceInfo":{"today":[\#(Self.priceRows(slots.0))],"tomorrow":[\#(Self.priceRows(slots.1))]}}}}}}"#)
        }
        if query.contains("consumption(resolution: DAILY") {
            return .json(Self.page(lock.withLock { consumptionDaily }, variables: variables, pageLimit: pageLimit,
                                   field: "consumption", costed: true, wrapper: "consumption"))
        }
        if query.contains("consumption(resolution: MONTHLY") {
            return .json(Self.page(lock.withLock { consumptionMonthly }, variables: variables, pageLimit: pageLimit,
                                   field: "consumption", costed: true, wrapper: "consumption"))
        }
        if query.contains("production(resolution: DAILY") {
            return .json(Self.page(lock.withLock { productionDaily }, variables: variables, pageLimit: pageLimit,
                                   field: "production", costed: false, wrapper: "production"))
        }
        if query.contains("production(resolution: MONTHLY") {
            return .json(Self.page(lock.withLock { productionMonthly }, variables: variables, pageLimit: pageLimit,
                                   field: "production", costed: false, wrapper: "production"))
        }
        return .json("{}", status: 400)
    }

    private static func priceRows(_ slots: [(Date, Double, String?)]) -> String {
        slots.map { slot -> String in
            let level = slot.2.map { #","level":"\#($0)""# } ?? ""
            return #"{"total":\#(slot.1),"startsAt":"\#(iso(slot.0))"\#(level)}"#
        }.joined(separator: ",")
    }

    /// The slice of `rows` one page holds: the `pageLimit` rows before the one `before` names.
    /// The cursor is the row's own position, the way the hourly mock and the real cursors both work.
    private static func page(_ rows: [(Date, Double?)], variables: [String: Any], pageLimit: Int,
                             field: String, costed: Bool, wrapper: String) -> String {
        var end = rows.count
        if let before = variables["before"] as? String, let index = Int(before.dropFirst(4)) { end = max(0, min(index, rows.count)) }
        let slice = rows[max(0, end - pageLimit)..<end]
        let edges = slice.enumerated().map { position, row -> String in
            let cursor = end - slice.count + position
            let value = row.1.map { String($0) } ?? "null"
            let cost = costed ? #","cost":\#(row.1.map { String($0 * 2.0) } ?? "null"),"currency":"SEK""# : ""
            return #"{"cursor":"cur-\#(cursor)","node":{"from":"\#(iso(row.0))","to":"\#(iso(row.0.addingTimeInterval(86_400)))","\#(field)":\#(value)\#(cost)}}"#
        }
        return #"{"data":{"viewer":{"home":{"\#(wrapper)":{"edges":[\#(edges.joined(separator: ","))]}}}}}"#
    }
}

@Suite("Tibber day and month energy")
struct TibberEnergyResolutionTests {
    private func days(_ count: Int, startingAt start: Date = day0) -> [(Date, Double?)] {
        (0..<count).map { (start.addingTimeInterval(Double($0) * 86_400), Double($0) + 1) }
    }

    @Test("Daily consumption is read in pages, carries cost and currency, and a day without a reading is left out")
    func dailyConsumption() async throws {
        // A page of three covers the five days in two requests, the most the daily read allows.
        let tibber = MockTibberEnergy(pageLimit: 3)
        var rows = days(5)
        rows[2] = (rows[2].0, nil)
        tibber.setConsumption(rows, resolution: .daily)
        let periods = try await TibberClient(token: "t", transport: tibber.transport).consumption(
            homeID: "home-1", resolution: .daily, from: day0, to: day0.addingTimeInterval(6 * 86_400))
        #expect(periods.count == 4)
        #expect(periods.map(\.start) == [day0, day0.addingTimeInterval(86_400),
                                         day0.addingTimeInterval(3 * 86_400), day0.addingTimeInterval(4 * 86_400)])
        #expect(periods.allSatisfy { $0.end.timeIntervalSince($0.start) == 86_400 })
        // Tibber's billed cost and its currency ride along with each day.
        #expect(periods.first?.kwh == 1.0 && periods.first?.cost == 2.0 && periods.first?.currency == "SEK")
        // The second page starts before the dropped day, at the newest day the feed did answer.
        #expect(tibber.beforeCursors == [nil, "cur-3"])
    }

    @Test("Monthly totals reach the API with the MONTHLY resolution and page the same way")
    func monthlyResolution() async throws {
        let tibber = MockTibberEnergy(pageLimit: 2)
        let start = day0.addingTimeInterval(30 * 86_400)
        tibber.setConsumption((0..<4).map { (start.addingTimeInterval(Double($0) * 30 * 86_400), Double($0) + 1) },
                              resolution: .monthly)
        let periods = try await TibberClient(token: "t", transport: tibber.transport).consumption(
            homeID: "home-1", resolution: .monthly, from: start, to: start.addingTimeInterval(5 * 30 * 86_400))
        #expect(periods.count == 4)
        #expect(tibber.queries.allSatisfy { $0.contains("consumption(resolution: MONTHLY") })
        #expect(tibber.beforeCursors == [nil, "cur-2"])
    }

    @Test("Daily production pages like consumption, and a home without a production metering point answers with none")
    func dailyProduction() async throws {
        let tibber = MockTibberEnergy(pageLimit: 3)
        tibber.setProduction(days(4), resolution: .daily)
        let client = TibberClient(token: "t", transport: tibber.transport)
        let periods = try await client.production(
            homeID: "home-1", resolution: .daily, from: day0, to: day0.addingTimeInterval(5 * 86_400))
        #expect(periods.count == 4)
        #expect(periods.allSatisfy { $0.kwh > 0 })
        #expect(tibber.queries.allSatisfy { $0.contains("production(resolution: DAILY") })
        tibber.setProduction([], resolution: .daily)
        let none = try await client.production(
            homeID: "home-1", resolution: .daily, from: day0, to: day0.addingTimeInterval(5 * 86_400))
        #expect(none.isEmpty)
    }

    @Test("Daily and monthly paging is bounded")
    func pagingIsBounded() async throws {
        let tibber = MockTibberEnergy(pageLimit: 1)
        tibber.setConsumption(days(1_000), resolution: .daily)
        tibber.setConsumption(days(1_000), resolution: .monthly)
        tibber.setProduction(days(1_000), resolution: .daily)
        tibber.setProduction(days(1_000), resolution: .monthly)
        let client = TibberClient(token: "t", transport: tibber.transport)
        _ = try await client.consumption(homeID: "home-1", resolution: .daily, from: day0, to: day0.addingTimeInterval(1_000 * 86_400))
        #expect(tibber.requestCount == TibberClient.maximumDailyPages)
        let beforeMonthly = tibber.requestCount
        _ = try await client.production(homeID: "home-1", resolution: .monthly, from: day0, to: day0.addingTimeInterval(1_000 * 86_400))
        #expect(tibber.requestCount - beforeMonthly == TibberClient.maximumMonthlyPages)
    }

    @Test("The published prices come back as slots with their levels")
    func publishedPrices() async throws {
        let tibber = MockTibberEnergy()
        let start = day0.addingTimeInterval(6 * 3_600)
        tibber.setPublishedPrices(
            today: (0..<4).map { (start.addingTimeInterval(Double($0) * 900), 1.0, $0.isMultiple(of: 2) ? "CHEAP" : nil) },
            tomorrow: [(start.addingTimeInterval(86_400), 2.0, "EXPENSIVE"),
                       (start.addingTimeInterval(86_400 + 900), 2.0, "EXPENSIVE")])
        let points = try await TibberClient(token: "t", transport: tibber.transport).currentPrices(homeID: "home-1")
        #expect(points.count == 6)
        #expect(points.allSatisfy { $0.end.timeIntervalSince($0.start) == 900 })
        #expect(points.map(\.level) == [.cheap, nil, .cheap, nil, .expensive, .expensive])
        #expect(points.last?.pricePerKwh == 2.0)
    }
}

@Suite("Tibber price level tally")
struct TibberPriceLevelTallyTests {
    private func point(_ start: Date, minutes: Double, level: TibberPriceLevel?) -> HomePricePoint {
        HomePricePoint(start: start, end: start.addingTimeInterval(minutes * 60), pricePerKwh: 1.0, level: level)
    }

    @Test("Slots add up as hours, and a slot without a level counts nowhere")
    func hours() {
        let start = day0.addingTimeInterval(6 * 3_600)
        let points = [
            point(start, minutes: 15, level: .cheap),
            point(start.addingTimeInterval(900), minutes: 15, level: .cheap),
            point(start.addingTimeInterval(1_800), minutes: 15, level: .veryCheap),
            point(start.addingTimeInterval(2_700), minutes: 15, level: .expensive),
            point(start.addingTimeInterval(3_600), minutes: 15, level: .expensive),
            point(start.addingTimeInterval(4_500), minutes: 15, level: nil),
        ]
        let tally = TibberPriceLevelTally.hours(points)
        #expect(tally[.cheap] == 0.5)
        #expect(tally[.veryCheap] == 0.25)
        #expect(tally[.expensive] == 0.5)
        // A level with no slots is absent, not zero, and an empty feed tallies to nothing.
        #expect(tally[.normal] == nil)
        #expect(tally[.veryExpensive] == nil)
        #expect(TibberPriceLevelTally.hours([]).isEmpty)
    }

    @Test("The tally splits by calendar day in the calendar it is given, oldest day first")
    func perDay() {
        var calendar = utcCalendar
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = day0.addingTimeInterval(86_400)
        let points = [
            point(day0.addingTimeInterval(23 * 3_600), minutes: 15, level: .cheap),
            point(day1, minutes: 15, level: .expensive),
            point(day1.addingTimeInterval(900), minutes: 15, level: .expensive),
        ]
        let days = TibberPriceLevelTally.perDay(points, calendar: calendar)
        #expect(days.count == 2)
        #expect(days[0].day == day0)
        #expect(days[0].hours[.cheap] == 0.25)
        #expect(days[1].day == day1)
        #expect(days[1].hours[.expensive] == 0.5)
    }
}

@Suite("Tibber energy readout model", .serialized)
@MainActor
struct TibberEnergyModelTests {
    private func connectedHome() throws -> ScopedPreferences {
        let scoped = ScopedPreferences(label: "tibber-energy")
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        try store.saveTibberToken("tibber-token")
        store.tibberHome = TibberHome(id: "home-1", name: "Villa", timeZone: "Europe/Stockholm", currency: "SEK")
        return scoped
    }

    private func rows(_ count: Int, from start: Date) -> [(Date, Double?)] {
        (0..<count).map { (start.addingTimeInterval(Double($0) * 86_400), Double($0) + 1) }
    }

    @Test("One read fills the days, the months and the level tally, and names no problem")
    func reloadFillsContent() async throws {
        // A page as wide as the daily window lets each one-page reach answer in a single request.
        let tibber = MockTibberEnergy(pageLimit: 31)
        let scoped = try connectedHome()
        let now = day0.addingTimeInterval(61 * 86_400)
        tibber.setConsumption(rows(31, from: now.addingTimeInterval(-30 * 86_400)), resolution: .daily)
        tibber.setProduction(rows(31, from: now.addingTimeInterval(-30 * 86_400)), resolution: .daily)
        tibber.setConsumption(rows(12, from: now.addingTimeInterval(-360 * 86_400)), resolution: .monthly)
        tibber.setPublishedPrices(
            today: (0..<4).map { (now.addingTimeInterval(Double($0) * 900), 1.0, "CHEAP") },
            tomorrow: [])
        let model = TibberEnergyModel(preferences: scoped.store, transport: tibber.transport, now: { now })
        await model.reload()
        let content = try #require(model.content)
        #expect(content.days.count == 31)
        #expect(content.productionDays.count == 31)
        #expect(content.months.count == 12)
        #expect(content.levelHours[.cheap] == 1.0)
        #expect(content.cost?.currency == "SEK")
        #expect(model.problem == nil)
        // The daily and monthly readings and the published prices, and nothing else. Paging asks
        // the same query twice, so the distinct queries are what count the endpoints.
        #expect(Set(tibber.queries).count == 5)
    }

    @Test("A failed read keeps the last good content and names the reason")
    func failureKeepsContent() async throws {
        let tibber = MockTibberEnergy()
        let scoped = try connectedHome()
        let now = day0.addingTimeInterval(61 * 86_400)
        tibber.setConsumption(rows(31, from: now.addingTimeInterval(-30 * 86_400)), resolution: .daily)
        let model = TibberEnergyModel(preferences: scoped.store, transport: tibber.transport, now: { now })
        await model.reload()
        let good = try #require(model.content)
        tibber.setFailure(#"{"message":"Unauthenticated","extensions":{"code":"UNAUTHENTICATED"}}"#)
        await model.reload()
        #expect(model.content == good)
        #expect(model.problem != nil)
        #expect(model.problem?.isEmpty == false)
    }

    @Test("Without a connected home the readout stays empty and nothing is asked")
    func notConfigured() async throws {
        let tibber = MockTibberEnergy()
        let scoped = ScopedPreferences(label: "tibber-energy")
        let model = TibberEnergyModel(preferences: scoped.store, transport: tibber.transport, now: { day0 })
        await model.reload()
        #expect(model.content == nil)
        #expect(model.problem == nil)
        #expect(tibber.requestCount == 0)
    }
}
