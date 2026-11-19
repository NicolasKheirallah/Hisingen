import Foundation
import Testing
@testable import Hisingen

@Suite("Home Assistant client")
struct HomeAssistantClientTests {
    private let token = "eyJ.super-secret-token.signature"
    private let base = URL(string: "http://homeassistant.local:8123")!

    private func client(_ transport: MockHomeAssistantTransport) -> HomeAssistantClient {
        HomeAssistantClient(baseURL: base, token: token, transport: transport)
    }

    @Test("Requests carry the bearer token and use the documented paths")
    func authenticatedRequests() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/", .json("{\"message\":\"API running.\"}"))
        try await client(transport).ping()
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(MockHomeAssistantTransport.encodedPath(request) == "/api/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("States decode from the fixture")
    func statesDecode() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/states", .fixture("home-assistant-states-nexblue"))
        let states = try await client(transport).states()
        #expect(states.count == 11)
        #expect(states.contains { $0.entityID == "switch.nx1234567_charging" && $0.state == "on" })
    }

    @Test("A missing entity is nil, not an error")
    func missingEntity() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/states/", .json("{\"message\":\"Entity not found.\"}", status: 404))
        #expect(try await client(transport).state(of: "switch.gone") == nil)
    }

    @Test("A charger action posts to the service path and returns the changed states")
    func serviceCall() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("POST", "/api/services/switch/turn_on", .json("""
        [{"entity_id":"switch.nx1234567_charging","state":"on","attributes":{},"last_changed":"2026-11-16T01:14:09+00:00","last_updated":"2026-11-16T01:14:09+00:00"}]
        """))
        let result = try await client(transport).callService(
            domain: "switch", service: "turn_on", data: .object(["entity_id": .string("switch.nx1234567_charging")]))
        #expect(result.changedStates.first?.entityID == "switch.nx1234567_charging")
        let request = try #require(transport.requests.first)
        #expect(request.url?.query == nil)
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains("switch.nx1234567_charging"))
    }

    @Test("Asking for a response sends the return_response flag and parses service_response")
    func serviceResponse() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("POST", "/api/services/tibber/get_prices", .fixture("home-assistant-tibber-prices"))
        let result = try await client(transport).callService(
            domain: "tibber", service: "get_prices", data: .object([:]), returnResponse: true)
        #expect(transport.requests.first?.url?.query == "return_response")
        let points = TibberPriceResponse.points(from: try #require(result.response), home: nil)
        #expect(points.count == 4)
        #expect(points[0].pricePerKwh == 0.62)
        #expect(points[0].end == points[1].start)
        #expect(points[3].end.timeIntervalSince(points[3].start) == 900)
    }

    @Test("Error statuses map to distinct errors and carry Home Assistant's message")
    func errorMapping() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/config", .json("{\"message\":\"Unauthorized\"}", status: 401))
        transport.route("POST", "/api/template", .json("{\"message\":\"Unauthorized\"}", status: 403))
        transport.route("POST", "/api/services/switch/turn_on", .text("Charger NX1234567 is offline", status: 500))
        transport.route("GET", "/api/states", .json("[]", status: 503))
        let api = client(transport)
        await #expect(throws: HomeAssistantError.unauthorized) { _ = try await api.config() }
        await #expect(throws: HomeAssistantError.forbidden) { _ = try await api.renderTemplate("{{ 1 }}") }
        await #expect(throws: HomeAssistantError.rejected(status: 500, message: "Charger NX1234567 is offline")) {
            _ = try await api.callService(domain: "switch", service: "turn_on")
        }
        await #expect(throws: HomeAssistantError.shuttingDown) { _ = try await api.states() }
    }

    @Test("An unreachable instance is a transient error")
    func unreachable() async {
        let transport = MockHomeAssistantTransport()
        transport.unreachable = true
        do {
            _ = try await client(transport).states()
            Issue.record("expected an error")
        } catch let error as HomeAssistantError {
            guard case .unreachable = error else { Issue.record("expected unreachable"); return }
            #expect(error.isTransient)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("The token never appears in an error description, the client description or a request URL")
    func tokenStaysOutOfText() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/config", .json("{\"message\":\"Unauthorized\"}", status: 401))
        let api = client(transport)
        #expect(!String(describing: api).contains(token))
        do { _ = try await api.config() } catch {
            #expect(!String(describing: error).contains(token))
            #expect(!error.localizedDescription.contains(token))
        }
        #expect(transport.requests.allSatisfy { !($0.url?.absoluteString ?? "").contains(token) })
    }

    @Test("History is requested with every change, minimal responses, and decodes per entity")
    func history() async throws {
        let transport = MockHomeAssistantTransport()
        transport.route("GET", "/api/history/period/", .fixture("home-assistant-history-minimal"))
        let from = Date(timeIntervalSince1970: 1_780_000_000)
        let result = try await client(transport).history(
            entityIDs: ["sensor.nx1234567_charging_state", "sensor.nx1234567_energy"],
            from: from, to: from.addingTimeInterval(86_400))
        let request = try #require(transport.requests.first)
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("/api/history/period/\(HATimestamp.format(from))"))
        // The comma between entity ids is percent-encoded in the query, which Home Assistant decodes.
        #expect(url.contains("filter_entity_id=sensor.nx1234567_charging_state%2Csensor.nx1234567_energy"))
        #expect(url.contains("significant_changes_only=0"))
        #expect(url.contains("minimal_response"))
        #expect(result["sensor.nx1234567_charging_state"]?.count == 4)
        let energy = try #require(result["sensor.nx1234567_energy"])
        #expect(energy.map(\.state) == ["0.0", "0.31", "unavailable", "0.62"])
        #expect(energy[1].at > energy[0].at)
    }
}

