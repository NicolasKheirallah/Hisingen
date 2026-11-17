import Foundation

/// Why a vendor cloud request did not produce a usable answer. Descriptions never carry the
/// account, the password, a token or a request header.
enum DirectChargerError: Error, Equatable, LocalizedError, Sendable {
    /// The account or password was refused, or the session was refused and signing in again failed.
    case unauthorized
    /// The account is signed in but may not use this charger or endpoint.
    case forbidden
    case notFound
    /// The vendor throttled the account. Retry after `retryAfter` seconds when it says how long.
    case rateLimited(retryAfter: TimeInterval?)
    /// The vendor answered and refused: a command the charger's state does not allow.
    case rejected(status: Int, message: String)
    case unreachable
    case chargerOffline
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return L10n.text("The account or password was not accepted.")
        case .forbidden: return L10n.text("This account may not control that charger.")
        case .notFound: return L10n.text("The charger service does not know that item.")
        case .rateLimited: return L10n.text("The charger service asked Hisingen to slow down. It will try again shortly.")
        case .rejected(_, let message): return message.isEmpty ? L10n.text("The charger service refused the request.") : message
        case .unreachable: return L10n.text("The charger service could not be reached.")
        case .chargerOffline: return L10n.text("The charger is offline.")
        case .malformedResponse: return L10n.text("The charger service sent an answer Hisingen could not read.")
        }
    }

    var isTransient: Bool {
        switch self {
        case .unreachable, .chargerOffline, .rateLimited: return true
        case .rejected(let status, _): return status >= 500
        default: return false
        }
    }
}

/// One vendor's cloud, reduced to what the card and the history need.
///
/// A provider never decides anything for the reader: it reads, it sends the command it is given,
/// and it lists finished sessions. Timestamps on the telemetry say when the cloud last vouched
/// for a value, the same contract the Home Assistant path keeps, so staleness and command
/// confirmation work the same for every source.
protocol DirectChargerProvider: Sendable {
    var source: ChargerSource { get }

    /// The chargers the account can control. Signs in on the way, so this doubles as the
    /// credential check during setup.
    func chargers() async throws -> [DirectChargerSummary]

    func telemetry(chargerID: String, now: Date) async throws -> HomeChargerTelemetry

    /// Sends the vendor's command for `kind`. Success means the cloud accepted it; the charger's
    /// own answer arrives in later telemetry, which the command tracker judges.
    func send(_ kind: HomeChargerCommandKind, chargerID: String, telemetry: HomeChargerTelemetry) async throws

    /// Finished sessions that ended inside the window. A session still running is left out.
    func sessions(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate]

    /// How far back the vendor can be asked, for the first import.
    var sessionLookback: TimeInterval { get }
}

enum DirectChargerProviders {
    static func make(_ source: ChargerSource, credentials: DirectChargerCredentials,
                     transport: any HomeAssistantTransport) -> (any DirectChargerProvider)? {
        switch source {
        case .homeAssistant, .nexBlue: return nil
        case .easee: return EaseeProvider(credentials: credentials, transport: transport)
        case .zaptec: return ZaptecProvider(credentials: credentials, transport: transport)
        }
    }
}

