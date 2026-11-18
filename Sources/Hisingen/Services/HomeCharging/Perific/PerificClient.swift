import Foundation

/// Perific's cloud (formerly Enegic), read with the owner's own Perific account.
///
/// There is no public API and no local interface: the monitor reports to `api.enegic.com` about
/// every ten seconds and the Perific app reads the same cloud. This client does what the app does,
/// read only. It never writes a setting and never touches the load-balancer endpoints, so Perific
/// keeps sole charge of limiting the charger.
///
/// What is known comes from community reverse engineering (kurtsson/hass-perific and
/// toshi38/homeassistant-perific) and is not vendor-documented, so every decoder here is tolerant:
/// a value in an unexpected shape reads as missing and is never guessed. The pieces that rest on a
/// single source are listed in `docs/home-charging.md` under House meter.
///
/// - Login is `PUT /createtoken` with the account and password. The token lasts a year and is sent
///   as the bare value in `X-Authorization`, not as a bearer token.
/// - `GET /getaccountoverview` lists the account's devices; the meter is the item of type `Phase`.
/// - `PUT /getlatestpackets` returns the newest real-time (about 10 s), per-minute and day packets.
///   The day packet is the register read at the end of the last completed day, so today's energy is
///   its subtraction from the minute packet and needs no history request.
/// - `PUT /getphasedata` returns one point per minute between two times. The request times are read
///   as UTC but the answer is labelled in the device's own time zone, without an offset.
struct PerificClient: Sendable {
    static let endpoint = URL(string: "https://api.enegic.com")!
    /// A request this long covers one history page: 7 days is about 10,000 one-minute points.
    static let historyPage: TimeInterval = 7 * 86_400
    /// Nine pages reach past the 62 days History looks back.
    static let maximumHistoryPages = 9

    private let session: BearerSession

    init(credentials: DirectChargerCredentials, transport: any HomeAssistantTransport,
         baseURL: URL = PerificClient.endpoint, now: @escaping @Sendable () -> Date = { Date() }) {
        session = BearerSession(baseURL: baseURL, transport: transport, now: now,
                                tokenHeader: .init(name: "X-Authorization", prefix: "")) { transport in
            try await Self.signIn(credentials, baseURL: baseURL, transport: transport)
        }
    }

    // MARK: Sign in

    static func signIn(_ credentials: DirectChargerCredentials, baseURL: URL,
                       transport: any HomeAssistantTransport) async throws -> BearerSession.Token {
        var request = try BearerSession.request(baseURL: baseURL, method: "PUT", path: "/createtoken")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": credentials.username.trimmingCharacters(in: .whitespaces),
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
              let info = object["TokenInfo"] as? [String: Any],
              let token = info["Token"] as? String, !token.isEmpty else {
            throw DirectChargerError.malformedResponse
        }
        let created = PerificTime.utc(info["Created"] as? String)
        let validTo = PerificTime.utc(info["ValidTo"] as? String)
        var lifetime = 30.0 * 86_400
        if let created, let validTo, validTo > created { lifetime = min(validTo.timeIntervalSince(created), 365 * 86_400) }
        return BearerSession.Token(value: token, lifetime: max(lifetime, 300))
    }

    // MARK: Meters

    /// The meters on the account. Signs in on the way, so this doubles as the credential check.
    func meters() async throws -> [HouseMeter] {
        let data = try await session.data("GET", path: "/getaccountoverview")
        return try Self.meters(from: data)
    }

