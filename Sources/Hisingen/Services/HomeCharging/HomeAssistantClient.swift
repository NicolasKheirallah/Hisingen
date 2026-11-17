import Foundation

/// Why a Home Assistant request did not produce a usable answer. Descriptions never carry the
/// access token or the request headers.
enum HomeAssistantError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress
    case unauthorized
    /// The token is valid but its user may not call this endpoint (templates need an administrator).
    case forbidden
    case notFound
    case shuttingDown
    /// Home Assistant answered and refused: a bad request, or an action that failed.
    case rejected(status: Int, message: String)
    case unreachable(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return L10n.text("The Home Assistant address is not valid.")
        case .unauthorized: return L10n.text("Home Assistant rejected the access token.")
        case .forbidden: return L10n.text("This token cannot use that part of Home Assistant. Use a token from an administrator.")
        case .notFound: return L10n.text("Home Assistant does not know that item.")
        case .shuttingDown: return L10n.text("Home Assistant is restarting.")
        case .rejected(_, let message): return message.isEmpty ? L10n.text("Home Assistant rejected the request.") : message
        case .unreachable: return L10n.text("Home Assistant could not be reached.")
        case .malformedResponse: return L10n.text("Home Assistant sent an answer Hisingen could not read.")
        }
    }

    /// Whether the same request may succeed later without the reader changing anything.
    var isTransient: Bool {
        switch self {
        case .unreachable, .shuttingDown: return true
        case .rejected(let status, _): return status >= 500
        default: return false
        }
    }
}

/// The one seam between the client and the network. Tests answer from a route table; the app
/// uses `URLSessionHomeAssistantTransport`.
protocol HomeAssistantTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHomeAssistantTransport: HomeAssistantTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HomeAssistantError.malformedResponse }
        return (data, http)
    }
}

struct HAConfig: Equatable, Sendable {
    var locationName: String
    var timeZone: String
    var version: String
    var components: Set<String>
    var currencyCode: String?

    func hasIntegration(_ domain: String) -> Bool { components.contains(domain) }
}

struct HAServiceResult: Equatable, Sendable {
    var changedStates: [HAEntityState]
    var response: HAJSONValue?
}

/// Home Assistant's REST API, limited to the documented endpoints Home Charging needs.
struct HomeAssistantClient: Sendable, CustomStringConvertible {
    let baseURL: URL
    private let token: String
    private let transport: any HomeAssistantTransport

