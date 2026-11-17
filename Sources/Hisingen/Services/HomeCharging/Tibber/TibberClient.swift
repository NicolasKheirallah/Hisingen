import Foundation

/// A Tibber home the token can read, as the reader picks it during setup.
struct TibberHome: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var timeZone: String?
    var currency: String?
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

    init(token: String, transport: any HomeAssistantTransport, baseURL: URL = TibberClient.endpoint,
         now: @escaping @Sendable () -> Date = { Date() }) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // A static token never expires; the session only supplies the header and the error mapping.
        session = BearerSession(baseURL: baseURL, transport: transport, now: now) { _ in
            BearerSession.Token(value: trimmed, lifetime: 10 * 365 * 86_400)
        }
    }

    // MARK: Homes

    static let homesQuery = """
    { viewer { homes { id timeZone appNickname address { address1 } \
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
            return TibberHome(id: id, name: nickname ?? address ?? id, timeZone: row["timeZone"] as? String, currency: currency)
        }
    }

    // MARK: Prices

    static let priceQuery = """
    query ($homeId: ID!, $last: Int!, $before: String) { viewer { home(id: $homeId) { currentSubscription { \
    priceInfo { range(resolution: QUARTER_HOURLY, last: $last, before: $before) { \
    edges { cursor node { total startsAt } } } } } } } }
    """

    /// A page is 384 quarter-hours, four days.
    static let pageSize = 384
    /// Ten pages reach about forty days back, past the longest session history Hisingen imports.
    static let maximumPages = 10

    /// Quarter-hour import prices covering `[from, to]`. Pages are read back from the newest price
    /// until one reaches `from`, following the cursors Tibber hands back, so nothing depends on how
    /// a cursor is built. Missing slots stay missing: a session priced from a gap is reported as such.
    func prices(homeID: String, from: Date, to: Date) async throws -> [HomePricePoint] {
        var collected: [Date: Double] = [:]
        var before: String?
        for _ in 0..<Self.maximumPages {
            var variables: [String: Any] = ["homeId": homeID, "last": Self.pageSize]
            if let before { variables["before"] = before }
            let object = try await run(Self.priceQuery, variables: variables)
            let edges = Self.edges(in: object)
            guard !edges.isEmpty else { break }
            for edge in edges { collected[edge.start] = edge.price }
            guard let oldest = edges.min(by: { $0.start < $1.start }), oldest.cursor != before else { break }
            if oldest.start <= from { break }
            before = oldest.cursor
        }
        return Self.points(from: collected, from: from, to: to)
    }

    private struct Edge {
        var cursor: String
        var start: Date
        var price: Double
    }

    private static func edges(in object: [String: Any]) -> [Edge] {
        let home = (object["viewer"] as? [String: Any])?["home"] as? [String: Any]
        let info = (home?["currentSubscription"] as? [String: Any])?["priceInfo"] as? [String: Any]
        let rows = ((info?["range"] as? [String: Any])?["edges"]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let cursor = row["cursor"] as? String,
                  let node = row["node"] as? [String: Any],
                  let start = LooseJSON.date(node["startsAt"]),
                  let price = LooseJSON.double(node["total"]) else { return nil }
            return Edge(cursor: cursor, start: start, price: price)
        }
    }

    /// Each slot ends where the next begins; the slot length is the usual gap, a quarter-hour when
    /// Tibber sends hourly prices spread over quarter-hour slots.
    static func points(from collected: [Date: Double], from: Date, to: Date) -> [HomePricePoint] {
        let sorted = collected.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return [] }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.key.timeIntervalSince($0.key) }.filter { $0 > 0 }.sorted()
        let step = gaps.isEmpty ? 900 : gaps[gaps.count / 2]
        return sorted.compactMap { start, price in
            let end = start.addingTimeInterval(step)
            guard end > from, start < to else { return nil }
            return HomePricePoint(start: start, end: end, pricePerKwh: price)
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
