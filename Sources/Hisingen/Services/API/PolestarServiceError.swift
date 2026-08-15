import Foundation

struct GraphQLServiceError: Codable, Equatable, Sendable {
    let message: String
    let path: [String]
    let code: String?

    init(message: String, path: [String], code: String? = nil) {
        self.message = message
        self.path = path
        self.code = code
    }
}

enum AuthFailureReason: String, Codable, Sendable {
    case noStoredSession
    case invalidCredentials
    case expiredSession
    case callbackRejected
}

enum PolestarError: Error, LocalizedError {
    case authenticationRequired(AuthFailureReason)
    case network(URLError)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    case client(statusCode: Int)
    case permissionDenied(operation: String)
    case graphQL([GraphQLServiceError], hasPartialData: Bool)
    case decoding(operation: String)
    case incompatibleAPI(operation: String)
    case invalidResponse(operation: String)
    case responseTooLarge(operation: String)
    case grpcUnimplemented(service: String)
    case grpcUnavailable(service: String)
    case secureStorage
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .authenticationRequired(.invalidCredentials):
            return L10n.text("Sign in failed. Check your Polestar ID and password.")
        case .authenticationRequired(.callbackRejected):
            return L10n.text("Polestar requested an additional or changed sign-in step. Open Settings and try again.")
        case .authenticationRequired:
            return L10n.text("Sign in is required.")
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.text("Offline — showing the last available vehicle data.")
            case .timedOut:
                return L10n.text("Polestar took too long to respond. Retrying automatically.")
            default:
                return L10n.text("Polestar is temporarily unreachable. Retrying automatically.")
            }
        case .rateLimited:
            return L10n.text("Polestar asked Hisingen to refresh less often. Retrying later.")
        case .server:
            return L10n.text("Polestar is temporarily unavailable. Retrying automatically.")
        case .client:
            return L10n.text("Polestar rejected the request. Open Settings if this continues.")
        case .permissionDenied:
            return L10n.text("This Polestar account is not permitted to use that vehicle service.")
        case .graphQL(_, let partial) where partial:
            return L10n.text("Some vehicle information is temporarily unavailable.")
        case .grpcUnimplemented:
            return L10n.text("This vehicle service is not available for your vehicle.")
        case .grpcUnavailable:
            return L10n.text("A vehicle service is temporarily unavailable. Retrying automatically.")
        case .graphQL, .decoding, .incompatibleAPI, .invalidResponse, .responseTooLarge:
            return L10n.text("Polestar's vehicle service returned an unexpected response.")
        case .secureStorage:
            return L10n.text("Hisingen couldn't update its protected Keychain session.")
        case .notConfigured:
            return L10n.text("Open Settings to sign in.")
        }
    }

    var requiresAuthentication: Bool {
        if case .authenticationRequired = self { return true }
        return false
    }

    var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .server, .grpcUnavailable: return true
        default: return false
        }
    }

    static func map(_ error: Error) -> PolestarError {
        if let error = error as? PolestarError { return error }
        if let error = error as? URLError { return .network(error) }
        if error is KeychainError { return .secureStorage }
        return .invalidResponse(operation: "network request")
    }

    static func httpFailure(statusCode: Int, retryAfter: TimeInterval? = nil,
                            authenticationReason: AuthFailureReason = .expiredSession,
                            forbiddenIsAuthentication: Bool = false,
                            operation: String = "request") -> PolestarError? {
        if (200..<300).contains(statusCode) { return nil }
        if statusCode == 401 || (statusCode == 403 && forbiddenIsAuthentication) {
            return .authenticationRequired(authenticationReason)
        }
        if statusCode == 403 { return .permissionDenied(operation: operation) }
        if statusCode == 429 { return .rateLimited(retryAfter: retryAfter) }
        if (500..<600).contains(statusCode) { return .server(statusCode: statusCode) }
        return .client(statusCode: statusCode)
    }


    var asVehicleServiceError: VehicleServiceError {
        switch self {
        case .authenticationRequired(let reason): return .authenticationRequired(provider: .polestar, reason: reason)
        case .network(let error): return .network(error)
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .server(let statusCode): return .server(statusCode: statusCode)
        case .client(let statusCode): return .client(statusCode: statusCode)
        case .permissionDenied(let operation): return .permissionDenied(provider: .polestar, operation: operation)
        case .graphQL(_, let hasPartialData): return .upstreamError(provider: .polestar, hasPartialData: hasPartialData)
        case .decoding(let operation): return .decoding(provider: .polestar, operation: operation)
        case .incompatibleAPI(let operation): return .incompatibleAPI(provider: .polestar, operation: operation)
        case .invalidResponse(let operation): return .invalidResponse(operation: operation)
        case .responseTooLarge(let operation): return .responseTooLarge(operation: operation)
        case .grpcUnimplemented(let service): return .unsupported(provider: .polestar, service: service)
        case .grpcUnavailable(let service): return .temporarilyUnavailable(provider: .polestar, service: service)
        case .secureStorage: return .secureStorage
        case .notConfigured: return .notConfigured
        }
    }
}

