import Foundation
import Testing
@testable import Hisingen

private let base = Date(timeIntervalSince1970: 1_794_000_000)   // a quarter-hour boundary
private let t0 = base

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// A Tibber API that serves a fixed series of quarter-hour prices in pages of `pageLimit`, newest
/// page first, with a cursor on every edge, the way the real one pages with `last` and `before`.
private final class MockTibber: @unchecked Sendable {
    let transport: MockHomeAssistantTransport
    private let lock = NSLock()
    private var _slots: [(Date, Double)] = []
    private var failure: String?
    private var httpStatus = 200
    private var _consumption: [(Date, Double?)] = []
    private var _upcoming: [(Date, Double)] = []
    private var _production: [(Date, Double?)] = []
    private var _liveEnabled = false
    private var _liveURL: String? = nil
    private(set) var queries: [String] = []
    private(set) var beforeCursors: [String?] = []
    private(set) var authorization: [String?] = []
    let pageLimit: Int

    init(transport: MockHomeAssistantTransport = MockHomeAssistantTransport(), pageLimit: Int = 8) {
        self.transport = transport
        self.pageLimit = pageLimit
        transport.route({ $0.httpMethod == "POST" && $0.url?.path == "/v1-beta/gql" }) { [weak self] request in
            self?.answer(request) ?? .json("{}", status: 503)
        }
    }

    func setSlots(count: Int, price: @escaping (Int) -> Double = { _ in 1.0 }, startingAt start: Date = base) {
        lock.withLock { _slots = (0..<count).map { (start.addingTimeInterval(Double($0) * 900), price($0)) } }
    }
    /// Prices Tibber has published for the slots still to come, which only `priceInfo` serves.
    func setUpcoming(count: Int, price: Double, startingAt start: Date) {
        lock.withLock { _upcoming = (0..<count).map { (start.addingTimeInterval(Double($0) * 900), price) } }
    }
    /// Hourly whole-home readings, oldest first; `nil` is an hour the meter has not reported.
    func setConsumption(hours: Int, startingAt start: Date = base, kwh: @escaping (Int) -> Double? = { _ in 1.0 }) {
        lock.withLock { _consumption = (0..<hours).map { (start.addingTimeInterval(Double($0) * 3_600), kwh($0)) } }
    }
    /// Hourly production readings, oldest first; `nil` is an hour without one, which the API sends
    /// as a null node.
    func setProduction(hours: Int, startingAt start: Date = base, kwh: @escaping (Int) -> Double? = { _ in 1.0 }) {
        lock.withLock { _production = (0..<hours).map { (start.addingTimeInterval(Double($0) * 3_600), kwh($0)) } }
    }
    /// Whether the home's features say a live reader is paired, and the URL the API names for
    /// subscriptions.
    func setLiveStream(enabled: Bool, url: String? = nil) {
        lock.withLock { _liveEnabled = enabled; _liveURL = url }
    }
    func setFailure(_ errors: String?) { lock.withLock { failure = errors } }
    func setStatus(_ status: Int) { lock.withLock { httpStatus = status } }
    var requestCount: Int { lock.withLock { queries.count } }