    static func meters(from data: Data) throws -> [HouseMeter] {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let object = parsed as? [String: Any], let list = object["Items"] as? [[String: Any]] {
            items = list
        } else if let list = parsed as? [[String: Any]] {
            items = list
        } else {
            throw DirectChargerError.malformedResponse
        }
        return items.compactMap { item in
            // The account also lists chargers and empty stubs. The meter is the item of type Phase.
            guard (item["ItemType"] as? String)?.lowercased() == "phase",
                  let id = identifier(item["ItemId"]) else { return nil }
            let named = [item["Name"], item["SystemName"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            let zone = (item["TimeZone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HouseMeter(id: id, name: named ?? id, timeZoneIdentifier: zone)
        }
    }

    // MARK: Latest reading

    /// The meter's newest reading, or `nil` when the answer does not list the meter.
    func latest(meterID: String) async throws -> HouseMeterReading? {
        let data = try await session.data("PUT", path: "/getlatestpackets", jsonBody: Data("{}".utf8))
        return try Self.reading(from: data, meterID: meterID)
    }

    static func reading(from data: Data, meterID: String) throws -> HouseMeterReading? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        guard let item = items.first(where: { identifier($0["ItemId"]) == meterID }),
              let packets = item["LatestPackets"] as? [String: Any] else { return nil }

        let realTime = packet(packets["PhaseRealTime"])
        let minute = packet(packets["PhaseMinute"])
        let day = packet(packets["PhaseDay"])
        // Real time is about ten seconds old; the minute packet is the fallback and carries the registers.
        guard let live = [realTime, minute].compactMap({ $0 }).first(where: { measurement(in: $0) != nil }),
              let measured = measurement(in: live) else { return nil }
        var reading = HouseMeterReading(observedAt: live.at, phases: measured.phases, voltageAssumed: measured.assumed)
        if let minute {
            reading.registersAt = minute.at
            reading.importedKwh = register(minute.data["hwi"])
            reading.exportedKwh = register(minute.data["hwo"])
        }
        // Only both registers make a day baseline; one of them cannot be subtracted from.
        if let day, let imported = register(day.data["hwi"]), let exported = register(day.data["hwo"]) {
            reading.dayRegister = HouseMeterReading.DayRegister(startedAt: day.at, importedKwh: imported,
                                                               exportedKwh: exported)
        }
        return reading
    }

    private struct Packet {
        var at: Date
        var data: [String: Any]
    }

    private static func packet(_ value: Any?) -> Packet? {
        guard let object = value as? [String: Any], let data = object["data"] as? [String: Any],
              let milliseconds = LooseJSON.double(object["ts"]), milliseconds > 0 else { return nil }
        return Packet(at: Date(timeIntervalSince1970: milliseconds / 1_000), data: data)
    }

    /// Per-phase current and voltage. A clamp-sensor device sends no voltage; 230 V stands in and
    /// the reading says so. The key without the `h` prefix is how other firmware names the same value.
    private static func measurement(in packet: Packet) -> (phases: [HouseMeterPhase], assumed: Bool)? {
        let currents = numbers(packet.data["hiavg"] ?? packet.data["iavg"])
        guard !currents.isEmpty else { return nil }
        let volts = numbers(packet.data["huavg"] ?? packet.data["uavg"])
        guard volts.isEmpty || volts.count == currents.count else { return nil }
        let assumed = volts.isEmpty
        let phases = currents.indices.map { HouseMeterPhase(amps: currents[$0], volts: assumed ? 230 : volts[$0]) }
        return (phases, assumed)
    }

    private static func numbers(_ value: Any?) -> [Double] {
        guard let list = value as? [Any] else { return [] }
        let parsed = list.compactMap { LooseJSON.double($0) }
        return parsed.count == list.count ? parsed.filter { $0.isFinite } : []
    }

    private static func register(_ value: Any?) -> Double? {
        guard let kwh = LooseJSON.double(value), kwh.isFinite, kwh >= 0 else { return nil }
        return kwh
    }

    // MARK: History

    /// Register readings for `[from, to]`, one per minute. A day is about 1,440 points.
    func registers(meterID: String, timeZone: TimeZone, from: Date, to: Date) async throws -> [HouseMeterRegisterPoint] {
        try await page(meterID: meterID, timeZone: timeZone, from: from, to: to)
    }

    /// Register readings taken on the hour for `[from, to]`, read a week at a time from the newest
    /// back, keeping only the hourly points so a two-month window stays small.
    func hourlyRegisters(meterID: String, timeZone: TimeZone, from: Date, to: Date) async throws -> [HouseMeterRegisterPoint] {
        var collected: [HouseMeterRegisterPoint] = []
        var end = to
        for _ in 0..<Self.maximumHistoryPages where end > from {
            let start = max(from, end.addingTimeInterval(-Self.historyPage))
            let points = try await page(meterID: meterID, timeZone: timeZone, from: start, to: end)
            // An empty week after some data is before the meter was registered: nothing older exists.
            if points.isEmpty, !collected.isEmpty { break }
            collected += points.filter { Int($0.at.timeIntervalSince1970.rounded()) % 3_600 == 0 }
            end = start
        }
        return collected
    }

    private func page(meterID: String, timeZone: TimeZone, from: Date, to: Date) async throws -> [HouseMeterRegisterPoint] {
        let id: Any = Int64(meterID).map { $0 as Any } ?? meterID
        let body = try JSONSerialization.data(withJSONObject: [
            "itemId": id,
            "startTime": PerificTime.requestString(from),
            "endTime": PerificTime.requestString(to)
        ])
        let data = try await session.data("PUT", path: "/getphasedata", jsonBody: body)
        return try Self.registers(from: data, timeZone: timeZone)
    }

    static func registers(from data: Data, timeZone: TimeZone) throws -> [HouseMeterRegisterPoint] {
        guard let groups = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DirectChargerError.malformedResponse
        }
        // The answer is a list of groups that each hold the points; a flat list of points reads the same.
        let rows: [[String: Any]] = groups.flatMap { group -> [[String: Any]] in
            if let inner = group["data"] as? [[String: Any]] { return inner }
            return [group]
        }
        var points: [HouseMeterRegisterPoint] = []
        for row in rows {
            guard let label = row["ts"] as? String, let at = PerificTime.local(label, in: timeZone),
                  let values = row["data"] as? [String: Any],
                  let imported = register(values["hwi"]), let exported = register(values["hwo"]) else { continue }
            points.append(HouseMeterRegisterPoint(at: at, importedKwh: imported, exportedKwh: exported))
        }
        return points.sorted { $0.at < $1.at }
    }

    // MARK: Identifiers

    /// `ItemId` is a millisecond epoch the vendor sends as a number or a string depending on the call.
    static func identifier(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.stringValue
        default: return nil
        }
    }
}

/// Enegic's time conventions: ISO strings with seven fractional digits and, in history, no offset.
enum PerificTime {
    /// A UTC timestamp such as `2026-11-18T09:00:00.1234567`, with or without the trailing `Z`.
    static func utc(_ text: String?) -> Date? {
        guard let text else { return nil }
        return parse(text, in: TimeZone(identifier: "UTC")!)
    }

    /// A history label, which is local time in the device's zone with no offset.
    static func local(_ text: String, in zone: TimeZone) -> Date? {
        parse(text, in: zone)
    }

    /// What `startTime` and `endTime` take: the instant written as UTC, without an offset.
    static func requestString(_ date: Date) -> String {
        formatter(in: TimeZone(identifier: "UTC")!).string(from: date)
    }

    private static func parse(_ text: String, in zone: TimeZone) -> Date? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Z") { trimmed.removeLast() }
        if let dot = trimmed.firstIndex(of: ".") { trimmed = String(trimmed[..<dot]) }
        return formatter(in: zone).date(from: trimmed)
    }

    private static func formatter(in zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }
}
