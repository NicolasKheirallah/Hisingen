import Foundation

/// One open WebSocket. The production type wraps `URLSessionWebSocketTask`; tests script it.
protocol HomeAssistantSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

protocol HomeAssistantSocketConnecting: Sendable {
    func connect(to url: URL) -> any HomeAssistantSocketConnection
}

struct URLSessionSocketConnector: HomeAssistantSocketConnecting {
    func connect(to url: URL) -> any HomeAssistantSocketConnection {
        URLSessionSocketConnection(url: url)
    }
}

private final class URLSessionSocketConnection: HomeAssistantSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
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
        @unknown default: throw HomeAssistantError.malformedResponse
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Home Assistant's WebSocket API: the authentication handshake, `state_changed` events for
/// live updates, and command/result round trips. The access token goes out once, in the `auth`
/// message, and is not kept afterwards.
actor HomeAssistantSocket {
    private let connection: any HomeAssistantSocketConnection
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<HAJSONValue, any Error>] = [:]
    private var stateContinuation: AsyncStream<HAStateChange>.Continuation?
    private var subscriptionID: Int?
    /// Entities the consumer cares about. `nil` delivers every change. Home Assistant sends the
    /// whole house over this subscription, so anything outside the set is dropped before it is
    /// decoded a second time or queued behind relevant events.
    private var watchedEntityIDs: Set<String>?
    private var reader: Task<Void, Never>?
    private(set) var isClosed = false

    private init(connection: any HomeAssistantSocketConnection) {
        self.connection = connection
    }

    /// Connects and authenticates. Throws `.unauthorized` when Home Assistant refuses the token.
    static func open(baseURL: URL, token: String,
                     connector: any HomeAssistantSocketConnecting = URLSessionSocketConnector()) async throws -> HomeAssistantSocket {
        guard var components = HomeAssistantAddress.endpoint(baseURL, path: "/api/websocket") else {
            throw HomeAssistantError.invalidAddress
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw HomeAssistantError.invalidAddress }
        let connection = connector.connect(to: url)
        do {
            let first = try await connection.receive()
            guard Self.type(of: first) == "auth_required" else { throw HomeAssistantError.malformedResponse }
            try await connection.send(try Self.encode(["type": .string("auth"), "access_token": .string(token)]))
            let reply = try await connection.receive()
            switch Self.type(of: reply) {
            case "auth_ok": break
            case "auth_invalid": throw HomeAssistantError.unauthorized
            default: throw HomeAssistantError.malformedResponse
            }
        } catch let error as HomeAssistantError {
            connection.close()
            throw error
        } catch {
            connection.close()
            throw HomeAssistantError.unreachable((error as NSError).localizedDescription)
        }
        let socket = HomeAssistantSocket(connection: connection)
        await socket.startReading()
        return socket
    }

    /// Live `state_changed` events. The stream ends when the socket closes, which is the
    /// caller's cue to reconnect. Pass `entityIDs` to receive only those entities.
    func stateChanges(entityIDs: Set<String>? = nil) async throws -> AsyncStream<HAStateChange> {
        watchedEntityIDs = entityIDs
        let (stream, continuation) = AsyncStream<HAStateChange>.makeStream(bufferingPolicy: .bufferingNewest(512))
        stateContinuation = continuation
        if isClosed { continuation.finish(); return stream }
        let id = allocateID()
        subscriptionID = id
        _ = try await roundTrip(id: id, fields: ["type": .string("subscribe_events"), "event_type": .string("state_changed")])
        return stream
    }

    /// Sends a command and waits for its `result`. Used for the best-effort discovery calls.
    func command(_ type: String, fields: [String: HAJSONValue] = [:], timeout: TimeInterval = 10) async throws -> HAJSONValue {
        let id = allocateID()
        var message = fields
        message["type"] = .string(type)
        // A watchdog resolves the pending request if Home Assistant never answers.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.abandon(id: id)
        }
        defer { watchdog.cancel() }
        return try await roundTrip(id: id, fields: message)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        reader?.cancel()
        connection.close()
        finishAll(with: HomeAssistantError.unreachable("closed"))
    }

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
                await self.readerEnded(error)
            }
        }
    }

    private func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func roundTrip(id: Int, fields: [String: HAJSONValue]) async throws -> HAJSONValue {
        var message = fields
        message["id"] = .number(Double(id))
        let text = try Self.encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            guard !isClosed else {
                continuation.resume(throwing: HomeAssistantError.unreachable("closed"))
                return
            }
            pending[id] = continuation
            Task { [connection] in
                do { try await connection.send(text) } catch { self.fail(id: id, error) }
            }
        }
    }

    private func fail(id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: HomeAssistantError.unreachable((error as NSError).localizedDescription))
    }

    private func abandon(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: HomeAssistantError.unreachable("timed out"))
    }

    private func route(_ text: String) {
        guard let object = (try? JSONDecoder().decode(HAJSONValue.self, from: Data(text.utf8)))?.objectValue,
              let type = object["type"]?.stringValue else { return }
        switch type {
        case "result":
            guard let id = object["id"]?.doubleValue.map(Int.init), let continuation = pending.removeValue(forKey: id) else { return }
            if object["success"]?.boolValue == true {
                continuation.resume(returning: object["result"] ?? .null)
            } else {
                let message = object["error"]?.objectValue?["message"]?.stringValue ?? ""
                continuation.resume(throwing: HomeAssistantError.rejected(status: 0, message: message))
            }
        case "event":
            guard let event = object["event"]?.objectValue, event["event_type"]?.stringValue == "state_changed",
                  let data = event["data"]?.objectValue, let entityID = data["entity_id"]?.stringValue else { return }
            if let watched = watchedEntityIDs, !watched.contains(entityID) { return }
            var newState: HAEntityState?
            if let value = data["new_state"], value != .null,
               let encoded = try? JSONEncoder().encode(value) {
                newState = try? JSONDecoder().decode(HAEntityState.self, from: encoded)
            }
            stateContinuation?.yield(HAStateChange(entityID: entityID, newState: newState))
        default:
            break
        }
    }

    private func readerEnded(_ error: any Error) {
        guard !isClosed else { return }
        isClosed = true
        connection.close()
        finishAll(with: HomeAssistantError.unreachable((error as NSError).localizedDescription))
    }

    private func finishAll(with error: HomeAssistantError) {
        stateContinuation?.finish()
        stateContinuation = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private static func type(of text: String) -> String? {
        (try? JSONDecoder().decode(HAJSONValue.self, from: Data(text.utf8)))?.objectValue?["type"]?.stringValue
    }

    private static func encode(_ object: [String: HAJSONValue]) throws -> String {
        let data = try JSONEncoder().encode(HAJSONValue.object(object))
        return String(decoding: data, as: UTF8.self)
    }
}
