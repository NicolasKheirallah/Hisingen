import Foundation
import Testing
@testable import Hisingen

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
private let credentials = DirectChargerCredentials(username: "owner@example.se", password: "p+ss word&1")
private let meterID = "1762080000000"
private let stockholm = TimeZone(identifier: "Europe/Stockholm")!

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private func client(_ transport: MockHomeAssistantTransport) -> PerificClient {
    PerificClient(credentials: credentials, transport: transport, now: { t0 })
}

/// The login answer as Enegic sends it: a token, and a validity one year long with seven fractional digits.
private func login(_ transport: MockHomeAssistantTransport, status: Int = 200) {
    transport.route("PUT", "/createtoken", .json(
        status == 200
            ? #"{"TokenInfo":{"Token":"TK-1","Created":"2026-11-18T10:36:29.7829322Z","ValidTo":"2027-11-18T10:36:29.7829323Z"},"User":{"UserId":1}}"#
            : #"{"Message":"Wrong"}"#, status: status))
}

private let overview = """
{"User":{},"Chargers":[],"Items":[
 {"ItemId":1762080000000,"ItemCategory":"LocalPhysical","ItemType":"Phase","ItemSubType":"EM2One","Name":"Huset","SystemName":"EM-1","TimeZone":"Europe/Stockholm"},
 {"ItemId":1762080000001,"ItemCategory":"LocalVirtual","ItemType":"Reporter","ItemSubType":"OpenReporter","Name":"Laddbox","TimeZone":"Europe/Stockholm"},
 {"ItemId":1762080000002,"ItemCategory":"None","ItemType":"None","ItemSubType":"None","Name":"Tom","SystemName":"X","TimeZone":"Europe/Stockholm"}]}
"""

/// `ts` is Unix milliseconds in packets. Real time carries current and voltage; the minute packet adds the registers.
private func packets(realTime: Date?, minute: Date, amps: [Double] = [4.8, 5.4, 4.6], volts: [Double]? = [227.3, 229, 229.3],
                     hwi: Double = 62_227.598, hwo: Double = 0, item: String = meterID) -> String {
    func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1_000) }
    func list(_ values: [Double]) -> String { "[" + values.map { String($0) }.joined(separator: ",") + "]" }
    let voltage = volts.map { #","huavg":\#(list($0))"# } ?? ""
    let real = realTime.map {
        #"{"hdr":1,"iid":\#(item),"ts":\#(ms($0)),"pv":3,"fw":"4.5.15","data":{"dv":2,"hiavg":\#(list(amps))\#(voltage)}}"#
    } ?? "null"
    return #"""
    [{"ItemId":\#(item),"LatestPackets":{
      "PhaseRealTime":\#(real),
      "PhaseMinute":{"hdr":1,"iid":\#(item),"ts":\#(ms(minute)),"pv":3,"data":{"dv":2,"hiavg":\#(list(amps))\#(voltage),"hwi":\#(hwi),"hwo":\#(hwo)}},
      "PhaseHour":null,"PhaseDay":null}}]
    """#
}

private func phaseData(_ points: [(String, Double, Double)]) -> String {
    let rows = points.map { #"{"ts":"\#($0.0)","data":{"dv":2,"hiavg":[1,1,1],"huavg":[230,230,230],"hwi":\#($0.1),"hwo":\#($0.2)}}"# }
    return #"[{"dt":"2026-01-01T00:00:00","data":[\#(rows.joined(separator: ","))]}]"#
}

// MARK: - Client

@Suite("Perific client")
struct PerificClientTests {
    @Test("The login is one PUT, and the token travels bare in X-Authorization, never as a bearer token")
    func tokenHeader() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("GET", "/getaccountoverview", .json(overview))
        let perific = client(transport)
        _ = try await perific.meters()
        _ = try await perific.meters()
        let logins = transport.requests(path: "/createtoken")
        #expect(logins.count == 1)
        #expect(logins.first?.httpMethod == "PUT")
        let body = try #require(logins.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body["username"] == "owner@example.se")
        #expect(body["password"] == "p+ss word&1")
        let reads = transport.requests(path: "/getaccountoverview")
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0.value(forHTTPHeaderField: "X-Authorization") == "TK-1" })
        #expect(reads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test("A wrong password is an unauthorized error that never repeats the password")
    func wrongPassword() async {
        let transport = MockHomeAssistantTransport()
        login(transport, status: 400)
        do {
            _ = try await client(transport).meters()
            Issue.record("expected a refusal")
        } catch let error as DirectChargerError {
            #expect(error == .unauthorized)
            let text = [error.errorDescription, String(describing: error), "\(credentials)"].compactMap { $0 }.joined()
            #expect(!text.contains("p+ss word&1"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("A token the cloud refuses is replaced once, then the answer stands")
    func reauthenticatesOnce() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        let calls = CallCounter()
        transport.route({ $0.url?.path == "/getaccountoverview" }) { _ in
            calls.increment() == 1 ? .json("{}", status: 401) : .json(overview)
        }
        let meters = try await client(transport).meters()
        #expect(meters.count == 1)
        #expect(transport.requests(path: "/createtoken").count == 2)
    }

    @Test("A login that answers without a token is malformed, not a crash")
    func loginWithoutToken() async {
        let transport = MockHomeAssistantTransport()
        transport.route("PUT", "/createtoken", .json(#"{"User":{}}"#))
        await #expect(throws: DirectChargerError.malformedResponse) { _ = try await client(transport).meters() }
    }

    @Test("Only the item of type Phase is a meter; reporters and empty stubs are left out")
    func metersAreFiltered() throws {
        let meters = try PerificClient.meters(from: Data(overview.utf8))
        #expect(meters == [HouseMeter(id: meterID, name: "Huset", timeZoneIdentifier: "Europe/Stockholm")])
    }

    @Test("The latest reading prefers the real-time packet and takes the registers from the minute packet")
    func latestReading() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        let real = t0.addingTimeInterval(-10)
        transport.route("PUT", "/getlatestpackets", .json(packets(realTime: real, minute: t0.addingTimeInterval(-90))))
        let reading = try #require(try await client(transport).latest(meterID: meterID))
        #expect(reading.observedAt == real)
        #expect(reading.phases.map(\.amps) == [4.8, 5.4, 4.6])
        #expect(reading.phases.map(\.volts) == [227.3, 229, 229.3])
        #expect(reading.importedKwh == 62_227.598)
        #expect(reading.exportedKwh == 0)
        #expect(!reading.voltageAssumed)
        // 4.8 x 227.3 + 5.4 x 229 + 4.6 x 229.3 = 3,382.42 W, apparent.
        #expect(abs(reading.netWatts - 3_382.42) < 0.01)
        #expect(reading.exportKw == 0)
        let request = try #require(transport.requests(path: "/getlatestpackets").first)
        #expect(request.httpMethod == "PUT")
    }

    @Test("Without a real-time packet the minute packet carries the reading")
    func minuteFallback() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        let minute = t0.addingTimeInterval(-60)
        transport.route("PUT", "/getlatestpackets", .json(packets(realTime: nil, minute: minute)))
        let reading = try #require(try await client(transport).latest(meterID: meterID))
        #expect(reading.observedAt == minute)
    }

    @Test("A clamp-sensor packet without voltage assumes 230 V and says so")
    func assumedVoltage() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("PUT", "/getlatestpackets", .json(packets(realTime: t0, minute: t0, amps: [10, 0, 0], volts: nil)))
        let reading = try #require(try await client(transport).latest(meterID: meterID))
        #expect(reading.voltageAssumed)
        #expect(reading.phases.map(\.volts) == [230, 230, 230])
        #expect(reading.netWatts == 2_300)
    }

    @Test("Negative current is export, and the net is split into import and export power")
    func exportSign() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("PUT", "/getlatestpackets", .json(packets(realTime: t0, minute: t0, amps: [-5, -5, -5], volts: [230, 230, 230])))
        let reading = try #require(try await client(transport).latest(meterID: meterID))
        #expect(reading.importKw == 0)
        #expect(abs(reading.exportKw - 3.45) < 0.001)
    }

    @Test("A meter the answer does not list reads as no reading, and a non-list answer is malformed")
    func missingMeter() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("PUT", "/getlatestpackets", .json(packets(realTime: t0, minute: t0, item: "999")))
        #expect(try await client(transport).latest(meterID: meterID) == nil)
        transport.route("PUT", "/getlatestpackets", .json(#"{"oops":true}"#))
        await #expect(throws: DirectChargerError.malformedResponse) { _ = try await client(transport).latest(meterID: meterID) }
    }

    @Test("History labels are the device's local time, so 11:35 in Stockholm in November is 10:35 UTC")
    func historyLabelsAreLocal() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("PUT", "/getphasedata", .json(phaseData([("2026-11-18T11:35:00", 62_227.5, 0), ("2026-11-18T11:34:00", 62_227.4, 0)])))
        let from = Date(timeIntervalSince1970: 1_763_460_000)
        let points = try await client(transport).registers(meterID: meterID, timeZone: stockholm, from: from, to: from.addingTimeInterval(3_600))
        #expect(points.map(\.importedKwh) == [62_227.4, 62_227.5])
        let expected = ISO8601DateFormatter().date(from: "2026-11-18T10:35:00Z")
        #expect(points.last?.at == expected)
        let body = try #require(transport.requests(path: "/getphasedata").first?.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        // The item id goes as a number, and the request times are UTC without an offset.
        #expect(body["itemId"] as? Int64 == 1_762_080_000_000)
        #expect(body["startTime"] as? String == PerificTime.requestString(from))
        #expect((body["startTime"] as? String)?.hasSuffix("Z") == false)
    }

    @Test("A point without both registers is skipped rather than guessed")
    func incompletePoints() throws {
        let json = #"[{"dt":"x","data":[{"ts":"2026-11-18T11:35:00","data":{"hwi":5.0}},{"ts":"2026-11-18T11:36:00","data":{"hwi":6.0,"hwo":0}},{"ts":"bad","data":{"hwi":7,"hwo":0}}]}]"#
        let points = try PerificClient.registers(from: Data(json.utf8), timeZone: stockholm)
        #expect(points.map(\.importedKwh) == [6.0])
    }

    @Test("Hourly history reads a week at a time, keeps the points on the hour and stops at the first empty week")
    func hourlyPagingStopsAtTheMeterStart() async throws {
        let transport = MockHomeAssistantTransport()
        login(transport)
        let calls = CallCounter()
        // Newest page: two points, one on the hour (10:00 UTC is 11:00 in Stockholm in November).
        transport.route({ $0.url?.path == "/getphasedata" }) { _ in
            calls.increment() == 1
                ? .json(phaseData([("2026-11-18T11:00:00", 100.0, 0), ("2026-11-18T11:01:00", 100.1, 0)]))
                : .json("[]")
        }
        let to = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!
        let from = to.addingTimeInterval(-60 * 86_400)
        let points = try await client(transport).hourlyRegisters(meterID: meterID, timeZone: stockholm, from: from, to: to)
        #expect(points.count == 1)
        #expect(points.first?.importedKwh == 100.0)
        #expect(transport.requests(path: "/getphasedata").count == 2)
    }

    @Test("Seven-digit fractional seconds parse, with or without the trailing Z")
    func tokenTimestamps() {
        let a = PerificTime.utc("2026-11-18T10:36:29.7829322Z")
        let b = PerificTime.utc("2026-11-18T10:36:29.7829322")
        #expect(a != nil && a == b)
        #expect(PerificTime.utc(nil) == nil)
    }

    @Test("A throttled cloud is a rate-limit error, not a refusal")
    func rateLimited() async {
        let transport = MockHomeAssistantTransport()
        login(transport)
        transport.route("PUT", "/getlatestpackets", .json("{}", status: 429))
        await #expect(throws: DirectChargerError.rateLimited(retryAfter: nil)) {
            _ = try await client(transport).latest(meterID: meterID)
        }
    }
}

// MARK: - Domain

@Suite("House meter domain")
struct HouseMeterDomainTests {
    private func point(_ seconds: Int, _ imported: Double, _ exported: Double = 0) -> HouseMeterRegisterPoint {
        HouseMeterRegisterPoint(at: Date(timeIntervalSince1970: TimeInterval(seconds)), importedKwh: imported, exportedKwh: exported)
    }

    @Test("A span is the difference between the first and last registers")
    func span() throws {
        let span = try #require(HouseMeterHistory.span([point(7_200, 12.5, 1.25), point(0, 10, 1), point(3_600, 11, 1.1)]))
        #expect(span.importedKwh == 2.5)
        #expect(span.exportedKwh == 0.25)
        #expect(HouseMeterHistory.span([point(0, 1)]) == nil)
    }

    @Test("A register that went backwards is a device reset, so there is no span")
    func spanAcrossReset() {
        #expect(HouseMeterHistory.span([point(0, 100), point(60, 3)]) == nil)
    }

    @Test("Hourly import needs both edges of the hour, and skips a gap or a fall")
    func hourlyImport() {
        let hours = HouseMeterHistory.hourlyImport([
            point(0, 100), point(3_600, 101.5), point(7_200, 103),
            // 10,800 is missing, so the hour from 7,200 has no end.
            point(14_400, 110), point(18_000, 109), // a fall: skipped
            point(1_800, 100.7) // not on the hour: ignored
        ])
        #expect(hours.map(\.kwh) == [1.5, 1.5])
        #expect(hours.first?.start == Date(timeIntervalSince1970: 0))
        #expect(hours.first?.end == Date(timeIntervalSince1970: 3_600))
    }

    @Test("A register set to the meter's lifetime total is not an hour of consumption")
    func registerJump() {
        // Seen on a real installation: 0 kWh one minute, 61,011 kWh the next, on its first day.
        let hours = HouseMeterHistory.hourlyImport([
            point(0, 0), point(3_600, 61_011.3), point(7_200, 61_012.8)
        ])
        #expect(hours.map(\.kwh).count == 1)
        #expect(abs((hours.first?.kwh ?? 0) - 1.5) < 0.001)
        #expect(HouseMeterHistory.span([point(0, 0), point(60, 61_011.3)]) == nil)
        // A long span with a normal total is still a span.
        #expect(HouseMeterHistory.span([point(0, 0), point(86_400, 40)])?.importedKwh == 40)
    }

    private func reading(amps: [Double], age: TimeInterval = 10, volts: Double = 230) -> HouseMeterReading {
        HouseMeterReading(observedAt: t0.addingTimeInterval(-age), phases: amps.map { HouseMeterPhase(amps: $0, volts: volts) })
    }

    @Test("The house line reads import, and the car split appears only when both readings are current and agree")
    func presentation() {
        let house = reading(amps: [10, 10, 10]) // 6.9 kW
        let both = HouseMeterPresentation.make(reading: house, span: nil, carKw: 4.6, now: t0)
        #expect(both.isLive)
        #expect(both.houseLine?.contains("6.9") == true)
        #expect(both.houseValue == "6.9 kW")
        #expect(both.splitLine?.contains("4.6") == true)
        #expect(both.splitLine?.contains("2.3") == true)
        #expect(both.freshnessLine == nil)

        // The car reads more than the house, so the two cannot be subtracted.
        #expect(HouseMeterPresentation.make(reading: reading(amps: [5, 5, 5]), span: nil, carKw: 7.4, now: t0).splitLine == nil)
        // No car reading, or an idle charger: no split.
        #expect(HouseMeterPresentation.make(reading: house, span: nil, carKw: nil, now: t0).splitLine == nil)
        #expect(HouseMeterPresentation.make(reading: house, span: nil, carKw: 0.02, now: t0).splitLine == nil)
    }

    @Test("A reading older than three minutes is last known: no split, no phase rows, and its age is named")
    func staleReading() {
        let old = reading(amps: [10, 10, 10], age: 600)
        let lines = HouseMeterPresentation.make(reading: old, span: nil, carKw: 4.6, now: t0)
        #expect(!lines.isLive)
        #expect(lines.splitLine == nil)
        #expect(lines.details.isEmpty)
        #expect(lines.freshnessLine?.contains("10") == true)
    }

    @Test("Export is worded as export, and today's figures follow the phase rows")
    func exportAndToday() {
        let sending = reading(amps: [-5, -5, -5])
        let span = HouseMeterSpan(from: t0, to: t0, importedKwh: 12.34, exportedKwh: 0)
        let lines = HouseMeterPresentation.make(reading: sending, span: span, carKw: nil, now: t0)
        #expect(lines.houseLine?.contains("grid") == true)
        #expect(lines.houseValue?.contains("grid") == true)
        #expect(lines.details.map(\.label).contains("Imported Today"))
        // No export today, so no export row.
        #expect(!lines.details.map(\.label).contains("Exported Today"))
    }

    @Test("No reading says nothing")
    func empty() {
        let lines = HouseMeterPresentation.make(reading: nil, span: nil, carKw: 3, now: t0)
        #expect(lines.houseLine == nil && lines.splitLine == nil && lines.freshnessLine == nil && lines.details.isEmpty)
    }
}

// MARK: - Model

private final class Cloud: @unchecked Sendable {
    let transport = MockHomeAssistantTransport()
    private let lock = NSLock()
    private var loginStatus = 200
    private var latestBody: String

    init(now: Date) {
        latestBody = packets(realTime: now.addingTimeInterval(-10), minute: now.addingTimeInterval(-70))
        transport.route({ $0.httpMethod == "PUT" && $0.url?.path == "/createtoken" }) { [weak self] _ in
            let status = self?.lock.withLock { self?.loginStatus } ?? 503
            return status == 200
                ? .json(#"{"TokenInfo":{"Token":"TK","Created":"2026-11-18T10:36:29.7829322Z","ValidTo":"2027-11-18T10:36:29.7829323Z"}}"#)
                : .json("{}", status: status)
        }
        transport.route("GET", "/getaccountoverview", .json(overview))
        transport.route({ $0.httpMethod == "PUT" && $0.url?.path == "/getlatestpackets" }) { [weak self] _ in
            .json(self?.lock.withLock { self?.latestBody } ?? "[]")
        }
        transport.route("PUT", "/getphasedata", .json(phaseData([("2026-11-18T01:00:00", 100.0, 0), ("2026-11-18T12:00:00", 109.5, 0)])))
    }

    func set(loginStatus: Int) { lock.withLock { self.loginStatus = loginStatus } }
    func set(latest: String) { lock.withLock { latestBody = latest } }
}

@MainActor
private func eventually(timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
private final class MeterHarness {
    let scoped = ScopedPreferences(label: "house-meter")
    let cloud = Cloud(now: t0)
    let model: HouseMeterModel

    init() {
        let cloud = cloud
        model = HouseMeterModel(
            preferences: scoped.store,
            dependencies: HomeChargingModel.Dependencies(
                transport: cloud.transport, socketConnector: nil, now: { t0 },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, observesWake: false))
    }
}

@Suite("House meter model", .serialized)
@MainActor
struct HouseMeterModelTests {
    @Test("A login that fails is never saved; one that works is, once, in the Keychain")
    func loginIsSavedOnlyWhenItWorks() async throws {
        let harness = MeterHarness()
        harness.cloud.set(loginStatus: 401)
        await #expect(throws: DirectChargerError.unauthorized) { _ = try await harness.model.connect(credentials: credentials) }
        #expect(!harness.model.hasSavedCredentials)

        harness.cloud.set(loginStatus: 200)
        let meters = try await harness.model.connect(credentials: credentials)
        #expect(meters.map(\.id) == [meterID])
        #expect(harness.model.hasSavedCredentials)
        #expect(harness.model.savedUsername() == "owner@example.se")
        // The password lives in the Keychain item only, never in preferences.
        let stored = harness.scoped.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!stored.contains("p+ss word&1"))
    }

    @Test("Choosing a meter reads it: live power, today's import, and nothing else is sent")
    func readsTheMeter() async throws {
        let harness = MeterHarness()
        let meters = try await harness.model.connect(credentials: credentials)
        harness.model.select(try #require(meters.first))
        await eventually { harness.model.link == .live && harness.model.today != nil }
        #expect(harness.model.link == .live)
        let reading = try #require(harness.model.reading)
        #expect(abs(reading.importKw - 3.38) < 0.01)
        #expect(abs((harness.model.today?.importedKwh ?? 0) - 9.5) < 0.001)
        let lines = harness.model.presentation(carKw: 2.0)
        #expect(lines.splitLine != nil)
        // Read only: no write-style endpoint is ever called, and the load balancer is never touched.
        let paths = Set(harness.cloud.transport.requests.compactMap { $0.url?.path })
        #expect(paths.isSubset(of: ["/createtoken", "/getaccountoverview", "/getlatestpackets", "/getphasedata"]))
        harness.model.stop()
    }

    @Test("A meter the account stops listing is named, and the last reading stays")
    func meterMissing() async throws {
        let harness = MeterHarness()
        harness.model.select(try #require(try await harness.model.connect(credentials: credentials).first))
        await eventually { harness.model.link == .live }
        harness.cloud.set(latest: packets(realTime: t0, minute: t0, item: "999"))
        harness.model.refreshNow()
        await eventually { harness.model.link == .meterMissing }
        #expect(harness.model.link == .meterMissing)
        #expect(harness.model.reading != nil)
        harness.model.stop()
    }

    @Test("A login Perific stops accepting ends the loop as unauthorized")
    func loginRefused() async throws {
        let harness = MeterHarness()
        harness.model.select(try #require(try await harness.model.connect(credentials: credentials).first))
        await eventually { harness.model.link == .live }
        harness.cloud.set(loginStatus: 401)
        harness.cloud.transport.route("PUT", "/getlatestpackets", .json("{}", status: 401))
        harness.model.refreshNow()
        await eventually { harness.model.link == .unauthorized }
        #expect(harness.model.link == .unauthorized)
    }

    @Test("Disconnect forgets the login and the meter")
    func disconnect() async throws {
        let harness = MeterHarness()
        harness.model.select(try #require(try await harness.model.connect(credentials: credentials).first))
        await eventually { harness.model.link == .live }
        harness.model.disconnect()
        #expect(harness.model.meter == nil)
        #expect(!harness.model.hasSavedCredentials)
        #expect(harness.model.reading == nil)
        #expect(harness.model.link == .notConfigured)
    }

    @Test("The chosen meter survives a restart and the login is read back from the Keychain")
    func restart() async throws {
        let harness = MeterHarness()
        harness.model.select(try #require(try await harness.model.connect(credentials: credentials).first))
        harness.model.stop()
        let cloud = harness.cloud
        let restored = HouseMeterModel(
            preferences: harness.scoped.store,
            dependencies: HomeChargingModel.Dependencies(
                transport: cloud.transport, socketConnector: nil, now: { t0 },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, observesWake: false))
        #expect(restored.meter?.id == meterID)
        restored.start()
        await eventually { restored.link == .live }
        #expect(restored.link == .live)
        restored.stop()
    }

    @Test("Hourly import is read from the register history and cached")
    func hourlyImport() async throws {
        let harness = MeterHarness()
        harness.cloud.transport.route("PUT", "/getphasedata", .json(phaseData([
            // t0 is 20:26 UTC on 28 May, when Stockholm is two hours ahead: 20:00 and 21:00 local are on the hour.
            ("2026-05-28T20:00:00", 100.0, 0), ("2026-05-28T21:00:00", 101.5, 0)])))
        harness.model.select(try #require(try await harness.model.connect(credentials: credentials).first))
        harness.model.stop()
        let from = t0.addingTimeInterval(-7 * 86_400)
        let first = try #require(await harness.model.hourlyImport(from: from, to: t0))
        #expect(first.map(\.kwh) == [1.5])
        let requests = harness.cloud.transport.requests(path: "/getphasedata").count
        _ = await harness.model.hourlyImport(from: from, to: t0)
        #expect(harness.cloud.transport.requests(path: "/getphasedata").count == requests)
    }

    @Test("Erasing Home Charging removes the Perific login too")
    func eraseAll() async throws {
        let harness = MeterHarness()
        _ = try await harness.model.connect(credentials: credentials)
        #expect(harness.model.hasSavedCredentials)
        HomeChargingStore(defaults: harness.scoped.defaults, keychain: harness.scoped.keychain).eraseAll()
        #expect(!harness.model.hasSavedCredentials)
    }
}
