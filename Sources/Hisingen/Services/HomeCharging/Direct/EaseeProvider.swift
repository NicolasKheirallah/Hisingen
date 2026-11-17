import Foundation

/// Easee's public cloud API (developer.easee.com), used with the owner's own Easee account.
///
/// Authentication is a username and password exchanged for a one-hour bearer token. State comes
/// from the observations endpoint, commands from `/api/chargers/{id}/commands/...`, and finished
/// sessions from the charger's session list. Two limits shape the polling: observations allow 100
/// requests per five minutes, and the session endpoints 10 per hour.
struct EaseeProvider: DirectChargerProvider {
    let source = ChargerSource.easee
    let sessionLookback: TimeInterval = 30 * 86_400

    private let session: BearerSession
    private let baseURL: URL

    /// Observation IDs read on every poll (developer.easee.com, Charger Observation IDs).
    enum Observation {
        static let opMode = 109
        static let cableLocked = 103
        static let totalPowerKw = 120
        static let sessionEnergyKwh = 121
        static let lifetimeEnergyKwh = 124
        static let dynamicChargerCurrent = 48
        static let reasonForNoCurrent = 96
        static let connectedToCloud = 250
        static let all = [opMode, cableLocked, totalPowerKw, sessionEnergyKwh, lifetimeEnergyKwh,
                          dynamicChargerCurrent, reasonForNoCurrent, connectedToCloud]
    }

    init(credentials: DirectChargerCredentials, transport: any HomeAssistantTransport,
         baseURL: URL = URL(string: "https://api.easee.com")!, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        session = BearerSession(baseURL: baseURL, transport: transport, now: now) { transport in
            try await Self.signIn(credentials, baseURL: baseURL, transport: transport)
        }
    }

    // MARK: Sign in

