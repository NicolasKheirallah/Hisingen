import Foundation

/// Zaptec's cloud API (docs.zaptec.com), used with the owner's Zaptec account.
///
/// Sign-in is the OAuth password grant at `/oauth/token`: a one-hour bearer token and no refresh
/// token, so Hisingen signs in again when it ends. Zaptec asks clients to reuse a token, to stay
/// well under 10 requests a second, and not to poll aggressively; a poll here is one request a
/// minute. Zaptec says the password grant will be phased out for the code grant, which is why
/// the sign-in sits in one place.
struct ZaptecProvider: DirectChargerProvider {
    let source = ChargerSource.zaptec
    let sessionLookback: TimeInterval = 30 * 86_400

    private let session: BearerSession

    /// State IDs from Zaptec's State Observation Reference.
    enum State {
        static let operationMode = 710
        static let totalChargePowerWatts = 513
        static let sessionEnergyKwh = 553
        static let chargeCurrentSet = 708
        static let finalStopActive = 718
        static let nextScheduleEvent = 763
        static let isOnline = -2
        static let communicationMode = 150
        static let voltagePhase1 = 501
        static let voltagePhase2 = 502
        static let voltagePhase3 = 503
        static let currentPhase1 = 507
        static let currentPhase2 = 508
        static let currentPhase3 = 509
        static let setPhases = 519
        static let cableType = 714
    }

    /// Command IDs from Zaptec's `sendCommand` documentation.
    enum Command {
        static let pause = 506
        static let resume = 507
    }

    init(credentials: DirectChargerCredentials, transport: any HomeAssistantTransport,
         baseURL: URL = URL(string: "https://api.zaptec.com")!, now: @escaping @Sendable () -> Date = { Date() }) {
        session = BearerSession(baseURL: baseURL, transport: transport, now: now) { transport in
            try await Self.signIn(credentials, baseURL: baseURL, transport: transport)
        }
    }

    // MARK: Sign in

