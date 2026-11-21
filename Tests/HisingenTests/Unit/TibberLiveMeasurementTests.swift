import Foundation
import Testing
@testable import Hisingen

// MARK: - Test support

/// The scripted connection speaks the same three methods the Tibber socket needs, so the existing
/// Home Assistant script drives it without a second mock.
extension ScriptedSocketConnection: TibberSocketConnection {}

private struct ScriptedTibberConnector: TibberSocketConnecting {
    let connection: ScriptedSocketConnection
    func connect(to url: URL) -> any TibberSocketConnection { connection }
}

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// One `next` frame as Tibber's stream sends it.
private func frame(at: Date, power: Double, production: Double?) -> String {
    let productionValue = production.map { String($0) } ?? "null"
    return #"{"type":"next","id":"1","payload":{"data":{"liveMeasurement":{"timestamp":"\#(iso(at))","power":\#(power),"powerProduction":\#(productionValue)}}}}"#
}

private func sentFrames(_ connection: ScriptedSocketConnection) -> [[String: Any]] {
    connection.sent.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:] }
}

/// The live-stream answer the home gives: whether a reader is paired, and where to subscribe.
private func liveBody(enabled: Bool, url: String? = nil) -> String {
    let urlValue = url.map { #""\#($0)""# } ?? "null"
    return #"{"data":{"viewer":{"websocketSubscriptionUrl":\#(urlValue),"home":{"features":{"realTimeConsumptionEnabled":\#(enabled)}}}}}"#
}

// MARK: - Socket

@Suite("Tibber live socket")
struct TibberLiveSocketTests {
    private func open(_ connection: ScriptedSocketConnection) async throws -> TibberLiveSocket {
        let opened = Task {
            try await TibberLiveSocket.open(url: URL(string: "wss://api.tibber.com/v1-beta/gql/subscriptions")!,
                                             token: "tok-1", homeID: "home-1",
                                             connector: ScriptedTibberConnector(connection: connection))
        }
        connection.push(#"{"type":"connection_ack"}"#)
        return try await opened.value
    }

    @Test("The handshake sends the token as a JSON value, subscribes with a string id, and reads `next` frames")
    func handshakeAndFrames() async throws {
        let connection = ScriptedSocketConnection()
        let socket = try await open(connection)
        connection.push(frame(at: t0, power: 2_340.5, production: nil))
        connection.push(frame(at: t0.addingTimeInterval(5), power: 1_900.0, production: 2_100.0))
        connection.push(#"{"type":"complete","id":"1"}"#)

        var received: [TibberLiveMeasurement] = []
        for await measurement in await socket.measurements() { received.append(measurement) }

        // The frames Tibber's own SDK sends: connection_init with the token inside the payload,
        // then one subscribe with a string id.
        let sent = sentFrames(connection)
        #expect(sent.count >= 2)
        #expect(sent[0]["type"] as? String == "connection_init")
        #expect((sent[0]["payload"] as? [String: Any])?["token"] as? String == "tok-1")
        #expect(sent[1]["type"] as? String == "subscribe")
        #expect(sent[1]["id"] as? String == "1")
        let query = ((sent[1]["payload"] as? [String: Any])?["query"] as? String) ?? ""
        #expect(query.contains("liveMeasurement(homeId: \"home-1\")"))
        // Only documented fields are asked for.
        #expect(query.contains("timestamp") && query.contains("power") && query.contains("powerProduction"))

        #expect(received.count == 2)
        #expect(received[0].observedAt == t0 && received[0].importKw == 2.3405)
        #expect(received[0].productionW == nil)
        #expect(received[1].productionKw == 2.1)
        // The stream completed on its own, which is not a failure.
        #expect(await socket.streamFailure == nil)
    }

    @Test("A refused stream names its reason, which is what the model's reconnect rules read")
    func refusedStream() async throws {
        let connection = ScriptedSocketConnection()
        let socket = try await open(connection)
        connection.push(frame(at: t0, power: 1_000, production: nil))
        connection.push(#"{"type":"error","id":"1","payload":{"errors":[{"message":"no active pulse devices found in home"}]}}"#)

        var received: [TibberLiveMeasurement] = []
        for await measurement in await socket.measurements() { received.append(measurement) }
        #expect(received.count == 1)
        #expect(await socket.streamFailure == .rejected(status: 200, message: "no active pulse devices found in home"))
    }

    @Test("A keepalive ping is answered with pong and the measurements carry on")
    func pingIsAnswered() async throws {
        let connection = ScriptedSocketConnection()
        let socket = try await open(connection)
        connection.push(#"{"type":"ping"}"#)
        connection.push(frame(at: t0, power: 500, production: nil))
        connection.push(#"{"type":"complete","id":"1"}"#)

        var received: [TibberLiveMeasurement] = []
        for await measurement in await socket.measurements() { received.append(measurement) }
        #expect(received.count == 1)
        #expect(sentFrames(connection).contains { $0["type"] as? String == "pong" })
    }
}

// MARK: - Presentation

@Suite("Tibber live presentation")
struct TibberLivePresentationTests {
    private func reading(age: TimeInterval = 10, power: Double = 3_400, production: Double? = nil) -> TibberLiveMeasurement {
        TibberLiveMeasurement(observedAt: t0.addingTimeInterval(-age), powerW: power, productionW: production)
    }

    @Test("The house line reads import, and the split follows the Perific rules")
    func houseAndSplit() {
        let lines = TibberLivePresentation.make(reading: reading(), carKw: 2.3, now: t0)
        #expect(lines.isLive)
        #expect(lines.houseLine?.contains("3.4") == true)
        #expect(lines.splitLine?.contains("2.3") == true)
        #expect(lines.splitLine?.contains("1.1") == true)
        #expect(lines.freshnessLine == nil)
        // The car reads more than the house, so the two cannot be subtracted.
        #expect(TibberLivePresentation.make(reading: reading(power: 1_000), carKw: 2.3, now: t0).splitLine == nil)
        // No car reading, or an idle charger: no split.
        #expect(TibberLivePresentation.make(reading: reading(), carKw: nil, now: t0).splitLine == nil)
        #expect(TibberLivePresentation.make(reading: reading(), carKw: 0.02, now: t0).splitLine == nil)
    }

    @Test("Production shows while it is happening, and only then")
    func productionLine() {
        let lines = TibberLivePresentation.make(reading: reading(production: 2_100), carKw: nil, now: t0)
        #expect(lines.productionLine?.contains("2.1") == true)
        // Under 0.1 kW the line is left out, the same gate the export line uses.
        #expect(TibberLivePresentation.make(reading: reading(production: 50), carKw: nil, now: t0).productionLine == nil)
        #expect(TibberLivePresentation.make(reading: reading(production: nil), carKw: nil, now: t0).productionLine == nil)
    }

    @Test("A frame older than three minutes is last known: its age is named, and the momentary lines are gone")
    func staleFrame() {
        let lines = TibberLivePresentation.make(reading: reading(age: 600, production: 2_100), carKw: 2.3, now: t0)
        #expect(!lines.isLive)
        #expect(lines.houseLine?.contains("3.4") == true)
        #expect(lines.splitLine == nil)
        #expect(lines.productionLine == nil)
        #expect(lines.freshnessLine?.contains("10") == true)
    }

    @Test("No frame says nothing")
    func empty() {
        let lines = TibberLivePresentation.make(reading: nil, carKw: 3, now: t0)
        #expect(lines.houseLine == nil && lines.splitLine == nil && lines.productionLine == nil && lines.freshnessLine == nil)
    }
}

// MARK: - Model

/// A clock the test moves forward, so staleness can be observed without waiting.
private final class WallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
private final class LiveHarness {
    let scoped = ScopedPreferences(label: "tibber-live")
    let transport = MockHomeAssistantTransport()
    let connection = ScriptedSocketConnection()
    let clock: WallClock
    let model: TibberLiveModel

    init(liveEnabled: Bool) {
        clock = WallClock(t0)
        transport.route({ request in
            guard request.httpMethod == "POST", request.url?.path == "/v1-beta/gql" else { return false }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return body.contains("websocketSubscriptionUrl")
        }) { [liveBody = liveBody(enabled: liveEnabled, url: "wss://api.tibber.com/v1-beta/gql/subscriptions")] _ in
            .json(liveBody)
        }
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        try? store.saveTibberToken("tibber-token")
        store.tibberHome = TibberHome(id: "home-1", name: "Villa", timeZone: "Europe/Stockholm", currency: "SEK")
        let clock = clock
        let connection = connection
        model = TibberLiveModel(
            preferences: scoped.store,
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, tibberSocketConnector: ScriptedTibberConnector(connection: connection),
                now: { clock.now }, wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, observesWake: false))
    }

    func startStreaming() {
        connection.push(#"{"type":"connection_ack"}"#)
        model.start()
    }
}

@Suite("Tibber live model", .serialized)
@MainActor
struct TibberLiveModelTests {
    @Test("A home without a Pulse is reported as such, and no stream is ever opened")
    func noPulse() async throws {
        let harness = LiveHarness(liveEnabled: false)
        harness.model.start()
        await eventually { harness.model.link == .noPulse }
        #expect(harness.model.link == .noPulse)
        #expect(harness.connection.sent.isEmpty)
        #expect(harness.model.reading == nil)
    }

    @Test("Frames arrive and the card lines read from them")
    func framesUpdateTheReading() async throws {
        let harness = LiveHarness(liveEnabled: true)
        harness.clock.now = t0
        harness.startStreaming()
        harness.connection.push(frame(at: t0.addingTimeInterval(-10), power: 3_400, production: 2_100))
        await eventually { harness.model.link == .live && harness.model.reading != nil }
        let lines = harness.model.presentation(carKw: 2.3)
        #expect(lines.isLive)
        #expect(lines.houseLine?.contains("3.4") == true)
        #expect(lines.splitLine?.contains("1.1") == true)
        #expect(lines.productionLine?.contains("2.1") == true)
        #expect(lines.freshnessLine == nil)
        harness.model.reset()
    }

    @Test("A stream refused with 'no active pulse devices' settles as no Pulse, not a reconnect")
    func refusedStreamSettlesAsNoPulse() async throws {
        let harness = LiveHarness(liveEnabled: true)
        harness.startStreaming()
        harness.connection.push(#"{"type":"error","id":"1","payload":{"errors":[{"message":"no active pulse devices found in home"}]}}"#)
        await eventually { harness.model.link == .noPulse }
        #expect(harness.model.link == .noPulse)
        #expect(harness.model.reading == nil)
    }

    @Test("A dropped stream keeps its last reading and reconnects")
    func droppedStreamReconnects() async throws {
        let harness = LiveHarness(liveEnabled: true)
        harness.clock.now = t0
        harness.startStreaming()
        harness.connection.push(frame(at: t0.addingTimeInterval(-10), power: 3_400, production: nil))
        await eventually { harness.model.link == .live && harness.model.reading != nil }
        // The network drops the socket.
        harness.connection.drop()
        await eventually { harness.model.link == .reconnecting }
        #expect(harness.model.link == .reconnecting)
        // The last reading stays as last known, with its age.
        let lines = harness.model.presentation(carKw: nil)
        #expect(lines.houseLine?.contains("3.4") == true)
        #expect(lines.splitLine == nil)
        harness.model.reset()
    }
}

// MARK: - Charging trends

@MainActor
private final class ShareHarness {
    let scoped = ScopedPreferences(label: "tibber-live-share")
    let transport = MockHomeAssistantTransport()
    let model: HomeChargingModel
    let base = t0

    /// Hourly consumption edges, `kwh` each, oldest first.
    private static func consumptionEdges(base: Date, count: Int, kwh: Double) -> String {
        let rows = (0..<count).map { index in
            let start = base.addingTimeInterval(Double(index) * 3_600)
            return #"{"cursor":"cur-\#(index)","node":{"from":"\#(iso(start))","to":"\#(iso(start.addingTimeInterval(3_600)))","consumption":\#(kwh),"cost":\#(kwh * 1.5),"currency":"SEK"}}"#
        }
        return #"{"data":{"viewer":{"home":{"consumption":{"edges":[\#(rows.joined(separator: ","))]}}}}}"#
    }

    /// Hourly production edges, `kwh` each. An empty list is a home with no production metering point.
    private static func productionEdges(base: Date, count: Int, kwh: Double) -> String {
        let rows = (0..<count).map { index in
            let start = base.addingTimeInterval(Double(index) * 3_600)
            return #"{"cursor":"cur-\#(index)","node":{"from":"\#(iso(start))","to":"\#(iso(start.addingTimeInterval(3_600)))","production":\#(kwh)}}"#
        }
        return #"{"data":{"viewer":{"home":{"production":{"edges":[\#(rows.joined(separator: ","))]}}}}}"#
    }

    init(production: (count: Int, kwh: Double)?) {
        transport.route({ request in
            guard request.httpMethod == "POST", request.url?.path == "/v1-beta/gql" else { return false }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return body.contains("consumption(")
        }) { [edges = Self.consumptionEdges(base: base, count: 24, kwh: 2.0)] _ in .json(edges) }
        if let production {
            transport.route({ request in
                guard request.httpMethod == "POST", request.url?.path == "/v1-beta/gql" else { return false }
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return body.contains("production(")
            }) { [edges = Self.productionEdges(base: base, count: production.count, kwh: production.kwh)] _ in .json(edges) }
        } else {
            transport.route({ request in
                guard request.httpMethod == "POST", request.url?.path == "/v1-beta/gql" else { return false }
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return body.contains("production(")
            }) { [edges = Self.productionEdges(base: base, count: 0, kwh: 0)] _ in .json(edges) }
        }
        transport.route({ request in
            guard request.httpMethod == "POST", request.url?.path == "/v1-beta/gql" else { return false }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return body.contains("websocketSubscriptionUrl")
        }) { _ in .json(liveBody(enabled: false)) }

        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        try? store.saveTibberToken("tibber-token")
        store.tibberHome = TibberHome(id: "home-1", name: "Villa", timeZone: "Europe/Stockholm", currency: "SEK")
        model = HomeChargingModel(
            preferences: scoped.store, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, tibberSocketConnector: nil,
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, observesWake: false))
    }

    /// One charger-measured session inside the metered window, hour 2 to 4.
    func session(wallboxKwh: Double) -> HistoricalChargingSession {
        let start = base.addingTimeInterval(2 * 3_600)
        let end = base.addingTimeInterval(4 * 3_600)
        let wallbox = WallboxMeasurement(chargerID: "c", sessionKey: "k", keyKind: "test", energyKwh: wallboxKwh,
                                         energySource: "test", measuredAt: end, startedAt: start, endedAt: end,
                                         peakPowerKw: nil, cost: nil, partialCost: nil, costMethod: nil,
                                         priceSource: nil, costAssumptions: [], missingKwh: nil, currency: nil, attribution: nil)
        return HistoricalChargingSession(id: "s", vin: "VIN", startedAt: start, endedAt: end, startSoc: 20, endSoc: 80,
                                          energyDeliveredKwh: 0, peakPowerKw: 7, averagePowerKw: 5,
                                          locationName: nil, createdAt: start, wallbox: wallbox)
    }
}

@Suite("Tibber production in charging trends", .serialized)
@MainActor
struct TibberProductionShareTests {
    @Test("The share carries the home's production when Tibber reports it")
    func shareCarriesProduction() async throws {
        let harness = ShareHarness(production: (count: 3, kwh: 1.5))
        let share = try #require(await harness.model.houseLoadShare(
            from: harness.base, to: harness.base.addingTimeInterval(24 * 3_600), sessions: [harness.session(wallboxKwh: 4)]))
        #expect(share.meter == .tibber)
        #expect(abs(share.houseKwh - 48) < 1e-9)
        #expect(abs((share.productionKwh ?? 0) - 4.5) < 1e-9)
    }

    @Test("A home that reports no production leaves the row out")
    func shareWithoutProduction() async throws {
        let harness = ShareHarness(production: nil)
        let share = try #require(await harness.model.houseLoadShare(
            from: harness.base, to: harness.base.addingTimeInterval(24 * 3_600), sessions: [harness.session(wallboxKwh: 4)]))
        #expect(share.meter == .tibber)
        #expect(share.productionKwh == nil)
    }

    @Test("The production answer is reused, like the consumption answer")
    func productionIsCached() async throws {
        let harness = ShareHarness(production: (count: 3, kwh: 1.5))
        _ = await harness.model.houseLoadShare(
            from: harness.base, to: harness.base.addingTimeInterval(24 * 3_600), sessions: [harness.session(wallboxKwh: 4)])
        let queries = harness.transport.requests.filter {
            String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("production(") == true
        }.count
        _ = await harness.model.houseProduction(from: harness.base, to: harness.base.addingTimeInterval(12 * 3_600))
        let again = harness.transport.requests.filter {
            String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("production(") == true
        }.count
        #expect(again == queries)
    }
}