    init(baseURL: URL, token: String, transport: any HomeAssistantTransport = URLSessionHomeAssistantTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Redacted on purpose: a client printed into a log must not leak its token.
    var description: String { "HomeAssistantClient(\(baseURL.host ?? "unknown host"))" }

    // MARK: - Endpoints

    /// `GET /api/`. Confirms the address and the token in one call.
    func ping() async throws {
        _ = try await request("GET", path: "/api/")
    }

    /// `GET /api/config`.
    func config() async throws -> HAConfig {
        let data = try await request("GET", path: "/api/config")
        guard let object = (try? JSONDecoder().decode(HAJSONValue.self, from: data))?.objectValue else {
            throw HomeAssistantError.malformedResponse
        }
        return HAConfig(
            locationName: object["location_name"]?.stringValue ?? "",
            timeZone: object["time_zone"]?.stringValue ?? TimeZone.current.identifier,
            version: object["version"]?.stringValue ?? "",
            components: Set((object["components"]?.arrayValue ?? []).compactMap(\.stringValue)),
            currencyCode: object["currency"]?.stringValue
        )
    }

    /// `GET /api/states`.
    func states() async throws -> [HAEntityState] {
        let data = try await request("GET", path: "/api/states")
        do {
            return try JSONDecoder().decode([HAEntityState].self, from: data)
        } catch {
            throw HomeAssistantError.malformedResponse
        }
    }

    /// `GET /api/states/<entity_id>`; `nil` when Home Assistant does not know the entity.
    func state(of entityID: String) async throws -> HAEntityState? {
        do {
            let data = try await request("GET", path: "/api/states/\(Self.pathComponent(entityID))")
            return try JSONDecoder().decode(HAEntityState.self, from: data)
        } catch HomeAssistantError.notFound {
            return nil
        } catch let error as HomeAssistantError {
            throw error
        } catch {
            throw HomeAssistantError.malformedResponse
        }
    }

    /// `POST /api/services/<domain>/<service>`. With `returnResponse` the action's own data comes
    /// back; Home Assistant answers 400 if the action has none, so ask only for actions that do.
    func callService(domain: String, service: String, data: HAJSONValue = .object([:]),
                     returnResponse: Bool = false) async throws -> HAServiceResult {
        let body = try JSONEncoder().encode(data)
        let query = returnResponse ? [URLQueryItem(name: "return_response", value: nil)] : []
        let raw = try await request("POST", path: "/api/services/\(domain)/\(service)", query: query, body: body)
        let decoded = try? JSONDecoder().decode(HAJSONValue.self, from: raw)
        if returnResponse {
            guard let object = decoded?.objectValue else { throw HomeAssistantError.malformedResponse }
            let changed = Self.changedStates(from: object["changed_states"])
            return HAServiceResult(changedStates: changed, response: object["service_response"])
        }
        return HAServiceResult(changedStates: Self.changedStates(from: decoded), response: nil)
    }

    /// `POST /api/template` (administrator tokens only). Returns the rendered text.
    func renderTemplate(_ template: String) async throws -> String {
        let body = try JSONEncoder().encode(["template": template])
        let data = try await request("POST", path: "/api/template", body: body)
        return String(decoding: data, as: UTF8.self)
    }

    /// `GET /api/history/period/<start>`: every state change of the given entities in the window,
    /// from the recorder (Home Assistant keeps ten days by default).
    func history(entityIDs: [String], from start: Date, to end: Date) async throws -> [String: [HAHistoryPoint]] {
        guard !entityIDs.isEmpty else { return [:] }
        let query = [
            URLQueryItem(name: "filter_entity_id", value: entityIDs.joined(separator: ",")),
            URLQueryItem(name: "end_time", value: HATimestamp.format(end)),
            URLQueryItem(name: "minimal_response", value: nil),
            URLQueryItem(name: "no_attributes", value: nil),
            URLQueryItem(name: "significant_changes_only", value: "0")
        ]
        let data = try await request("GET", path: "/api/history/period/\(HATimestamp.format(start))", query: query)
        guard let groups = try? JSONDecoder().decode([[HAHistoryPoint]].self, from: data) else {
            throw HomeAssistantError.malformedResponse
        }
        var result: [String: [HAHistoryPoint]] = [:]
        for (index, group) in groups.enumerated() {
            let id = group.first?.entityID ?? (index < entityIDs.count ? entityIDs[index] : nil)
            guard let id else { continue }
            result[id] = group
        }
        return result
    }

    // MARK: - Transport

    private func request(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HomeAssistantError.invalidAddress
        }
        components.percentEncodedPath = path
        components.percentEncodedQueryItems = query.isEmpty ? nil : query.map {
            let name = $0.name.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? $0.name
            let value = $0.value.map { $0.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? $0 }
            return URLQueryItem(name: name, value: value)
        }
        guard let url = components.url else { throw HomeAssistantError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as HomeAssistantError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HomeAssistantError.unreachable((error as NSError).localizedDescription)
        }
        switch response.statusCode {
        case 200...299: return data
        case 401: throw HomeAssistantError.unauthorized
        case 403: throw HomeAssistantError.forbidden
        case 404: throw HomeAssistantError.notFound
        case 503: throw HomeAssistantError.shuttingDown
        case let status: throw HomeAssistantError.rejected(status: status, message: Self.errorMessage(from: data))
        }
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=,")
        return set
    }()

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func changedStates(from value: HAJSONValue?) -> [HAEntityState] {
        guard let array = value?.arrayValue,
              let data = try? JSONEncoder().encode(HAJSONValue.array(array)) else { return [] }
        return (try? JSONDecoder().decode([HAEntityState].self, from: data)) ?? []
    }

    /// Home Assistant's error body is `{"message": "..."}` for most failures and plain text for
    /// action errors. Either way it is trimmed, and never contains anything this client sent.
    private static func errorMessage(from data: Data) -> String {
        if let object = (try? JSONDecoder().decode(HAJSONValue.self, from: data))?.objectValue,
           let message = object["message"]?.stringValue {
            return String(message.prefix(300))
        }
        return String(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}