    static func signIn(_ credentials: DirectChargerCredentials, baseURL: URL,
                       transport: any HomeAssistantTransport) async throws -> BearerSession.Token {
        var request = try BearerSession.request(baseURL: baseURL, method: "POST", path: "/oauth/token")
        request.httpBody = Data(formBody([
            ("grant_type", "password"),
            ("username", credentials.username.trimmingCharacters(in: .whitespaces)),
            ("password", credentials.password),
            ("scope", "openid")
        ]).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await BearerSession.send(request, through: transport)
        switch response.statusCode {
        case 200..<300: break
        // `invalid_grant` arrives as a 400; either way the account or password was not accepted.
        case 400, 401, 403: throw DirectChargerError.unauthorized
        default: try BearerSession.check(response, data: data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty else {
            throw DirectChargerError.malformedResponse
        }
        return BearerSession.Token(value: token, lifetime: LooseJSON.double(object["expires_in"]) ?? 3_600)
    }

    static func formBody(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    // MARK: Chargers

    func chargers() async throws -> [DirectChargerSummary] {
        let data = try await session.data("GET", path: "/api/chargers", query: [URLQueryItem(name: "PageSize", value: "100")])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DirectChargerError.malformedResponse
        }
        let rows = (Self.value(object, "data") as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = Self.value(row, "id") as? String, !id.isEmpty else { return nil }
            if LooseJSON.bool(Self.value(row, "active")) == false { return nil }
            let name = (Self.value(row, "name") as? String) ?? (Self.value(row, "deviceId") as? String) ?? id
            return DirectChargerSummary(id: id, name: name, siteName: Self.value(row, "installationName") as? String,
                                        isOnline: LooseJSON.bool(Self.value(row, "isOnline")))
        }
    }

    // MARK: Telemetry

    func telemetry(chargerID: String, now: Date) async throws -> HomeChargerTelemetry {
        let data = try await session.data("GET", path: "/api/chargers/\(EaseeProvider.pathComponent(chargerID))/state")
        return try Self.telemetry(from: data, now: now)
    }

    /// Reads Zaptec's state list. As with Easee, a state's own timestamp is when it last changed,
    /// not when Zaptec last vouched for it, so a reading is stamped with the poll time while the
    /// charger is online. A charger Zaptec reports offline is `unavailable`.
    static func telemetry(from data: Data, now: Date) throws -> HomeChargerTelemetry {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        var values: [Int: String] = [:]
        for row in rows {
            guard let id = LooseJSON.double(value(row, "stateId")).map({ Int($0) }) else { continue }
            values[id] = (value(row, "valueAsString") as? String) ?? ""
        }

        var telemetry = HomeChargerTelemetry()
        guard let mode = values[State.operationMode].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            return telemetry
        }
        if let online = values[State.isOnline], LooseJSON.bool(online) == false {
            telemetry.status = HomeChargerReading(value: .unavailable, timestamp: now)
            return telemetry
        }

        let finalStop = values[State.finalStopActive].flatMap { LooseJSON.bool($0) }
        let scheduled = isScheduled(values[State.nextScheduleEvent], now: now)
        let status = ZaptecStatus.map(operationMode: mode, finalStopActive: finalStop, hasScheduledEvent: scheduled)
        telemetry.status = HomeChargerReading(value: status, timestamp: now)
        if let watts = values[State.totalChargePowerWatts].flatMap({ LooseJSON.double($0) }) {
            telemetry.powerKw = HomeChargerReading(value: max(0, watts) / 1_000, timestamp: now)
        }
        if let kwh = values[State.sessionEnergyKwh].flatMap({ LooseJSON.double($0) }) {
            telemetry.sessionEnergyKwh = HomeChargerReading(value: max(0, kwh), timestamp: now)
        }
        if let amps = values[State.chargeCurrentSet].flatMap({ LooseJSON.double($0) }) {
            telemetry.currentLimitAmps = HomeChargerReading(value: amps, timestamp: now)
        }
        if let phases = Self.phases(from: values) {
            telemetry.phases = HomeChargerReading(value: phases, timestamp: now)
        }
        if let cable = values[State.cableType].flatMap({ LooseJSON.double($0) }), cable > 0 {
            telemetry.cableLimitAmps = HomeChargerReading(value: cable, timestamp: now)
        }
        if let phaseSetting = Self.phaseMode(values[State.setPhases]) {
            telemetry.phaseMode = HomeChargerReading(value: phaseSetting, timestamp: now)
        }
        if let network = Self.network(values[State.communicationMode]) {
            telemetry.network = HomeChargerReading(value: network, timestamp: now)
        }
        telemetry.chargingEnabled = HomeChargerReading(value: status.isChargingEnabled, timestamp: now)
        return telemetry
    }

    /// Zaptec reports the voltage and the current of each phase as two states (docs.zaptec.com,
    /// State Observation Reference: 501 to 503 and 507 to 509). A phase missing either reading is
    /// left out; pairing it with a neighbour would invent one.
    static func phases(from values: [Int: String]) -> [HomeChargerPhase]? {
        var phases: [HomeChargerPhase] = []
        for (voltsID, ampsID) in [(State.voltagePhase1, State.currentPhase1),
                                  (State.voltagePhase2, State.currentPhase2),
                                  (State.voltagePhase3, State.currentPhase3)] {
            guard let volts = values[voltsID].flatMap({ LooseJSON.double($0) }),
                  let amps = values[ampsID].flatMap({ LooseJSON.double($0) }),
                  volts.isFinite, amps.isFinite, volts >= 0, amps >= 0 else { continue }
            phases.append(HomeChargerPhase(volts: volts, amps: amps))
        }
        return phases.isEmpty ? nil : phases
    }

    /// State 519, SetPhases. Zaptec's constants map every value to a phase set
    /// (api.zaptec.com/api/constants, PhaseIdMap): 1, 2, 3, 5, 6 and 8 are one phase on the TN or
    /// the IT grid, 4 and 9 are all three. A value outside the table reads as `nil`, not a guess.
    static func phaseMode(_ raw: String?) -> HomeChargerPhaseMode? {
        guard let value = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        switch value {
        case 1, 2, 3, 5, 6, 8: return .singlePhase
        case 4, 9: return .threePhase
        default: return nil
        }
    }

    /// State 150, Network communication mode: "Wifi, LTE, PLC, or none" (docs.zaptec.com, State
    /// Observation Reference). PLC has no wording of its own, so it is left out with any value the
    /// documentation does not name.
    static func network(_ raw: String?) -> HomeChargerNetwork? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wifi": return .wifi
        case "lte": return .mobile
        case "none": return HomeChargerNetwork.none
        default: return nil
        }
    }

    /// Whether Zaptec holds a schedule event. The value is a time when there is one; an empty
    /// value or a time already past means there is none.
    static func isScheduled(_ raw: String?, now: Date) -> Bool {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "0" else { return false }
        if let date = DirectChargerDates.parse(text) { return date > now }
        return true
    }

    // MARK: Commands

    func send(_ kind: HomeChargerCommandKind, chargerID: String, telemetry: HomeChargerTelemetry) async throws {
        // Zaptec has a pause and a resume and no "start": a charge that is not paused or scheduled
        // has nothing to resume, and Zaptec says so. That answer is shown to the reader as it is.
        let command = kind == .pause ? Command.pause : Command.resume
        let data = try await session.data("POST", path: "/api/chargers/\(EaseeProvider.pathComponent(chargerID))/sendCommand/\(command)")
        try Self.checkCommandAnswer(data)
    }