@Suite("Home Assistant WebSocket")
struct HomeAssistantSocketTests {
    private let base = URL(string: "http://homeassistant.local:8123")!

    /// Polls for up to two seconds. Returns whether the condition held, so a test that depends on
    /// it can fail at the cause instead of timing out later.
    @discardableResult
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("The handshake authenticates once and the token is sent only in the auth message")
    func handshake() async throws {
        let connection = ScriptedSocketConnection()
        connection.push("{\"type\":\"auth_required\",\"ha_version\":\"2026.11.0\"}")
        connection.push("{\"type\":\"auth_ok\"}")
        _ = try await HomeAssistantSocket.open(baseURL: base, token: "tok-123", connector: ScriptedSocketConnector(connection: connection))
        #expect(connection.sent.count == 1)
        #expect(connection.sent[0].contains("\"auth\""))
        #expect(connection.sent[0].contains("tok-123"))
    }

    @Test("An invalid token is reported as unauthorized")
    func invalidToken() async {
        let connection = ScriptedSocketConnection()
        connection.push("{\"type\":\"auth_required\"}")
        connection.push("{\"type\":\"auth_invalid\",\"message\":\"Invalid access token\"}")
        await #expect(throws: HomeAssistantError.unauthorized) {
            _ = try await HomeAssistantSocket.open(baseURL: base, token: "bad", connector: ScriptedSocketConnector(connection: connection))
        }
    }

    @Test("State changes are delivered and the stream ends when the socket drops")
    func stateChangesAndDrop() async throws {
        let connection = ScriptedSocketConnection()
        connection.push("{\"type\":\"auth_required\"}")
        connection.push("{\"type\":\"auth_ok\"}")
        let socket = try await HomeAssistantSocket.open(baseURL: base, token: "t", connector: ScriptedSocketConnector(connection: connection))

        async let subscribed = socket.stateChanges()
        await waitUntil { connection.sent.contains { $0.contains("subscribe_events") } }
        connection.push("{\"id\":1,\"type\":\"result\",\"success\":true,\"result\":null}")
        let stream = try await subscribed

        connection.push("""
        {"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"sensor.nx1234567_charging_state",
        "new_state":{"entity_id":"sensor.nx1234567_charging_state","state":"lb_waiting","attributes":{},
        "last_changed":"2026-11-16T01:50:00.123456+00:00","last_updated":"2026-11-16T01:50:00.123456+00:00"}}}}
        """)
        var iterator = stream.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change?.entityID == "sensor.nx1234567_charging_state")
        #expect(change?.newState?.state == "lb_waiting")

        connection.drop()
        let end = await iterator.next()
        #expect(end == nil)
        await waitUntil { true }
        #expect(await socket.isClosed)
    }

    @Test("A watched set drops other entities' changes and an unwatched socket delivers all of them")
    func stateChangesCanBeScopedToWatchedEntities() async throws {
        func event(_ entity: String, _ state: String) -> String {
            """
            {"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"\(entity)",
            "new_state":{"entity_id":"\(entity)","state":"\(state)","attributes":{},
            "last_changed":"2026-11-16T01:50:00.123456+00:00","last_updated":"2026-11-16T01:50:00.123456+00:00"}}}}
            """
        }
        for watched in [Set(["sensor.wanted"]), nil] as [Set<String>?] {
            let connection = ScriptedSocketConnection()
            connection.push("{\"type\":\"auth_required\"}")
            connection.push("{\"type\":\"auth_ok\"}")
            let socket = try await HomeAssistantSocket.open(baseURL: base, token: "t", connector: ScriptedSocketConnector(connection: connection))
            async let subscribed = socket.stateChanges(entityIDs: watched)
            await waitUntil { connection.sent.contains { $0.contains("subscribe_events") } }
            connection.push("{\"id\":1,\"type\":\"result\",\"success\":true,\"result\":null}")
            let stream = try await subscribed

            connection.push(event("sensor.unrelated", "1"))
            connection.push(event("sensor.wanted", "2"))
            var iterator = stream.makeAsyncIterator()
            let first = await iterator.next()
            if watched == nil {
                #expect(first?.entityID == "sensor.unrelated")
                #expect(await iterator.next()?.entityID == "sensor.wanted")
            } else {
                #expect(first?.entityID == "sensor.wanted", "the unrelated entity never reaches the stream")
                #expect(first?.newState?.state == "2")
            }
            connection.drop()
        }
    }

    @Test("A command resolves with its result and a failed command throws")
    func commandRoundTrip() async throws {
        let connection = ScriptedSocketConnection()
        connection.push("{\"type\":\"auth_required\"}")
        connection.push("{\"type\":\"auth_ok\"}")
        let socket = try await HomeAssistantSocket.open(baseURL: base, token: "t", connector: ScriptedSocketConnector(connection: connection))
        async let answer = socket.command("search/related", fields: ["item_type": .string("entity")])
        // The encoder escapes "/" as "\\/", so match a fragment without one.
        let firstSent: Bool = await waitUntil { connection.sent.contains { $0.contains("related") } }
        #expect(firstSent)
        connection.push("{\"id\":1,\"type\":\"result\",\"success\":true,\"result\":{\"automation\":[\"automation.x\"]}}")
        let value = try await answer
        #expect(value.objectValue?["automation"]?.arrayValue?.first?.stringValue == "automation.x")

        async let failing = socket.command("config/entity_registry/list")
        let secondSent: Bool = await waitUntil { connection.sent.contains { $0.contains("entity_registry") } }
        #expect(secondSent)
        connection.push("{\"id\":2,\"type\":\"result\",\"success\":false,\"error\":{\"code\":\"unauthorized\",\"message\":\"Unauthorized\"}}")
        do {
            _ = try await failing
            Issue.record("Expected the command to be rejected")
        } catch let error as HomeAssistantError {
            #expect(error == .rejected(status: 0, message: "Unauthorized"))
        }
    }
}

