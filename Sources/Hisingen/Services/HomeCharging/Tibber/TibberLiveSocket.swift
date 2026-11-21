import Foundation

/// One open Tibber websocket. The production type wraps `URLSessionWebSocketTask` with the
/// `graphql-transport-ws` subprotocol; tests script it.
protocol TibberSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

protocol TibberSocketConnecting: Sendable {
    func connect(to url: URL) -> any TibberSocketConnection
}

struct URLSessionTibberSocketConnector: TibberSocketConnecting {
    func connect(to url: URL) -> any TibberSocketConnection { URLSessionTibberSocketConnection(url: url) }
}

private final class URLSessionTibberSocketConnection: TibberSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        // The subprotocol is part of the handshake; Tibber's stream refuses a plain websocket.
        task = session.webSocketTask(with: url, protocols: ["graphql-transport-ws"])
        task.maximumMessageSize = 8 * 1_024 * 1_024
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw DirectChargerError.malformedResponse
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// What the API names for the live stream: whether the home has a live reader paired, and the
/// URL websocket subscriptions go to. Both fields are documented on `viewer`.
struct TibberLiveStream: Equatable, Sendable {
    /// The schema calls the reader a Pulse or Watty device.
    var realTimeEnabled: Bool
    /// The subscription address the API names, when it answers one.
    var url: URL?
}

/// One frame of the live stream, reduced to what the card reads. `power` is the grid meter's
/// momentary import in watts and `powerProduction` the production metering point's momentary net
/// production in watts; both are documented on `liveMeasurement` (developer.tibber.com).
struct TibberLiveMeasurement: Equatable, Sendable {
    /// A reading older than this is shown as last known, the same rule the Perific lines use.
    static let staleAfter: TimeInterval = 180

    /// When the meter took the reading, from the frame and not from arrival.
    var observedAt: Date
    var powerW: Double
    /// Net production at the moment, in watts. `nil` when the frame carried none.
    var productionW: Double?

    var importKw: Double { max(0, powerW) / 1_000 }
    var productionKw: Double? { productionW.map { max(0, $0) / 1_000 } }

    func age(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(observedAt)) }
    func isCurrent(now: Date) -> Bool { age(now: now) <= Self.staleAfter }
}

/// Tibber's live-measurement subscription over wss, in the shape of `HomeAssistantSocket`. The
/// protocol is `graphql-transport-ws`: the token goes out once, as a JSON value inside
/// `connection_init`, the subscription is one `subscribe` frame with a string id, measurements
/// arrive as `next` frames, and `complete` or `error` ends the stream. The frame shapes follow
/// Tibber's own .NET SDK (github.com/tibber/Tibber.SDK.NET).
actor TibberLiveSocket {
    /// The documented stream address. The API also names its own URL, which the caller uses when
    /// it answers one.
    static let subscriptionURL = URL(string: "wss://api.tibber.com/v1-beta/gql/subscriptions")!
    /// Only the fields the card reads; everything else the schema lists stays on the wire.
    static let subscriptionQuery = "subscription { liveMeasurement(homeId: \"%@\") { timestamp power powerProduction } }"

    private let connection: any TibberSocketConnection
    private var stream: AsyncStream<TibberLiveMeasurement>?
    private var continuation: AsyncStream<TibberLiveMeasurement>.Continuation?
    private var reader: Task<Void, Never>?
    private(set) var isClosed = false
    /// Why the stream ended on its own, which is what the caller's reconnect rules read. `nil`
    /// when the caller closed it or the stream completed.
    private(set) var streamFailure: DirectChargerError?

    private init(connection: any TibberSocketConnection, stream: AsyncStream<TibberLiveMeasurement>,
                 continuation: AsyncStream<TibberLiveMeasurement>.Continuation) {
        self.connection = connection
        self.stream = stream
        self.continuation = continuation
    }

    /// Connects and subscribes. A token the API refuses shows up as the reader's own homes query
    /// failing before this is ever reached, not as a stream error.
    static func open(url: URL, token: String, homeID: String,
                     connector: any TibberSocketConnecting = URLSessionTibberSocketConnector()) async throws -> TibberLiveSocket {
        let connection = connector.connect(to: url)
        do {
            try await connection.send(Self.encode(["type": "connection_init", "payload": ["token": token]]))
            // The protocol acknowledges a connection before anything may be subscribed to it.
            // A keepalive ping first is answered and skipped.
            while true {
                let text = try await connection.receive()
                guard let object = Self.decode(text), let type = object["type"] as? String else { continue }
                if type == "connection_ack" { break }
                if type == "ping" { try await connection.send(Self.encode(["type": "pong"])) }
            }
            let escaped = homeID.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            try await connection.send(Self.encode([
                "payload": ["query": String(format: subscriptionQuery, escaped), "variables": [:], "extensions": [:]],
                "type": "subscribe", "id": "1"
            ]))
            let (stream, continuation) = AsyncStream<TibberLiveMeasurement>.makeStream(bufferingPolicy: .bufferingNewest(64))
            let socket = TibberLiveSocket(connection: connection, stream: stream, continuation: continuation)
            await socket.startReading()
            return socket
        } catch {
            connection.close()
            throw DirectChargerError.unreachable
        }
    }

    /// The live stream. It ends when the socket closes or the stream completes, which is the
    /// caller's cue to reconnect or to read `streamFailure`.
    func measurements() -> AsyncStream<TibberLiveMeasurement> {
        if let stream { return stream }
        // A closed socket has no stream left to hand out, so an already finished one ends the loop.
        let (empty, continuation) = AsyncStream<TibberLiveMeasurement>.makeStream()
        continuation.finish()
        return empty
    }

    func close() { streamEnded(nil) }

    // MARK: - Internals

    private func startReading() {
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let text = try await self.connection.receive()
                    await self.route(text)
                }
            } catch {
                await self.streamEnded(.unreachable)
            }
        }
    }

    private func route(_ text: String) {
        guard let object = Self.decode(text), let type = object["type"] as? String else { return }
        switch type {
        case "next":
            let measurement = (((object["payload"] as? [String: Any])?["data"] as? [String: Any])?["liveMeasurement"]) as? [String: Any]
            guard let frame = measurement, let observedAt = LooseJSON.date(frame["timestamp"]),
                  let watts = LooseJSON.double(frame["power"]), watts.isFinite else { return }
            continuation?.yield(TibberLiveMeasurement(
                observedAt: observedAt, powerW: watts,
                productionW: LooseJSON.double(frame["powerProduction"]).flatMap { $0.isFinite ? $0 : nil }))
        case "complete":
            streamEnded(nil)
        case "error":
            let errors = (object["payload"] as? [String: Any])?["errors"] as? [[String: Any]] ?? []
            streamEnded(TibberClient.error(from: errors))
        case "ping":
            Task { [connection] in try? await connection.send(Self.encode(["type": "pong"])) }
        default:
            break   // `pong` and `ka` are the protocol's housekeeping.
        }
    }

    private func streamEnded(_ failure: DirectChargerError?) {
        guard !isClosed else { return }
        isClosed = true
        if let failure { streamFailure = failure }
        reader?.cancel()
        connection.close()
        continuation?.finish()
        continuation = nil
    }

    private static func decode(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
