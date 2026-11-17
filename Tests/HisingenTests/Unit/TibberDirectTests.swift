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
    func setFailure(_ errors: String?) { lock.withLock { failure = errors } }
    func setStatus(_ status: Int) { lock.withLock { httpStatus = status } }
    var requestCount: Int { lock.withLock { queries.count } }

    private func answer(_ request: URLRequest) -> MockHomeAssistantTransport.Reply {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        let (slots, failure, status) = lock.withLock { () -> ([(Date, Double)], String?, Int) in
            queries.append(query)
            beforeCursors.append(variables["before"] as? String)
            authorization.append(request.value(forHTTPHeaderField: "Authorization"))
            return (_slots, self.failure, httpStatus)
        }
        if status != 200 { return .json(#"{"message":"nope"}"#, status: status) }
        if let failure { return .json(#"{"errors":[\#(failure)],"data":null}"#) }
        if query.contains("homes") {
            return .json("""
            {"data":{"viewer":{"homes":[
              {"id":"home-1","timeZone":"Europe/Stockholm","appNickname":"Villa","address":{"address1":"Storgatan 1"},
               "currentSubscription":{"priceInfo":{"current":{"currency":"SEK"}}}},
              {"id":"home-2","timeZone":"Europe/Stockholm","appNickname":null,"address":{"address1":"Fjällvägen 2"},
               "currentSubscription":null}]}}}
            """)
        }
        var end = slots.count
        if let before = variables["before"] as? String, let index = Int(before.dropFirst(4)) { end = index }
        let start = max(0, end - pageLimit)
        let edges = (start..<end).map { index in
            #"{"cursor":"cur-\#(index)","node":{"total":\#(slots[index].1),"startsAt":"\#(iso(slots[index].0))"}}"#
        }
        return .json(#"{"data":{"viewer":{"home":{"currentSubscription":{"priceInfo":{"range":{"edges":[\#(edges.joined(separator: ","))]}}}}}}}"#)
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
        let collected: [Date: Double] = [base: 1.0, base.addingTimeInterval(3_600): 2.0, base.addingTimeInterval(7_200): 3.0]
        let points = TibberClient.points(from: collected, from: base, to: base.addingTimeInterval(10_800))
        #expect(points.map { $0.end.timeIntervalSince($0.start) } == [3_600, 3_600, 3_600])
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
}