    static func signIn(_ credentials: DirectChargerCredentials, baseURL: URL,
                       transport: any HomeAssistantTransport) async throws -> BearerSession.Token {
        var request = try BearerSession.request(baseURL: baseURL, method: "POST", path: "/api/accounts/login")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "userName": credentials.username.trimmingCharacters(in: .whitespaces),
            "password": credentials.password
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await BearerSession.send(request, through: transport)
        switch response.statusCode {
        case 200..<300: break
        // A refused login is a wrong account or password however the vendor words it.
        case 400, 401, 403, 404: throw DirectChargerError.unauthorized
        default: try BearerSession.check(response, data: data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = object["accessToken"] as? String, !token.isEmpty else {
            throw DirectChargerError.malformedResponse
        }
        return BearerSession.Token(value: token, lifetime: LooseJSON.double(object["expiresIn"]) ?? 3_600)
    }

    // MARK: Chargers

    func chargers() async throws -> [DirectChargerSummary] {
        let data = try await session.data("GET", path: "/api/chargers")
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            // An Equalizer (product code 1000) is a meter, not something that charges a car.
            if let code = LooseJSON.double(item["productCode"]), Int(code) == 1000 { return nil }
            return DirectChargerSummary(id: id, name: (item["name"] as? String) ?? id, siteName: nil, isOnline: nil)
        }
    }

    // MARK: Telemetry

    func telemetry(chargerID: String, now: Date) async throws -> HomeChargerTelemetry {
        let ids = Observation.all.map(String.init).joined(separator: ",")
        let data = try await session.data("GET", path: "/state/\(Self.pathComponent(chargerID))/observations",
                                          query: [URLQueryItem(name: "ids", value: ids)])
        return try Self.telemetry(from: data, now: now)
    }

    /// Builds the telemetry from an observations answer.
    ///
    /// An observation carries the time the charger last changed it, which for a status that
    /// stays "disconnected" for a week is a week ago. That is not staleness. What the card needs
    /// is when the cloud last vouched for the value, so a reading is stamped with the time of the
    /// poll, provided the charger is online. A charger the cloud reports offline is `unavailable`.
    static func telemetry(from data: Data, now: Date) throws -> HomeChargerTelemetry {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        // The documented answer wraps the list in `observations`; a bare list is read the same way.
        let rows: [[String: Any]]
        if let object = parsed as? [String: Any], let list = object["observations"] as? [[String: Any]] {
            rows = list
        } else if let list = parsed as? [[String: Any]] {
            rows = list
        } else {
            throw DirectChargerError.malformedResponse
        }
        var values: [Int: Any] = [:]
        for row in rows {
            guard let id = LooseJSON.double(row["id"]).map({ Int($0) }) else { continue }
            values[id] = row["value"]
        }

        var telemetry = HomeChargerTelemetry()
        let opMode = LooseJSON.double(values[Observation.opMode]).map { Int($0) }
        let cloud = LooseJSON.bool(values[Observation.connectedToCloud])
        guard let opMode else { return telemetry }

        if opMode == 0 || cloud == false {
            telemetry.status = HomeChargerReading(value: .unavailable, timestamp: now)
            return telemetry
        }

        let reason = LooseJSON.double(values[Observation.reasonForNoCurrent]).map { Int($0) }
        let dynamicCurrent = LooseJSON.double(values[Observation.dynamicChargerCurrent])
        let status = EaseeStatus.map(opMode: opMode, reasonForNoCurrent: reason, dynamicCurrentAmps: dynamicCurrent)
        telemetry.status = HomeChargerReading(value: status, timestamp: now)
        if let power = LooseJSON.double(values[Observation.totalPowerKw]) {
            telemetry.powerKw = HomeChargerReading(value: max(0, power), timestamp: now)
        }
        if let energy = LooseJSON.double(values[Observation.sessionEnergyKwh]) {
            telemetry.sessionEnergyKwh = HomeChargerReading(value: max(0, energy), timestamp: now)
        }
        if let lifetime = LooseJSON.double(values[Observation.lifetimeEnergyKwh]) {
            telemetry.lifetimeEnergyKwh = HomeChargerReading(value: max(0, lifetime), timestamp: now)
        }
        if let dynamicCurrent {
            telemetry.currentLimitAmps = HomeChargerReading(value: dynamicCurrent, timestamp: now)
        }
        if let locked = LooseJSON.bool(values[Observation.cableLocked]) {
            telemetry.cableLocked = HomeChargerReading(value: locked, timestamp: now)
        }
        telemetry.chargingEnabled = HomeChargerReading(value: status.isChargingEnabled, timestamp: now)
        return telemetry
    }

    // MARK: Commands

    func send(_ kind: HomeChargerCommandKind, chargerID: String, telemetry: HomeChargerTelemetry) async throws {
        let base = "/api/chargers/\(Self.pathComponent(chargerID))/commands"
        switch kind {
        case .pause:
            _ = try await session.data("POST", path: "\(base)/pause_charging")
        case .start:
            if telemetry.status?.value == .delayedStart {
                // A schedule is holding the start; this overrides it for the current session.
                _ = try await session.data("POST", path: "\(base)/override_schedule")
                return
            }
            do {
                // Clears the zero limit that a pause sets, which is what most "start" presses undo.
                _ = try await session.data("POST", path: "\(base)/resume_charging")
            } catch DirectChargerError.rejected {
                // A charger that wants authorisation answers a resume with a refusal; start it instead.
                _ = try await session.data("POST", path: "\(base)/start_charging")
            }
        }
    }

    // MARK: Sessions

    func sessions(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate] {
        let path = "/api/sessions/charger/\(Self.pathComponent(chargerID))/sessions/\(DirectChargerDates.format(from))/\(DirectChargerDates.format(to))"
        let data = try await session.data("GET", path: path)
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        return Self.candidates(from: list, chargerID: chargerID)
    }

    static func candidates(from list: [[String: Any]], chargerID: String) -> [HomeChargingSessionCandidate] {
        list.compactMap { item in
            // A session that has not ended yet is picked up by a later import.
            guard LooseJSON.bool(item["isComplete"]) == true, let id = LooseJSON.double(item["id"]).map({ Int($0) }),
                  let kwh = LooseJSON.double(item["kiloWattHours"]), kwh >= HomeSessionReconstructor.minimumSessionKwh else { return nil }
            // The energy window is the better span for matching and pricing; the plug window is the fallback.
            guard let start = LooseJSON.date(item["firstEnergyTransferPeriodStarted"]) ?? LooseJSON.date(item["carConnected"]),
                  let end = LooseJSON.date(item["lastEnergyTransferPeriodEnd"]) ?? LooseJSON.date(item["carDisconnected"]),
                  end > start else { return nil }
            return HomeChargingSessionCandidate(
                key: HomeChargingSessionCandidate.vendorKey(chargerID: chargerID, sessionID: String(id)),
                keyKind: .vendorSessionID, chargerID: chargerID, startedAt: start, endedAt: end,
                energyKwh: kwh, energySource: "easee_session_api", measuredAt: end)
        }
    }

    static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? text
    }
}

/// Easee's operating mode (observation 109) with the reason a connected car gets no current
/// (observation 96) and the dynamic limit (observation 48), folded into Hisingen's statuses.
enum EaseeStatus {
    /// ReasonForNoCurrent values that mean a load balancer is holding the charger back
    /// (developer.easee.com, Enumerations): circuit and fuse limits, the queue, and the
    /// circuit-level balancing codes.
    static let loadBalancingReasons: Set<Int> = [1, 2, 3, 4, 5, 6, 50, 51, 52]

    static func map(opMode: Int, reasonForNoCurrent: Int?, dynamicCurrentAmps: Double?) -> HomeChargerStatus {
        switch opMode {
        case 0: return .unavailable
        case 1: return .unplugged
        case 2:
            // Awaiting start: the car is connected and nothing is flowing. Why decides what it is.
            if let reason = reasonForNoCurrent {
                if loadBalancingReasons.contains(reason) { return .waitingForPower }
                if reason == 54 { return .delayedStart }
            }
            // A pause sets the dynamic limit to zero. The car is plugged in and held, not waiting for anyone.
            if let dynamicCurrentAmps, dynamicCurrentAmps <= 0 { return .pluggedIn }
            return .waitingForVehicle
        case 3: return .charging
        case 4: return .finished
        case 5: return .error
        case 6: return .waitingForVehicle
        case 7, 8: return .pluggedIn
        default: return .unrecognised("op_mode_\(opMode)")
        }
    }
}
