import Foundation

/// A Tibber home the token can read, as the reader picks it during setup.
struct TibberHome: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var timeZone: String?
    var currency: String?
    /// Tibber's price area code for the home (`SE3`), which is the spot-price zone.
    var priceArea: String?
    /// The grid company that owns the meter. Its fee is on the grid invoice, not in Tibber's price.
    var gridCompany: String?
    /// The main fuse the home is connected with, which the grid company's fixed fee follows and
    /// which caps how much the charger and the house can draw at once.
    var mainFuseSize: Int?

    init(id: String, name: String, timeZone: String? = nil, currency: String? = nil,
         priceArea: String? = nil, gridCompany: String? = nil, mainFuseSize: Int? = nil) {
        self.id = id
        self.name = name
        self.timeZone = timeZone
        self.currency = currency
        self.priceArea = priceArea
        self.gridCompany = gridCompany
        self.mainFuseSize = mainFuseSize
    }

    /// The spot-price zone Tibber reports for this home, when it is one Hisingen reads.
    var elspotZone: ElspotZone? { priceArea.flatMap { ElspotZone(rawValue: $0.uppercased()) } }
}

/// One hour of whole-home consumption from the grid meter, as Tibber reports it.
struct TibberConsumptionHour: Equatable, Sendable {
    var start: Date
    var end: Date
    var kwh: Double
    /// What Tibber billed for the hour's energy, taxes included and the grid fee not. `nil` when Tibber gave none.
    var cost: Double? = nil
    var currency: String? = nil
}

/// Tibber's own API (developer.tibber.com), read with the reader's personal access token. It is
/// the electricity-supplier side of Home Charging: it prices charger sessions, and needs neither a
/// charger nor Home Assistant.
///
/// The token is static, so it is used as it is. A price (`total`) is Tibber's all-in price per
/// kWh: energy, taxes and Tibber's markup, without the grid fee.
struct TibberClient: Sendable {
    static let endpoint = URL(string: "https://api.tibber.com")!

    private let session: BearerSession
    private let now: @Sendable () -> Date

    init(token: String, transport: any HomeAssistantTransport, baseURL: URL = TibberClient.endpoint,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // A static token never expires; the session only supplies the header and the error mapping.
        session = BearerSession(baseURL: baseURL, transport: transport, now: now) { _ in
            BearerSession.Token(value: trimmed, lifetime: 10 * 365 * 86_400)
        }
    }

    // MARK: Homes

    static let homesQuery = """
    { viewer { homes { id timeZone appNickname mainFuseSize address { address1 } \
    meteringPointData { priceAreaCode gridCompany } \
    currentSubscription { priceInfo { current { currency } } } } } }
    """

