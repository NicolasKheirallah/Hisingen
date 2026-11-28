import Foundation

/// NexBlue's owner OpenAPI uses a separate refresh grant for myNexBlue accounts.
struct NexBlueProvider: DirectChargerProvider {
    let source = ChargerSource.nexBlue
    let sessionLookback: TimeInterval = 30 * 86_400
    private let session: BearerSession

    private static let baseURL = URL(string: "https://api.nexblue.com")!
    private static let root = "/third_party/openapi"

    init(transport: any HomeAssistantTransport, now: @escaping @Sendable () -> Date = Date.init,
         initialToken: BearerSession.Token? = nil, authenticate: @escaping BearerSession.Authenticate) {
        session = BearerSession(baseURL: Self.baseURL, transport: transport, now: now,
                                initialToken: initialToken, checkResponse: Self.check, authenticate: authenticate)
    }

    static func signIn(_ credentials: DirectChargerCredentials, transport: any HomeAssistantTransport)
    async throws -> (chargers: [DirectChargerSummary], refreshToken: String) {
        let tokens = try await grant("login", fields: ["username": credentials.username.trimmingCharacters(in: .whitespaces),
                                                       "password": credentials.password, "account_type": 0],
                                     invalidGrantCode: 1501, transport: transport)
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw DirectChargerError.malformedResponse
        }
        let provider = NexBlueProvider(transport: transport, initialToken: tokens.bearer) { _ in
            throw DirectChargerError.unauthorized
        }
        return (try await provider.chargers(), refreshToken)
    }

    static func refresh(_ token: String, transport: any HomeAssistantTransport)
    async throws -> (bearer: BearerSession.Token, rotatedRefreshToken: String?) {
        let tokens = try await grant("refresh_token", fields: ["refresh_token": token, "account_type": 0],
                                     invalidGrantCode: 1502, transport: transport)
        return (tokens.bearer, tokens.refreshToken.flatMap { $0.isEmpty ? nil : $0 })
    }

    func chargers() async throws -> [DirectChargerSummary] {
        let data = try await session.data("GET", path: Self.root + "/chargers")
        let list = try Self.decode(List<Charger>.self, from: data)
        var summaries: [DirectChargerSummary] = []
        for item in list.data where !item.serialNumber.isEmpty {
            try Task.checkCancellation()
            let fallback = L10n.format("NexBlue %@", item.serialNumber)
            let model: String?
            do {
                model = try await productName(chargerID: item.serialNumber)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                model = nil
            }
            summaries.append(DirectChargerSummary(id: item.serialNumber, name: model ?? fallback, role: item.role))
        }
        // Two chargers of one model would otherwise read the same in the pairing list. The serial
        // is already the identity; a short tail is enough to tell them apart.
        let counts = Dictionary(grouping: summaries, by: \.name).mapValues { $0.count }
        for index in summaries.indices where (counts[summaries[index].name] ?? 0) > 1 {
            summaries[index].name += " · " + String(summaries[index].id.suffix(4))
        }
        return summaries
    }

    /// The model name, read from the charger detail. Best effort: a detail the account cannot read
    /// leaves the serial in the label rather than failing the sign-in.
    private func productName(chargerID: String) async throws -> String? {
        let data = try await session.data("GET", path: Self.chargerPath(chargerID))
        guard let detail = try? Self.decode(ChargerProfile.self, from: data) else { return nil }
        let name = detail.productName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    func telemetry(chargerID: String, now: Date) async throws -> HomeChargerTelemetry {
        let data: Data
        do {
            data = try await session.data("GET", path: Self.commandPath(chargerID, "status"))
        } catch DirectChargerError.chargerOffline {
            return HomeChargerTelemetry(status: .init(value: .unavailable, timestamp: now))
        }
        let status = try Self.decode(Status.self, from: data)
        let state: HomeChargerStatus
        switch status.chargingState {
        case 0: state = .unplugged
        case 1: state = .pluggedIn
        case 2: state = .charging
        case 3: state = .finished
        case 4: state = .error
        case 5: state = .waitingForPower
        case 6: state = .delayedStart
        case 7: state = .waitingForVehicle
        default: state = .unrecognised(String(status.chargingState))
        }
        func reading(_ value: Double?) -> HomeChargerReading<Double>? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return HomeChargerReading(value: value, timestamp: now)
        }
        return HomeChargerTelemetry(
            status: HomeChargerReading(value: state, timestamp: now),
            powerKw: reading(status.power), sessionEnergyKwh: reading(status.energy),
            lifetimeEnergyKwh: reading(status.lifetimeEnergy), currentLimitAmps: reading(status.currentLimit),
            chargingEnabled: HomeChargerReading(value: state.isChargingEnabled && status.isDisable != true, timestamp: now),
            isDisabled: status.isDisable.map { HomeChargerReading(value: $0, timestamp: now) },
            cableLocked: status.isLock.map { HomeChargerReading(value: $0, timestamp: now) },
            phases: Self.phases(status, now: now),
            cableLimitAmps: reading(status.cableCurrentLimit.map(Double.init)).flatMap { $0.value > 0 ? $0 : nil },
            circuitFuseAmps: reading(status.circuitFuse.map(Double.init)).flatMap { $0.value > 0 ? $0 : nil },
            phaseMode: Self.phaseMode(status.phaseCharging).map { HomeChargerReading(value: $0, timestamp: now) },
            network: Self.network(status.networkStatus).map { HomeChargerReading(value: $0, timestamp: now) }
        )
    }

    private static func phases(_ status: Status, now: Date) -> HomeChargerReading<[HomeChargerPhase]>? {
        let volts = status.voltageList ?? []
        let amps = status.currentList ?? []
        let phases = zip(volts, amps).compactMap { volts, amps -> HomeChargerPhase? in
            guard volts.isFinite, amps.isFinite, volts >= 0, amps >= 0 else { return nil }
            return HomeChargerPhase(volts: volts, amps: amps)
        }
        return phases.isEmpty ? nil : HomeChargerReading(value: phases, timestamp: now)
    }

    private static func phaseMode(_ code: Int?) -> HomeChargerPhaseMode? {
        switch code {
        case 0: return .adaptive
        case 1: return .singlePhase
        case 2: return .threePhase
        default: return nil
        }
    }

    private static func network(_ code: Int?) -> HomeChargerNetwork? {
        switch code {
        case 0: return HomeChargerNetwork.none
        case 1: return .wifi
        case 2: return .mobile
        case 3: return .ethernet
        default: return nil
        }
    }

    func send(_ kind: HomeChargerCommandKind, chargerID: String, telemetry: HomeChargerTelemetry) async throws {
        let action = kind == .start ? "start_charging" : "stop_charging"
        let data = try await session.data("POST", path: Self.commandPath(chargerID, action), jsonBody: Data("{}".utf8))
        let result = try Self.decode(CommandResult.self, from: data).code
        switch result {
        case 0: return
        case 2: throw DirectChargerError.forbidden
        case 3:
            throw DirectChargerError.rejected(status: 200, message: L10n.text("The charger's safety self-test failed."))
        case 4:
            throw DirectChargerError.rejected(status: 200, message: L10n.text("Charging is disabled on this charger."))
        case 5:
            throw DirectChargerError.rejected(status: 200, message: L10n.text("Another user is using this charger."))
        default: throw DirectChargerError.rejected(status: 200, message: "")
        }
    }

    func sessions(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate] {
        var start = from
        var candidates: [HomeChargingSessionCandidate] = []
        while start < to {
            let end = min(start.addingTimeInterval(sessionLookback - 86_400), to)
            let batch = try await sessionBatch(chargerID: chargerID, from: start.addingTimeInterval(-86_400), to: end)
            candidates += batch.filter { $0.endedAt >= start && (end == to || $0.endedAt < end) }
            start = end
        }
        return await withHourlyProfiles(candidates, chargerID: chargerID)
    }

    /// The session list gives each session's total only. The charger's hourly energy says when it
    /// arrived, so a session is priced for the hours that drew energy rather than for every hour the
    /// cable was in. Best effort: without the readings a session keeps its total and is priced as an
    /// estimate, as before.
    private func withHourlyProfiles(_ candidates: [HomeChargingSessionCandidate], chargerID: String) async -> [HomeChargingSessionCandidate] {
        guard let first = candidates.map(\.startedAt).min(), let last = candidates.map(\.endedAt).max() else { return candidates }
        guard let hours = try? await hourlyEnergy(chargerID: chargerID, from: first, to: last), !hours.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard candidate.intervals.isEmpty,
                  let intervals = HomeEnergyProfile.intervals(from: hours, startedAt: candidate.startedAt,
                                                              endedAt: candidate.endedAt, energyKwh: candidate.energyKwh)
            else { return candidate }
            var profiled = candidate
            profiled.intervals = intervals
            profiled.energyProfileNote = HomeEnergyProfile.note
            return profiled
        }
    }

    /// `GET /measurement/chargers/{id}`: energy per UTC hour across all sessions, only for the hours
    /// that drew any. The API allows 60 days a request.
    func hourlyEnergy(chargerID: String, from: Date, to: Date) async throws -> [HomeEnergyProfile.Hour] {
        let path = Self.root + "/measurement/chargers/" + Self.pathComponent(chargerID)
        let window: TimeInterval = 59 * 86_400
        var hours: [HomeEnergyProfile.Hour] = []
        var start = from
        while start < to {
            try Task.checkCancellation()
            let end = min(start.addingTimeInterval(window), to)
            let query = [
                URLQueryItem(name: "from_date", value: DirectChargerDates.format(start)),
                URLQueryItem(name: "to_date", value: DirectChargerDates.format(end)),
                URLQueryItem(name: "granularity", value: "hourly")
            ]
            let data = try await session.data("GET", path: path, query: query)
            hours += try Self.decode(HourlyEnergy.self, from: data).data.compactMap { item in
                guard let kwh = item.consumption, kwh.isFinite, let date = DirectChargerDates.parse(item.date) else { return nil }
                return HomeEnergyProfile.Hour(start: date, kwh: kwh)
            }
            start = end
        }
        return hours
    }

    private func sessionBatch(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate] {
        let path = Self.root + "/sessions/charger/" + Self.pathComponent(chargerID)
        let query = [
            URLQueryItem(name: "from_date", value: DirectChargerDates.format(from)),
            URLQueryItem(name: "to_date", value: DirectChargerDates.format(to))
        ]
        let data = try await session.data("GET", path: path, query: query)
        let list = try Self.decode(List<FinishedSession>.self, from: data)
        return list.data.compactMap { item in
            guard let start = Self.timestamp(item.startTimestamp), let end = Self.timestamp(item.endTimestamp),
                  end > start, end >= from, end <= to,
                  let energy = item.consumption, energy.isFinite,
                  energy >= HomeSessionReconstructor.minimumSessionKwh else { return nil }
            let key = "nexblue:\(chargerID):\(DirectChargerDates.format(start)):\(DirectChargerDates.format(end))"
            return HomeChargingSessionCandidate(
                key: key, keyKind: .vendorWindow, chargerID: chargerID, startedAt: start, endedAt: end,
                energyKwh: energy, energySource: "nexblue_session_api", measuredAt: end,
                startReason: item.startReason, stopReason: item.stopReason
            )
        }
    }

    private static func chargerPath(_ chargerID: String) -> String {
        root + "/chargers/" + pathComponent(chargerID)
    }

    private static func commandPath(_ chargerID: String, _ action: String) -> String {
        chargerPath(chargerID) + "/cmd/" + action
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func timestamp(_ value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        let seconds = value >= 10_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func grant(_ action: String, fields: [String: Any], invalidGrantCode: Int,
                              transport: any HomeAssistantTransport) async throws -> TokenResponse {
        var request = try BearerSession.request(baseURL: baseURL, method: "POST", path: root + "/account/" + action)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await BearerSession.send(request, through: transport)
        if response.statusCode == 403
            || (response.statusCode == 400 && (try? decode(APIError.self, from: data).code) == invalidGrantCode) {
            throw DirectChargerError.unauthorized
        }
        try check(response, data)
        let tokens = try decode(TokenResponse.self, from: data)
        guard !tokens.accessToken.isEmpty, tokens.expiresIn > 0 else {
            throw DirectChargerError.malformedResponse
        }
        return tokens
    }

    private static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300, 401, 403, 404, 429:
            try BearerSession.check(response, data: data)
        default:
            switch try? decode(APIError.self, from: data).code {
            case 2101: throw DirectChargerError.unreachable
            case 2103: throw DirectChargerError.forbidden
            case 2105: throw DirectChargerError.chargerOffline
            default: throw DirectChargerError.rejected(status: response.statusCode, message: "")
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(type, from: data) else { throw DirectChargerError.malformedResponse }
        return value
    }

    private struct List<Element: Decodable>: Decodable { let data: [Element] }
    private struct Charger: Decodable {
        let serialNumber: String
        let role: Int?
    }
    private struct ChargerProfile: Decodable { let productName: String? }
    private struct HourlyEnergy: Decodable {
        struct Item: Decodable {
            let date: String
            let consumption: Double?
        }
        let data: [Item]
    }
    private struct APIError: Decodable { let code: Int }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval

        var bearer: BearerSession.Token { .init(value: accessToken, lifetime: expiresIn) }
    }

    private struct Status: Decodable {
        let chargingState: Int
        let power: Double?
        let energy: Double?
        let lifetimeEnergy: Double?
        let currentLimit: Double?
        let isDisable: Bool?
        let isLock: Bool?
        let voltageList: [Double]?
        let currentList: [Double]?
        let cableCurrentLimit: Int?
        let circuitFuse: Int?
        let phaseCharging: Int?
        let networkStatus: Int?
    }

    private struct FinishedSession: Decodable {
        let startTimestamp: Int64?
        let endTimestamp: Int64?
        let consumption: Double?
        let startReason: String?
        let stopReason: String?
    }

    func schedule(chargerID: String) async throws -> NexBlueSchedule {
        let detailData = try await session.data("GET", path: Self.chargerPath(chargerID))
        let detail = try Self.decode(ChargerDetail.self, from: detailData)
        guard detail.online else { throw DirectChargerError.chargerOffline }
        if let role = detail.role, role != 0 { throw DirectChargerError.forbidden }
        guard detail.deviceOperatorType != 3,
              let timeZone = TimeZone(identifier: detail.placeData.tzId) else { throw NexBlueTimerError.unsupported }

        let data = try await session.data("GET", path: Self.commandPath(chargerID, "schedule"))
        let schedule = try Self.decode(ScheduleDetail.self, from: data)
        guard schedule.scheduleMode == 2 else { throw NexBlueTimerError.unsupported }
        return NexBlueSchedule(timeZone: timeZone, items: schedule.chargeSchedules)
    }

    func saveTimer(_ preview: NexBlueTimerPreview, now: () -> Date,
                   canWrite: @MainActor () -> Bool) async throws {
        let current = try await schedule(chargerID: preview.chargerID)
        try current.checkAvailable()
        guard current == preview.schedule, await canWrite(),
              NexBlueTimerPreview.canRepresent(preview.window, in: current.timeZone, after: now().addingTimeInterval(60)) else {
            throw NexBlueTimerError.changed
        }

        let path = Self.commandPath(preview.chargerID, "schedule")
        let item = preview.item
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(ScheduleUpdate(scheduleItem: item, scheduleIndex: current.items.count))
        do {
            let response = try await session.data("PUT", path: path, jsonBody: body)
            guard try Self.decode(CommandResult.self, from: response).code == 0 else {
                throw DirectChargerError.rejected(status: 200, message: "")
            }
        } catch let error as DirectChargerError {
            // A timeout or unreadable reply can follow an accepted write. Verify before reporting its outcome.
            switch error {
            case .unreachable, .malformedResponse: break
            case .rejected(let status, _) where status == 408 || status >= 500: break
            default: throw error
            }
        }

        guard let saved = try? await schedule(chargerID: preview.chargerID), saved.timeZone == current.timeZone,
              saved.items.count == current.items.count + 1, Array(saved.items.dropLast()) == current.items,
              let last = saved.items.last, item.matches(last) else { throw NexBlueTimerError.unconfirmed }
    }

    private struct ChargerDetail: Decodable {
        struct Place: Decodable {
            let country: String
            let tzId: String
        }
        let placeData: Place
        let online: Bool
        let role: Int?
        let deviceOperatorType: Int
    }

    private struct ScheduleDetail: Decodable {
        let scheduleMode: Int
        let chargeSchedules: [NexBlueScheduleItem]
    }

    private struct ScheduleUpdate: Encodable {
        let scheduleItem: NexBlueScheduleItem
        let scheduleIndex: Int
    }

    private struct CommandResult: Decodable {
        let code: Int

        init(from decoder: Decoder) throws {
            enum Field: String, CodingKey { case result }
            let fields = try decoder.container(keyedBy: Field.self)
            if let number = try? fields.decode(Int.self, forKey: .result) {
                code = number
            } else if try fields.decode(String.self, forKey: .result) == "success" {
                code = 0
            } else {
                throw DirectChargerError.malformedResponse
            }
        }
    }
}