@Suite("Home charger discovery")
struct HomeChargerDiscoveryTests {
    @Test("A NexBlue charger is found from its enum sensor and its entities are classified")
    func discoversNexBlue() throws {
        let chargers = HomeChargerDiscovery.chargers(in: try fixtureStates())
        let charger = try #require(chargers.first)
        #expect(chargers.count == 1)
        #expect(charger.id == "nx1234567")
        #expect(charger.entities == NexBlueFixture.map.withoutVehicleBattery)
        #expect(charger.missing.isEmpty)
    }

    @Test("A device serial from the registry becomes the charger id")
    func serialBecomesID() throws {
        let serials = ["sensor.nx1234567_charging_state": (serial: Optional("NX1234567"), name: Optional("NX1234567"))]
        let charger = try #require(HomeChargerDiscovery.chargers(in: try fixtureStates(), serialsByEntity: serials).first)
        #expect(charger.id == "NX1234567")
    }

    @Test("A charger missing its switch reports what is missing so the reader can map it by hand")
    func reportsGaps() throws {
        let states = try fixtureStates().filter { $0.domain != "switch" }
        let charger = try #require(HomeChargerDiscovery.chargers(in: states).first)
        #expect(charger.missing == ["charging switch"])
    }

    @Test("Battery sensors are offered separately and unrelated entities are ignored")
    func batterySensors() throws {
        let sensors = HomeChargerDiscovery.batterySensors(in: try fixtureStates())
        #expect(sensors.map(\.entityID) == ["sensor.polestar_2_battery"])
        #expect(sensors.first?.percent == 62)
    }

    @Test("The address normaliser accepts plain hosts and rejects other schemes")
    func addressNormalisation() {
        #expect(HomeAssistantAddress.normalise("homeassistant.local:8123") == .success(URL(string: "http://homeassistant.local:8123")!))
        #expect(HomeAssistantAddress.normalise("https://ha.example.org/lovelace/0?x=1") == .success(URL(string: "https://ha.example.org")!))
        #expect(HomeAssistantAddress.normalise("ftp://ha.local") == .failure(.unsupportedScheme))
        #expect(HomeAssistantAddress.normalise("   ") == .failure(.empty))
    }
}

private extension HomeChargerEntityMap {
    var withoutVehicleBattery: HomeChargerEntityMap {
        var copy = self
        copy.vehicleBattery = nil
        return copy
    }
}
