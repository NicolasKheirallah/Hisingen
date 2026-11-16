import Foundation
@testable import Hisingen

/// A mock Home Assistant endpoint: requests are answered from a route table, and every request
/// is recorded so a test can assert on the method, path, query and headers the client sent.
final class MockHomeAssistantTransport: HomeAssistantTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
        static func fixture(_ name: String, status: Int = 200) -> Reply {
            Reply(status: status, body: fixtureData(name))
        }
        static func text(_ text: String, status: Int) -> Reply { Reply(status: status, body: Data(text.utf8)) }
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var routes: [(match: @Sendable (URLRequest) -> Bool, reply: @Sendable (URLRequest) -> Reply)] = []
    var unreachable = false

    func route(_ matcher: @escaping @Sendable (URLRequest) -> Bool, _ reply: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        routes.insert((matcher, reply), at: 0)
    }

    /// `GET /api/states` style shorthand.
    func route(_ method: String, _ pathPrefix: String, _ reply: Reply) {
        route({ $0.httpMethod == method && Self.encodedPath($0).hasPrefix(pathPrefix) }, { _ in reply })
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func requests(path: String) -> [URLRequest] {
        requests.filter { Self.encodedPath($0) == path }
    }

    /// `URL.path` drops a trailing slash, and `GET /api/` needs it, so compare the raw path.
    static func encodedPath(_ request: URLRequest) -> String {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (matched, down) = lock.withLock {
            recorded.append(request)
            return (routes.first { $0.match(request) }, unreachable)
        }
        if down { throw URLError(.cannotConnectToHost) }
        let reply = matched?.reply(request) ?? Reply.text("not routed", status: 404)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (reply.body, response)
    }
}

func fixtureData(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
          let data = try? Data(contentsOf: url) else {
        fatalError("Missing fixture \(name).json")
    }
    return data
}

func fixtureStates(_ name: String = "home-assistant-states-nexblue") throws -> [HAEntityState] {
    try JSONDecoder().decode([HAEntityState].self, from: fixtureData(name))
}

/// The two-sided script of a Home Assistant WebSocket session.
final class ScriptedSocketConnection: HomeAssistantSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false
    private(set) var sent: [String] = []

    func push(_ text: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            inbox.append(text)
            lock.unlock()
        }
    }

    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let first = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: first)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: URLError(.networkConnectionLost))
    }

    /// Simulates the network dropping under an open socket.
    func drop() { close() }
}

struct ScriptedSocketConnector: HomeAssistantSocketConnecting {
    let connection: ScriptedSocketConnection
    func connect(to url: URL) -> any HomeAssistantSocketConnection { connection }
}

/// Fixed charger entity ids matching `home-assistant-states-nexblue`.
enum NexBlueFixture {
    static let map = HomeChargerEntityMap(
        chargingState: "sensor.nx1234567_charging_state", power: "sensor.nx1234567_power",
        sessionEnergy: "sensor.nx1234567_energy", lifetimeEnergy: "sensor.nx1234567_lifetime_energy",
        currentLimit: "sensor.nx1234567_current_limit", chargingSwitch: "switch.nx1234567_charging",
        chargingEnabled: "binary_sensor.nx1234567_charging_enabled",
        cableLock: "binary_sensor.nx1234567_cable_lock_state", vehicleBattery: "sensor.polestar_2_battery"
    )

    static func pairing(vin: String = "YSMTEST", shared: Bool = false, networkFee: Double = 0) -> HomeChargingPairing {
        HomeChargingPairing(
            baseURL: "http://homeassistant.local:8123", chargerID: "NX1234567", chargerName: "NexBlue NX1234567",
            entities: map, vin: vin, locationID: "home-loc", locationAlias: "Home", isSharedCharger: shared,
            timeZoneIdentifier: "Europe/Stockholm", tibberHome: nil, networkFeeOrePerKwh: networkFee,
            pairedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    /// A state table where every charger entity was reported at `reportedAt`.
    static func table(status: String = "charging", powerKw: String = "7.31", energyKwh: String = "12.42",
                      reportedAt: Date, switchState: String = "on") -> [String: HAEntityState] {
        func state(_ id: String, _ value: String, _ attributes: [String: HAJSONValue] = [:]) -> HAEntityState {
            HAEntityState(entityID: id, state: value, attributes: attributes, lastChanged: reportedAt,
                          lastUpdated: reportedAt, lastReported: reportedAt)
        }
        let all = [
            state(map.chargingState!, status), state(map.power!, powerKw, ["unit_of_measurement": .string("kW")]),
            state(map.sessionEnergy!, energyKwh, ["unit_of_measurement": .string("kWh")]),
            state(map.chargingSwitch!, switchState), state(map.chargingEnabled!, "on")
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.entityID, $0) })
    }
}

func history(_ state: String, minutesFromStart: Double, base: Date, entity: String? = nil) -> HAHistoryPoint {
    HAHistoryPoint(entityID: entity, state: state, at: base.addingTimeInterval(minutesFromStart * 60))
}