/// Signs in once, reuses the token until shortly before it expires, and signs in again once when
/// the vendor says the token is no longer good. The network seam is the same one the Home
/// Assistant client uses, so tests answer from a route table and nothing real is ever called.
actor BearerSession {
    struct Token: Sendable {
        var value: String
        var lifetime: TimeInterval
    }

    typealias Authenticate = @Sendable (any HomeAssistantTransport) async throws -> Token
    typealias CheckResponse = @Sendable (HTTPURLResponse, Data) throws -> Void

    private let baseURL: URL
    private let transport: any HomeAssistantTransport
    private let authenticate: Authenticate
    private let checkResponse: CheckResponse
    private let now: @Sendable () -> Date
    private var token: String?
    private var expiry: Date?
    private var authentication: Task<String, any Error>?

    /// A token is renewed this long before the vendor says it ends, so a request in flight does
    /// not carry one that dies on the way.
    static let renewalMargin: TimeInterval = 120

    init(baseURL: URL, transport: any HomeAssistantTransport, now: @escaping @Sendable () -> Date = { Date() },
         initialToken: Token? = nil, checkResponse: @escaping CheckResponse = BearerSession.check,
         authenticate: @escaping Authenticate) {
        self.baseURL = baseURL
        self.transport = transport
        self.authenticate = authenticate
        self.checkResponse = checkResponse
        self.now = now
        if let initialToken {
            self.token = initialToken.value
            self.expiry = now().addingTimeInterval(initialToken.lifetime)
        }
    }

    func data(_ method: String, path: String, query: [URLQueryItem] = [], jsonBody: Data? = nil) async throws -> Data {
        let bearer = try await currentToken()
        do {
            return try await perform(method, path: path, query: query, jsonBody: jsonBody, bearer: bearer)
        } catch DirectChargerError.unauthorized {
            if token == bearer { token = nil; expiry = nil }
            let refreshed = try await currentToken()
            return try await perform(method, path: path, query: query, jsonBody: jsonBody, bearer: refreshed)
        }
    }

    func signOut() {
        authentication?.cancel()
        token = nil
        expiry = nil
    }

    private func currentToken() async throws -> String {
        try Task.checkCancellation()
        if let token, let expiry, expiry > now() { return token }
        if let authentication {
            return try await authentication.value
        }
        let task = Task {
            defer { authentication = nil }
            let fresh: Token
            do {
                fresh = try await authenticate(transport)
            } catch let error as DirectChargerError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DirectChargerError.unreachable
            }
            try Task.checkCancellation()
            token = fresh.value
            expiry = now().addingTimeInterval(fresh.lifetime - min(fresh.lifetime / 2, Self.renewalMargin))
            return fresh.value
        }
        authentication = task
        return try await task.value
    }

    private func perform(_ method: String, path: String, query: [URLQueryItem], jsonBody: Data?,
                         bearer: String) async throws -> Data {
        try Task.checkCancellation()
        var request = try Self.request(baseURL: baseURL, method: method, path: path, query: query)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.send(request, through: transport)
        try checkResponse(response, data)
        return data
    }

    static func request(baseURL: URL, method: String, path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DirectChargerError.malformedResponse
        }
        components.percentEncodedPath = path
        components.percentEncodedQueryItems = query.isEmpty ? nil : query.map {
            URLQueryItem(name: $0.name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? $0.name,
                         value: $0.value.map { $0.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? $0 })
        }
        guard let url = components.url else { throw DirectChargerError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    static func send(_ request: URLRequest, through transport: any HomeAssistantTransport) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DirectChargerError {
            throw error
        } catch {
            throw DirectChargerError.unreachable
        }
    }

    /// Maps a vendor answer to an error without ever putting a header, a token or a request body
    /// into the message. Only the vendor's own `detail`, `title` or `message` text is passed on.
    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw DirectChargerError.unauthorized
        case 403: throw DirectChargerError.forbidden
        case 404: throw DirectChargerError.notFound
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw DirectChargerError.rateLimited(retryAfter: retry)
        default:
            throw DirectChargerError.rejected(status: response.statusCode, message: vendorMessage(in: data))
        }
    }

    static func vendorMessage(in data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        for key in ["detail", "title", "message", "Message"] {
            if let text = object[key] as? String, !text.isEmpty { return String(text.prefix(240)) }
        }
        return ""
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+,;")
        return set
    }()
}

/// Lenient reading of values the vendors send as a string, a number or a boolean depending on
/// the field. A value that is none of those reads as `nil`, never as a guess.
enum LooseJSON {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.intValue != 0
        case let text as String:
            switch text.lowercased() {
            case "true", "1", "on": return true
            case "false", "0", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return DirectChargerDates.parse(text)
    }
}

enum DirectChargerDates {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // The vendors sometimes leave the zone off. They mean UTC.
        let bare = ISO8601DateFormatter()
        bare.formatOptions = [.withInternetDateTime]
        bare.timeZone = TimeZone(identifier: "UTC")
        if !text.hasSuffix("Z"), !text.contains("+") {
            let trimmed = text.split(separator: ".").first.map(String.init) ?? text
            return bare.date(from: trimmed + "Z")
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