    /// A command refused because of the charger's state can arrive inside a 200 as a `Code`.
    static func checkCommandAnswer(_ data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = LooseJSON.double(value(object, "code")).map({ Int($0) }), code != 0, code != 200 else { return }
        throw DirectChargerError.rejected(status: code, message: (value(object, "message") as? String) ?? "")
    }

    // MARK: Sessions

    func sessions(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate] {
        var candidates: [HomeChargingSessionCandidate] = []
        var cursor: String?
        // Bounded: a page is 200 sessions, so ten pages is far more than a home charger makes.
        for _ in 0..<10 {
            var query = [
                URLQueryItem(name: "From", value: DirectChargerDates.format(from)),
                URLQueryItem(name: "To", value: DirectChargerDates.format(to)),
                URLQueryItem(name: "ChargerId", value: chargerID),
                URLQueryItem(name: "PageSize", value: "200"),
                URLQueryItem(name: "Order", value: "0")
            ]
            if let cursor { query.append(URLQueryItem(name: "Cursor", value: cursor)) }
            let data = try await session.data("GET", path: "/api/sessions/archived", query: query)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw DirectChargerError.malformedResponse
            }
            candidates += Self.candidates(from: (Self.value(object, "sessions") as? [[String: Any]]) ?? [], chargerID: chargerID)
            guard LooseJSON.bool(Self.value(object, "hasMore")) == true,
                  let next = Self.value(object, "cursor") as? String, !next.isEmpty else { break }
            cursor = next
        }
        return candidates
    }

    static func candidates(from list: [[String: Any]], chargerID: String) -> [HomeChargingSessionCandidate] {
        list.compactMap { item in
            guard let id = value(item, "id") as? String, !id.isEmpty,
                  LooseJSON.bool(value(item, "voided")) != true,
                  // A session that Zaptec replaced with another one would count twice.
                  (value(item, "replacedBySessionId") as? String)?.isEmpty ?? true,
                  let start = LooseJSON.date(value(item, "startDateTime")),
                  let end = LooseJSON.date(value(item, "endDateTime")), end > start,
                  let kwh = LooseJSON.double(value(item, "energy")), kwh >= HomeSessionReconstructor.minimumSessionKwh else { return nil }
            return HomeChargingSessionCandidate(
                key: HomeChargingSessionCandidate.vendorKey(chargerID: chargerID, sessionID: id),
                keyKind: .vendorSessionID, chargerID: chargerID, startedAt: start, endedAt: end,
                energyKwh: kwh, energySource: "zaptec_session_api", measuredAt: end,
                intervals: intervals(from: value(item, "energyDetails") as? [[String: Any]], start: start, end: end))
        }
    }

    /// Cumulative readings become the energy of each stretch between them. The stretch before the
    /// first reading is not invented: its energy is whatever the first reading already holds.
    static func intervals(from details: [[String: Any]]?, start: Date, end: Date) -> [HomeEnergyInterval] {
        let readings = (details ?? []).compactMap { row -> (at: Date, kwh: Double)? in
            guard let at = LooseJSON.date(value(row, "timestamp")), let kwh = LooseJSON.double(value(row, "energy")) else { return nil }
            return (at, kwh)
        }.sorted { $0.at < $1.at }
        guard !readings.isEmpty else { return [] }
        var result: [HomeEnergyInterval] = []
        var previous: (at: Date, kwh: Double) = (start, 0)
        for reading in readings {
            let delta = reading.kwh - previous.kwh
            if delta > 0, reading.at > previous.at, reading.at <= end.addingTimeInterval(60) {
                result.append(HomeEnergyInterval(start: previous.at, end: reading.at, kwh: delta))
            }
            previous = reading
        }
        return result
    }

    /// Zaptec's own documentation is PascalCase in places and its schema camelCase; read either.
    static func value(_ object: [String: Any], _ key: String) -> Any? {
        if let direct = object[key] { return direct }
        return object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

/// Zaptec's charger operation mode (state 710) with the final-stop flag (718) and any schedule
/// event (763), folded into Hisingen's statuses.
enum ZaptecStatus {
    static func map(operationMode: Int, finalStopActive: Bool?, hasScheduledEvent: Bool) -> HomeChargerStatus {
        switch operationMode {
        case 1: return .unplugged
        case 2: return hasScheduledEvent ? .delayedStart : .pluggedIn
        case 3: return .charging
        case 5:
            // 5 with the flag set is a pause or a schedule; 5 without it is a car that is full.
            if finalStopActive == true { return hasScheduledEvent ? .delayedStart : .pluggedIn }
            return .finished
        default: return .unrecognised("operation_mode_\(operationMode)")
        }
    }
}