    private func answer(_ request: URLRequest) -> MockHomeAssistantTransport.Reply {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        let (slots, failure, status, hours, upcoming, production, liveEnabled, liveURL) = lock.withLock { () -> ([(Date, Double)], String?, Int, [(Date, Double?)], [(Date, Double)], [(Date, Double?)], Bool, String?) in
            queries.append(query)
            beforeCursors.append(variables["before"] as? String)
            authorization.append(request.value(forHTTPHeaderField: "Authorization"))
            return (_slots, self.failure, httpStatus, _consumption, _upcoming, _production, _liveEnabled, _liveURL)
        }
        if status != 200 { return .json(#"{"message":"nope"}"#, status: status) }
        if let failure { return .json(#"{"errors":[\#(failure)],"data":null}"#) }
        if query.contains("homes") {
            return .json("""
            {"data":{"viewer":{"homes":[
              {"id":"home-1","timeZone":"Europe/Stockholm","appNickname":"Villa","address":{"address1":"Storgatan 1"},
               "meteringPointData":{"priceAreaCode":"SE3","gridCompany":"Vattenfall Eldistribution AB"},
               "currentSubscription":{"priceInfo":{"current":{"currency":"SEK"}}}},
              {"id":"home-2","timeZone":"Europe/Stockholm","appNickname":null,"address":{"address1":"Fjällvägen 2"},
               "currentSubscription":null}]}}}
            """)
        }
        if query.contains("priceInfo(resolution") {
            // Like the real API: today in full and tomorrow when it is out, each slot with its level.
            let rows = upcoming.map { #"{"total":\#($0.1),"startsAt":"\#(iso($0.0))","level":"NORMAL"}"# }
            return .json(#"{"data":{"viewer":{"home":{"currentSubscription":{"priceInfo":{"today":[\#(rows.joined(separator: ","))],"tomorrow":[]}}}}}}"#)
        }
        if query.contains("websocketSubscriptionUrl") {
            let url = liveURL.map { #""\#($0)""# } ?? "null"
            return .json(#"{"data":{"viewer":{"websocketSubscriptionUrl":\#(url),"home":{"features":{"realTimeConsumptionEnabled":\#(liveEnabled)}}}}}"#)
        }
        if query.contains("production(") {
            var end = production.count
            if let before = variables["before"] as? String, let index = Int(before.dropFirst(4)) { end = index }
            let start = max(0, end - pageLimit)
            let edges = (start..<end).map { index -> String in
                let value = production[index].1.map { String($0) } ?? "null"
                return #"{"cursor":"cur-\#(index)","node":{"from":"\#(iso(production[index].0))","to":"\#(iso(production[index].0.addingTimeInterval(3_600)))","production":\#(value)}}"#
            }
            return .json(#"{"data":{"viewer":{"home":{"production":{"edges":[\#(edges.joined(separator: ","))]}}}}}"#)
        }
        if query.contains("consumption(") {
            var end = hours.count
            if let before = variables["before"] as? String, let index = Int(before.dropFirst(4)) { end = index }
            let start = max(0, end - pageLimit)
            let edges = (start..<end).map { index -> String in
                let value = hours[index].1.map { String($0) } ?? "null"
                return #"{"cursor":"cur-\#(index)","node":{"from":"\#(iso(hours[index].0))","to":"\#(iso(hours[index].0.addingTimeInterval(3_600)))","consumption":\#(value),"cost":\#(hours[index].1.map { String($0 * 1.5) } ?? "null"),"currency":"SEK"}}"#
            }
            return .json(#"{"data":{"viewer":{"home":{"consumption":{"edges":[\#(edges.joined(separator: ","))]}}}}}"#)
        }
        var end = slots.count
        if let before = variables["before"] as? String, let index = Int(before.dropFirst(4)) { end = index }
        let start = max(0, end - pageLimit)
        let edges = (start..<end).map { index in
            let level = index % 2 == 0 ? #","level":"CHEAP""# : ""
            return #"{"cursor":"cur-\#(index)","node":{"total":\#(slots[index].1),"startsAt":"\#(iso(slots[index].0))"\#(level)}}"#
        }
        return .json(#"{"data":{"viewer":{"home":{"currentSubscription":{"priceInfoRange":{"edges":[\#(edges.joined(separator: ","))]}}}}}}"#)
    }
}

@Suite("Tibber API client")
struct TibberClientTests {
    @Test("The homes query reads the nickname, address, time zone and currency, and sends the token as a bearer")
    func homes() async throws {
        let tibber = MockTibber()
        let homes = try await TibberClient(token: " tok-123 \n", transport: tibber.transport).homes()
        #expect(homes.map(\.id) == ["home-1", "home-2"])
        #expect(homes[0].name == "Villa")
        #expect(homes[0].currency == "SEK")
        #expect(homes[0].timeZone == "Europe/Stockholm")
        // The metering point names the spot-price zone and the grid company.
        #expect(homes[0].priceArea == "SE3")
        #expect(homes[0].elspotZone == .se3)
        #expect(homes[0].gridCompany == "Vattenfall Eldistribution AB")
        #expect(homes[1].priceArea == nil)
        #expect(homes[1].elspotZone == nil)
        // No nickname: the street address names it. No subscription: no currency, and no failure.
        #expect(homes[1].name == "Fjällvägen 2")
        #expect(homes[1].currency == nil)
        #expect(tibber.authorization == ["Bearer tok-123"])
    }

    @Test("Prices are read page by page back from the newest, following the cursors Tibber returns")
    func paging() async throws {
        let tibber = MockTibber(pageLimit: 8)
        tibber.setSlots(count: 24) { 1.0 + Double($0) / 100 }
        let from = base.addingTimeInterval(3 * 900)
        let to = base.addingTimeInterval(20 * 900)
        let points = try await TibberClient(token: "t", transport: tibber.transport).prices(homeID: "home-1", from: from, to: to)
        // Newest page, then two older ones; it stops once a page reaches `from`.
        #expect(tibber.beforeCursors == [nil, "cur-16", "cur-8"])
        #expect(points.first?.start == base.addingTimeInterval(3 * 900))   // the slot that begins at `from`
        #expect(points.last?.start == base.addingTimeInterval(19 * 900))
        #expect(points.count == 17)
        // Slots are quarter-hours and carry Tibber's all-in price unchanged.
        #expect(points.allSatisfy { $0.end.timeIntervalSince($0.start) == 900 })
        #expect(abs((points.first?.pricePerKwh ?? 0) - 1.03) < 1e-9)
    }

    @Test("Prices come from the subscription's priceInfoRange, which is where Tibber serves quarter-hours")
    func queryShape() async throws {
        // `priceInfo { range(resolution: QUARTER_HOURLY) }` is refused by the live API with HTTP 400,
        // because that legacy field only takes HOURLY and DAILY.
        let tibber = MockTibber(pageLimit: 50)
        tibber.setSlots(count: 8)
        _ = try await TibberClient(token: "t", transport: tibber.transport).prices(homeID: "home-1", from: base, to: base.addingTimeInterval(8 * 900))
        #expect(tibber.queries.first?.contains("priceInfoRange(resolution: QUARTER_HOURLY") == true)
        #expect(tibber.queries.first?.contains("priceInfo {") == false)
    }

    @Test("A span that reaches past now also gets the prices Tibber has published for the slots to come")
    func upcomingPricesAreMerged() async throws {
        // priceInfoRange stops at the slot running now; against the live API it returned nothing after it.
        let tibber = MockTibber(pageLimit: 50)
        tibber.setSlots(count: 8, price: { _ in 1.0 })
        let now = base.addingTimeInterval(8 * 900)
        tibber.setUpcoming(count: 8, price: 2.0, startingAt: now)
        let client = TibberClient(token: "t", transport: tibber.transport, now: { now })
        let points = try await client.prices(homeID: "home-1", from: base, to: base.addingTimeInterval(16 * 900))
        #expect(points.count == 16)
        #expect(points.last?.end == base.addingTimeInterval(16 * 900))
        #expect(points.prefix(8).allSatisfy { $0.pricePerKwh == 1.0 })
        #expect(points.suffix(8).allSatisfy { $0.pricePerKwh == 2.0 })
        // The slot the range and the upcoming list both name is one slot, not two.
        #expect(Set(points.map(\.start)).count == points.count)
    }

    @Test("A span that ends before now does not ask for upcoming prices")
    func pastSpanSkipsUpcoming() async throws {
        let tibber = MockTibber(pageLimit: 50)
        tibber.setSlots(count: 8)
        tibber.setUpcoming(count: 8, price: 2.0, startingAt: base.addingTimeInterval(8 * 900))
        let client = TibberClient(token: "t", transport: tibber.transport, now: { base.addingTimeInterval(8 * 900) })
        _ = try await client.prices(homeID: "home-1", from: base, to: base.addingTimeInterval(6 * 900))
        #expect(tibber.queries.allSatisfy { !$0.contains("priceInfo(resolution") })
    }

    @Test("A slot carries Tibber's level when it gives one, and none when it does not")
    func levels() async throws {
        let tibber = MockTibber(pageLimit: 50)
        tibber.setSlots(count: 4)
        let points = try await TibberClient(token: "t", transport: tibber.transport).prices(
            homeID: "home-1", from: base, to: base.addingTimeInterval(4 * 900))
        #expect(points.map(\.level) == [.cheap, nil, .cheap, nil])
    }

    @Test("Hourly consumption is read in pages, and an hour without a reading is left out, not counted as zero")
    func consumption() async throws {
        let tibber = MockTibber(pageLimit: 12)
        tibber.setConsumption(hours: 24) { $0 == 5 ? nil : 2.0 }
        let hours = try await TibberClient(token: "t", transport: tibber.transport).consumption(
            homeID: "home-1", from: base, to: base.addingTimeInterval(24 * 3_600))
        #expect(hours.count == 23)
        #expect(!hours.contains { $0.start == base.addingTimeInterval(5 * 3_600) })
        #expect(hours.allSatisfy { $0.kwh == 2.0 && $0.end.timeIntervalSince($0.start) == 3_600 })
        // Tibber's billed cost and its currency ride along with each hour.
        #expect(hours.allSatisfy { $0.cost == 3.0 && $0.currency == "SEK" })
        #expect(tibber.beforeCursors == [nil, "cur-12"])
        #expect(hours == hours.sorted { $0.start < $1.start })
    }

    @Test("Consumption paging is bounded")
    func consumptionIsBounded() async throws {
        let tibber = MockTibber(pageLimit: 2)
        tibber.setConsumption(hours: 1_000)
        _ = try await TibberClient(token: "t", transport: tibber.transport).consumption(
            homeID: "home-1", from: base, to: base.addingTimeInterval(1_000 * 3_600))
        #expect(tibber.requestCount == TibberClient.maximumConsumptionPages)
    }

    @Test("One page of consumption is enough when it already reaches back far enough")
    func consumptionSinglePage() async throws {
        let tibber = MockTibber(pageLimit: 100)
        tibber.setConsumption(hours: 24)
        _ = try await TibberClient(token: "t", transport: tibber.transport).consumption(
            homeID: "home-1", from: base.addingTimeInterval(6 * 3_600), to: base.addingTimeInterval(20 * 3_600))
        #expect(tibber.requestCount == 1)
    }

    @Test("Hourly production pages the same way consumption does, and an hour without a reading is left out")
    func production() async throws {
        let tibber = MockTibber(pageLimit: 12)
        tibber.setProduction(hours: 24) { $0 == 5 ? nil : 1.5 }
        let hours = try await TibberClient(token: "t", transport: tibber.transport).production(
            homeID: "home-1", from: base, to: base.addingTimeInterval(24 * 3_600))
        #expect(hours.count == 23)
        #expect(!hours.contains { $0.start == base.addingTimeInterval(5 * 3_600) })
        #expect(hours.allSatisfy { $0.kwh == 1.5 && $0.end.timeIntervalSince($0.start) == 3_600 })
        #expect(tibber.beforeCursors == [nil, "cur-12"])
        #expect(hours == hours.sorted { $0.start < $1.start })
    }

    @Test("A home without a production metering point answers with no hours, which stays an empty answer")
    func productionAbsent() async throws {
        let tibber = MockTibber(pageLimit: 100)
        let hours = try await TibberClient(token: "t", transport: tibber.transport).production(
            homeID: "home-1", from: base, to: base.addingTimeInterval(24 * 3_600))
        #expect(hours.isEmpty)
        #expect(tibber.requestCount == 1)
    }

    @Test("Production paging is bounded")
    func productionIsBounded() async throws {
        let tibber = MockTibber(pageLimit: 2)
        tibber.setProduction(hours: 1_000)
        _ = try await TibberClient(token: "t", transport: tibber.transport).production(
            homeID: "home-1", from: base, to: base.addingTimeInterval(1_000 * 3_600))
        #expect(tibber.requestCount == TibberClient.maximumProductionPages)
    }

    @Test("The live-stream check reads whether a reader is paired and the URL the API names")
    func liveStream() async throws {
        let tibber = MockTibber()
        tibber.setLiveStream(enabled: true, url: "wss://api.tibber.com/v1-beta/gql/subscriptions")
        let stream = try await TibberClient(token: "t", transport: tibber.transport).liveStream(homeID: "home-1")
        #expect(stream.realTimeEnabled)
        #expect(stream.url == TibberLiveSocket.subscriptionURL)
        tibber.setLiveStream(enabled: false)
        let refused = try await TibberClient(token: "t", transport: tibber.transport).liveStream(homeID: "home-1")
        #expect(!refused.realTimeEnabled)
        #expect(refused.url == nil)
        // The query asks for the fields the schema documents, and nothing else.
        #expect(tibber.queries.allSatisfy { $0.contains("realTimeConsumptionEnabled") && $0.contains("websocketSubscriptionUrl") })
    }

    @Test("One page is enough when it already reaches back far enough")
    func singlePage() async throws {
        let tibber = MockTibber(pageLimit: 50)
        tibber.setSlots(count: 24)
        _ = try await TibberClient(token: "t", transport: tibber.transport).prices(
            homeID: "home-1", from: base.addingTimeInterval(4 * 900), to: base.addingTimeInterval(10 * 900))
        #expect(tibber.requestCount == 1)
    }

    @Test("Paging is bounded and a cursor that does not move stops it")
    func pagingIsBounded() async throws {
        let tibber = MockTibber(pageLimit: 2)
        tibber.setSlots(count: 1_000)
        _ = try await TibberClient(token: "t", transport: tibber.transport).prices(
            homeID: "home-1", from: base, to: base.addingTimeInterval(1_000 * 900))
        #expect(tibber.requestCount == TibberClient.maximumPages)
    }

    @Test("A gap in Tibber's prices stays a gap and is not filled")
    func gapsStayGaps() async throws {
        let tibber = MockTibber(pageLimit: 100)
        tibber.setSlots(count: 12)
        let points = try await TibberClient(token: "t", transport: tibber.transport).prices(
            homeID: "home-1", from: base.addingTimeInterval(-4 * 3_600), to: base.addingTimeInterval(4 * 3_600))
        // Only the twelve published slots come back; the hours before them are not invented.
        #expect(points.count == 12)
        #expect(points.first?.start == base)
    }

    @Test("GraphQL failures arrive as 200 with errors, and each reader-actionable one is told apart")
    func errors() async throws {
        let cases: [(String, DirectChargerError)] = [
            (#"{"message":"Unauthenticated","extensions":{"code":"UNAUTHENTICATED"}}"#, .unauthorized),
            (#"{"message":"Invalid token"}"#, .unauthorized),
            (#"{"message":"Too many requests","extensions":{"code":"RATE_LIMIT_EXCEEDED"}}"#, .rateLimited(retryAfter: nil)),
            (#"{"message":"Home not found"}"#, .rejected(status: 200, message: "Home not found"))
        ]
        for (errors, expected) in cases {
            let tibber = MockTibber()
            tibber.setFailure(errors)
            await #expect(throws: expected) { _ = try await TibberClient(token: "secret-token", transport: tibber.transport).homes() }
        }
        let refused = MockTibber()
        refused.setStatus(401)
        await #expect(throws: DirectChargerError.unauthorized) { _ = try await TibberClient(token: "secret-token", transport: refused.transport).homes() }
        let text = DirectChargerError.unauthorized.errorDescription ?? ""
        #expect(!text.contains("secret-token"))
    }

    @Test("Hourly prices spread over quarter-hour slots keep their own step")
    func hourlyStep() {
        let collected: [Date: (price: Double, level: TibberPriceLevel?)] = [
            base: (1.0, nil), base.addingTimeInterval(3_600): (2.0, nil), base.addingTimeInterval(7_200): (3.0, nil)]
        let points = TibberClient.points(from: collected, from: base, to: base.addingTimeInterval(10_800))
        #expect(points.map { $0.end.timeIntervalSince($0.start) } == [3_600, 3_600, 3_600])
    }

    @Test("Mixed 60-minute and 15-minute slots across a DST boundary remain contiguous without overlaps or gaps")
    func mixedGranularityAndDstBounds() {
        let utcMorning = Date(timeIntervalSince1970: 1_792_886_400) // 2026-10-25T00:00:00Z (DST fallback night in Europe/Stockholm)
        let collected: [Date: (price: Double, level: TibberPriceLevel?)] = [
            utcMorning: (1.0, .cheap),
            utcMorning.addingTimeInterval(3_600): (2.0, .normal),
            utcMorning.addingTimeInterval(4_500): (2.4, .expensive),
            utcMorning.addingTimeInterval(5_400): (1.6, .normal),
        ]
        let points = TibberClient.points(from: collected, from: utcMorning, to: utcMorning.addingTimeInterval(7_200))
        #expect(points.count == 4)
        #expect(points[0].end == points[1].start)
        #expect(points[1].end == points[2].start)
        #expect(points[2].end == points[3].start)
        #expect(points[0].end.timeIntervalSince(points[0].start) == 3_600)
        #expect(points[1].end.timeIntervalSince(points[1].start) == 900)
        #expect(points[3].end.timeIntervalSince(points[3].start) == 900)
    }

    @Test
    func anOutageDoesNotSetThePriceCadence() {
        let afterOutage = base.addingTimeInterval(4 * 3_600)
        let collected: [Date: (price: Double, level: TibberPriceLevel?)] = [
            base: (0.2, nil),
            afterOutage: (0.4, nil),
        ]
        let points = TibberClient.points(from: collected, from: base, to: afterOutage.addingTimeInterval(3_600))

        #expect(points.map(\.start) == [base, afterOutage])
        #expect(points.map(\.end) == [base.addingTimeInterval(900), afterOutage.addingTimeInterval(900)])
    }
}

// MARK: - Pricing a direct charger's sessions

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}

@MainActor
private final class PricingHarness {
    let scoped = ScopedPreferences(label: "tibber-direct")
    let database = VehicleDatabase.inMemory()
    let tibber: MockTibber
    let clock: Clock
    let model: HomeChargingModel
    let sessionStart = ISO8601DateFormatter().date(from: "2026-11-14T22:00:00Z")!

    init(fee: Double = 0) throws {
        let transport = MockHomeAssistantTransport()
        tibber = MockTibber(transport: transport, pageLimit: 400)
        clock = Clock(ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!)
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        try store.saveCredentials(DirectChargerCredentials(username: "owner@example.se", password: "pw"), for: .easee)
        store.pairing = HomeChargingPairing(
            baseURL: "", chargerID: "EH1", chargerName: "Garage", entities: HomeChargerEntityMap(), vin: "YSMTEST",
            locationID: "home-loc", locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm",
            networkFeeOrePerKwh: fee, source: .easee)
        scoped.store.storeChargingHistory = true
        transport.route({ $0.url?.path == "/api/accounts/login" }) { _ in .json(#"{"accessToken":"AT","expiresIn":3600}"#) }
        transport.route({ ($0.url?.path ?? "").hasSuffix("/observations") }) { _ in
            .json(#"{"observations":[{"id":109,"value":"1"},{"id":250,"value":"true"}]}"#)
        }
        transport.route("GET", "/api/sessions/", .json("""
        [{"id":41,"isComplete":true,"kiloWattHours":10.0,"carConnected":"2026-11-14T21:00:00Z","carDisconnected":"2026-11-15T03:00:00Z",
          "firstEnergyTransferPeriodStarted":"2026-11-14T22:00:00Z","lastEnergyTransferPeriodEnd":"2026-11-15T00:00:00Z"}]
        """))
        let clock = clock
        model = HomeChargingModel(
            preferences: scoped.store, database: database,
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, now: { clock.now },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, spotPrices: { _ in [] }, observesWake: false))
    }

    /// Prices for the two hours of the session: 1.00 for the first hour and 2.00 for the second.
    func publishPrices() {
        let start = sessionStart.addingTimeInterval(-6 * 3_600)
        tibber.setSlots(count: 24 * 4, price: { index in
            let slotStart = start.addingTimeInterval(Double(index) * 900)
            return slotStart >= self.sessionStart.addingTimeInterval(3_600) && slotStart < self.sessionStart.addingTimeInterval(7_200) ? 2.0 : 1.0
        }, startingAt: start)
    }

    func connectTibber() throws {
        try model.connectTibber(token: "tibber-token", home: TibberHome(id: "home-1", name: "Villa", timeZone: nil, currency: "SEK"))
    }

    func importSessions() async -> HomeSessionSync.Summary? {
        await model.syncSessions()
        if case .finished(let summary) = model.syncState { return summary }
        return nil
    }
}

@Suite("Direct charger sessions priced from Tibber", .serialized)
@MainActor
struct TibberSessionPricingTests {
    @Test("A session is priced at Tibber's time-weighted average, with the network fee added once and the method recorded")
    func pricedFromTheTibberApi() async throws {
        let harness = try PricingHarness(fee: 25)
        harness.publishPrices()
        try harness.connectTibber()
        _ = await harness.importSessions()
        let row = try #require(harness.database.charging.recentChargingSessions(for: "YSMTEST").first)
        let wallbox = try #require(row.wallbox)
        #expect(wallbox.costMethod == HomeSessionCost.Method.totalTibberAverage.rawValue)
        #expect(wallbox.priceSource == HomeSessionPricer.tibberAPISource)
        // Hour one at 1.00 and hour two at 2.00 average 1.50; the 0.25 fee is added to each kWh of the 10 kWh.
        #expect(abs((wallbox.cost ?? 0) - 17.5) < 1e-6)
        #expect(!wallbox.costAssumptions.isEmpty)
        // It reached Tibber and the charger's cloud, and nothing else.
        let homeAssistantCalls = harness.tibber.transport.requests.filter { ($0.url?.path ?? "").hasPrefix("/api/services") }
        #expect(homeAssistantCalls.isEmpty)
        #expect(harness.model.tibberProblem == nil)
    }

    @Test("Without Tibber connected the cost falls back to the rate settings and says so")
    func notConnected() async throws {
        let harness = try PricingHarness()
        _ = await harness.importSessions()
        let wallbox = try #require(harness.database.charging.recentChargingSessions(for: "YSMTEST").first?.wallbox)
        #expect(wallbox.costMethod != HomeSessionCost.Method.totalTibberAverage.rawValue)
        #expect(wallbox.costMethod != HomeSessionCost.Method.intervalTibber.rawValue)
        #expect(harness.tibber.queries.isEmpty)
    }

    @Test("A Tibber failure never blocks the import: the session is priced from the rate settings and the reason is kept")
    func tibberFails() async throws {
        let harness = try PricingHarness()
        try harness.connectTibber()
        harness.tibber.setFailure(#"{"message":"Too many requests","extensions":{"code":"RATE_LIMIT_EXCEEDED"}}"#)
        let summary = await harness.importSessions()
        #expect(summary?.tibberProblem != nil)
        #expect(harness.model.tibberProblem != nil)
        let wallbox = try #require(harness.database.charging.recentChargingSessions(for: "YSMTEST").first?.wallbox)
        #expect(wallbox.costMethod != HomeSessionCost.Method.totalTibberAverage.rawValue)
        #expect(wallbox.energyKwh == 10.0)
    }

    @Test("A session that Tibber's prices only partly cover is not priced as if they covered it")
    func partialCoverage() async throws {
        let harness = try PricingHarness()
        // Prices published for the first half hour of the session only.
        harness.tibber.setSlots(count: 2, price: { _ in 1.0 }, startingAt: harness.sessionStart)
        try harness.connectTibber()
        _ = await harness.importSessions()
        let wallbox = try #require(harness.database.charging.recentChargingSessions(for: "YSMTEST").first?.wallbox)
        #expect(wallbox.costMethod != HomeSessionCost.Method.totalTibberAverage.rawValue)
    }

    @Test("Connecting stores the token in the Keychain only; disconnecting removes it and the home")
    func tokenStorage() async throws {
        let harness = try PricingHarness()
        try harness.connectTibber()
        #expect(harness.model.hasTibberToken)
        #expect(harness.model.tibberHome?.id == "home-1")
        let dump = harness.scoped.defaults.dictionaryRepresentation().description
        #expect(!dump.contains("tibber-token"))
        harness.model.disconnectTibber()
        #expect(!harness.model.hasTibberToken)
        #expect(harness.model.tibberHome == nil)
        #expect(harness.scoped.defaults.data(forKey: HomeChargingStore.tibberHomeKey) == nil)
    }

    @Test("Erasing everything removes the Tibber token with the rest")
    func erase() async throws {
        let harness = try PricingHarness()
        try harness.connectTibber()
        harness.model.eraseEverything()
        #expect(!harness.model.hasTibberToken)
        #expect(harness.model.tibberHome == nil)
    }

    @Test("The token is checked against Tibber before anything is saved")
    func testBeforeSave() async throws {
        let harness = try PricingHarness()
        harness.tibber.setFailure(#"{"message":"Unauthenticated","extensions":{"code":"UNAUTHENTICATED"}}"#)
        let result = await harness.model.testTibber(token: "bad")
        #expect(result == .failure(.unauthorized))
        #expect(!harness.model.hasTibberToken)
        harness.tibber.setFailure(nil)
        guard case .success(let homes) = await harness.model.testTibber(token: "good") else { Issue.record("expected homes"); return }
        #expect(homes.count == 2)
        #expect(!harness.model.hasTibberToken)
    }

    @Test("Non-SEK Tibber homes provide planner sources with their own currency and time zone")
    func nonSekPlannerTibberSource() throws {
        let harness = try PricingHarness()
        try harness.model.connectTibber(
            token: "tibber-token",
            home: TibberHome(id: "home-no", name: "Oslo", timeZone: "Europe/Oslo", currency: "NOK")
        )
        let nokSource = try #require(harness.model.plannerTibberSource())
        #expect(nokSource.currency == "NOK")
        #expect(nokSource.timeZoneIdentifier == "Europe/Oslo")

        try harness.model.connectTibber(
            token: "tibber-token",
            home: TibberHome(id: "home-de", name: "Berlin", timeZone: "Europe/Berlin", currency: "EUR")
        )
        let eurSource = try #require(harness.model.plannerTibberSource())
        #expect(eurSource.currency == "EUR")
        #expect(eurSource.timeZoneIdentifier == "Europe/Berlin")
    }
}