    /// The homes the token can read. Doubles as the check that the token works.
    func homes() async throws -> [TibberHome] {
        let object = try await run(Self.homesQuery, variables: [:])
        guard let rows = ((object["viewer"] as? [String: Any])?["homes"]) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let address = (row["address"] as? [String: Any])?["address1"] as? String
            let nickname = (row["appNickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let currency = ((((row["currentSubscription"] as? [String: Any])?["priceInfo"]) as? [String: Any])?["current"] as? [String: Any])?["currency"] as? String
            let metering = row["meteringPointData"] as? [String: Any]
            return TibberHome(id: id, name: nickname ?? address ?? id, timeZone: row["timeZone"] as? String, currency: currency,
                              priceArea: (metering?["priceAreaCode"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              gridCompany: (metering?["gridCompany"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              mainFuseSize: row["mainFuseSize"] as? Int)
        }
    }

    // MARK: Prices

    static let priceQuery = """
    query ($homeId: ID!, $last: Int!, $before: String) { viewer { home(id: $homeId) { currentSubscription { \
    priceInfoRange(resolution: QUARTER_HOURLY, last: $last, before: $before) { \
    edges { cursor node { total startsAt level } } } } } } }
    """

    /// The prices still to come. `priceInfoRange` stops at the current slot, so the rest of today and
    /// tomorrow (published in the afternoon) are only here.
    static let upcomingQuery = """
    query ($homeId: ID!) { viewer { home(id: $homeId) { currentSubscription { \
    priceInfo(resolution: QUARTER_HOURLY) { today { total startsAt level } tomorrow { total startsAt level } } } } } }
    """

    /// Whole-home hourly consumption. A page is 744 hours, 31 days.
    static let consumptionQuery = """
    query ($homeId: ID!, $last: Int!, $before: String) { viewer { home(id: $homeId) { \
    consumption(resolution: HOURLY, last: $last, before: $before) { \
    edges { cursor node { from to consumption cost currency } } } } } }
    """
    static let consumptionPageSize = 744
    /// Two pages reach about two months back.
    static let maximumConsumptionPages = 2

    /// A page is 384 quarter-hours, four days.
    static let pageSize = 384
    /// Ten pages reach about forty days back, past the longest session history Hisingen imports.
    static let maximumPages = 10

    /// Quarter-hour import prices covering `[from, to]`. Pages are read back from the newest price
    /// until one reaches `from`, following the cursors Tibber hands back, so nothing depends on how
    /// a cursor is built. Missing slots stay missing: a session priced from a gap is reported as such.
    func prices(homeID: String, from: Date, to: Date) async throws -> [HomePricePoint] {
        var collected: [Date: (price: Double, level: TibberPriceLevel?)] = [:]
        var before: String?
        for _ in 0..<Self.maximumPages {
            var variables: [String: Any] = ["homeId": homeID, "last": Self.pageSize]
            if let before { variables["before"] = before }
            let object = try await run(Self.priceQuery, variables: variables)
            let edges = Self.edges(in: object)
            guard !edges.isEmpty else { break }
            for edge in edges { collected[edge.start] = (edge.price, edge.level) }
            guard let oldest = edges.min(by: { $0.start < $1.start }), oldest.cursor != before else { break }
            if oldest.start <= from { break }
            before = oldest.cursor
        }
        // The range ends at the slot running now. A span that reaches past it also needs the prices
        // Tibber has published for the rest of today and for tomorrow.
        if to > now() {
            for edge in try await upcomingPrices(homeID: homeID) { collected[edge.start] = (edge.price, edge.level) }
        }
        return Self.points(from: collected, from: from, to: to)
    }

    private func upcomingPrices(homeID: String) async throws -> [Edge] {
        let object = try await run(Self.upcomingQuery, variables: ["homeId": homeID])
        let home = (object["viewer"] as? [String: Any])?["home"] as? [String: Any]
        let info = (home?["currentSubscription"] as? [String: Any])?["priceInfo"] as? [String: Any]
        return ["today", "tomorrow"].flatMap { day -> [Edge] in
            ((info?[day] as? [[String: Any]]) ?? []).compactMap { node in
                guard let start = LooseJSON.date(node["startsAt"]), let price = LooseJSON.double(node["total"]), price.isFinite else { return nil }
                return Edge(cursor: "", start: start, price: price,
                            level: (node["level"] as? String).flatMap(TibberPriceLevel.init(rawValue:)))
            }
        }
    }

    private struct Edge {
        var cursor: String
        var start: Date
        var price: Double
        var level: TibberPriceLevel?
    }

    private static func edges(in object: [String: Any]) -> [Edge] {
        let home = (object["viewer"] as? [String: Any])?["home"] as? [String: Any]
        let range = (home?["currentSubscription"] as? [String: Any])?["priceInfoRange"] as? [String: Any]
        let rows = (range?["edges"]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let cursor = row["cursor"] as? String,
                  let node = row["node"] as? [String: Any],
                  let start = LooseJSON.date(node["startsAt"]),
                  let price = LooseJSON.double(node["total"]) else { return nil }
            return Edge(cursor: cursor, start: start, price: price,
                        level: (node["level"] as? String).flatMap(TibberPriceLevel.init(rawValue:)))
        }
    }

    /// Each slot ends where the next begins; the slot length is the usual gap, a quarter-hour when
    /// Tibber sends hourly prices spread over quarter-hour slots.
    static func points(from collected: [Date: (price: Double, level: TibberPriceLevel?)], from: Date, to: Date) -> [HomePricePoint] {
        let sorted = collected.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return [] }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.key.timeIntervalSince($0.key) }.filter { $0 > 0 }.sorted()
        let step = gaps.isEmpty ? 900 : gaps[gaps.count / 2]
        return sorted.compactMap { start, price in
            let end = start.addingTimeInterval(step)
            guard end > from, start < to else { return nil }
            return HomePricePoint(start: start, end: end, pricePerKwh: price.price, level: price.level)
        }
    }

    // MARK: Consumption

    /// Hourly whole-home consumption covering `[from, to]`, read back from the newest hour. Hours the
    /// meter has not reported yet come back without a value and are left out, so a gap stays a gap.
    func consumption(homeID: String, from: Date, to: Date) async throws -> [TibberConsumptionHour] {
        var collected: [Date: TibberConsumptionHour] = [:]
        var before: String?
        for _ in 0..<Self.maximumConsumptionPages {
            var variables: [String: Any] = ["homeId": homeID, "last": Self.consumptionPageSize]
            if let before { variables["before"] = before }
            let object = try await run(Self.consumptionQuery, variables: variables)
            let page = Self.consumptionEdges(in: object)
            guard !page.isEmpty else { break }
            for edge in page { collected[edge.hour.start] = edge.hour }
            guard let oldest = page.min(by: { $0.hour.start < $1.hour.start }), oldest.cursor != before else { break }
            if oldest.hour.start <= from { break }
            before = oldest.cursor
        }
        return collected.values
            .filter { $0.end > from && $0.start < to }
            .sorted { $0.start < $1.start }
    }

    private struct ConsumptionEdge {
        var cursor: String
        var hour: TibberConsumptionHour
    }

    private static func consumptionEdges(in object: [String: Any]) -> [ConsumptionEdge] {
        let home = (object["viewer"] as? [String: Any])?["home"] as? [String: Any]
        let rows = ((home?["consumption"] as? [String: Any])?["edges"]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let cursor = row["cursor"] as? String, let node = row["node"] as? [String: Any],
                  let start = LooseJSON.date(node["from"]), let end = LooseJSON.date(node["to"]), end > start else { return nil }
            // A null `consumption` is an hour without a reading, not an hour of zero.
            guard let kwh = LooseJSON.double(node["consumption"]), kwh.isFinite, kwh >= 0 else { return nil }
            let cost = LooseJSON.double(node["cost"]).flatMap { $0.isFinite ? $0 : nil }
            let currency = (node["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ConsumptionEdge(cursor: cursor, hour: TibberConsumptionHour(start: start, end: end, kwh: kwh, cost: cost, currency: currency))
        }
    }

    // MARK: GraphQL

    /// Sends one query. Tibber answers GraphQL failures with a 200 and an `errors` list, so that
    /// list is read for the three cases a reader can act on.
    private func run(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await session.data("POST", path: "/v1-beta/gql", jsonBody: body)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DirectChargerError.malformedResponse
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            throw Self.error(from: errors)
        }
        guard let payload = root["data"] as? [String: Any] else { throw DirectChargerError.malformedResponse }
        return payload
    }

    static func error(from errors: [[String: Any]]) -> DirectChargerError {
        let first = errors.first ?? [:]
        let code = ((first["extensions"] as? [String: Any])?["code"] as? String) ?? ""
        let message = (first["message"] as? String) ?? ""
        let haystack = "\(code) \(message)".lowercased()
        if haystack.contains("rate_limit") || haystack.contains("rate limit") { return .rateLimited(retryAfter: nil) }
        if haystack.contains("unauthenticated") || haystack.contains("unauthorized") || haystack.contains("invalid token")
            || haystack.contains("access token") { return .unauthorized }
        return .rejected(status: 200, message: String(message.prefix(240)))
    }
}
