import Foundation


enum VolvoError: Error, LocalizedError {
    case authenticationRequired(AuthFailureReason)


    case appNotConfigured
    case network(URLError)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    case client(statusCode: Int)
    case permissionDenied(operation: String)


    case regionRestricted(service: String)
    case decoding(operation: String)
    case incompatibleAPI(operation: String)
    case invalidResponse(operation: String)
    case responseTooLarge(operation: String)
    case unsupported(service: String)
    case temporarilyUnavailable(service: String)
    case secureStorage
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .authenticationRequired(.invalidCredentials):
            return L10n.text("Sign in failed. Check your Volvo ID credentials.")
        case .authenticationRequired(.callbackRejected):
            return L10n.text("Volvo requested an additional or changed sign-in step. Open Settings and try again.")
        case .authenticationRequired:
            return L10n.text("Sign in is required.")
        case .appNotConfigured:
            return L10n.text("Add your Volvo Developer Portal client ID, client secret, and VCC API key in Settings first.")
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.text("Offline — showing the last available vehicle data.")
            case .timedOut:
                return L10n.text("Volvo took too long to respond. Retrying automatically.")
            default:
                return L10n.text("Volvo is temporarily unreachable. Retrying automatically.")
            }
        case .rateLimited:
            return L10n.text("Volvo asked Hisingen to refresh less often. Retrying later.")
        case .server:
            return L10n.text("Volvo is temporarily unavailable. Retrying automatically.")
        case .client:
            return L10n.text("Volvo rejected the request. Open Settings if this continues.")
        case .permissionDenied:
            return L10n.text("This Volvo account is not permitted to use that vehicle service.")
        case .regionRestricted:
            return L10n.text("This service isn't offered for this vehicle's registered market.")
        case .unsupported:
            return L10n.text("This vehicle service is not available for your vehicle.")
        case .temporarilyUnavailable:
            return L10n.text("A vehicle service is temporarily unavailable. Retrying automatically.")
        case .decoding, .incompatibleAPI, .invalidResponse, .responseTooLarge:
            return L10n.text("Volvo's vehicle service returned an unexpected response.")
        case .secureStorage:
            return L10n.text("Hisingen couldn't update its protected Keychain session.")
        case .notConfigured:
            return L10n.text("Open Settings to sign in.")
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .authenticationRequired, .appNotConfigured: return true
        default: return false
        }
    }

    var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .server, .temporarilyUnavailable: return true
        default: return false
        }
    }

    static func httpFailure(statusCode: Int, retryAfter: TimeInterval? = nil,
                            operation: String = "request") -> VolvoError? {
        if (200..<300).contains(statusCode) { return nil }
        if statusCode == 401 { return .authenticationRequired(.expiredSession) }
        if statusCode == 403 { return .permissionDenied(operation: operation) }
        if statusCode == 429 { return .rateLimited(retryAfter: retryAfter) }
        if (500..<600).contains(statusCode) { return .server(statusCode: statusCode) }
        return .client(statusCode: statusCode)
    }

    var asVehicleServiceError: VehicleServiceError {
        switch self {
        case .authenticationRequired(let reason): return .authenticationRequired(provider: .volvo, reason: reason)
        case .appNotConfigured: return .notConfigured
        case .network(let error): return .network(error)
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .server(let statusCode): return .server(statusCode: statusCode)
        case .client(let statusCode): return .client(statusCode: statusCode)
        case .permissionDenied(let operation): return .permissionDenied(provider: .volvo, operation: operation)
        case .regionRestricted(let service): return .unsupported(provider: .volvo, service: service)
        case .decoding(let operation): return .decoding(provider: .volvo, operation: operation)
        case .incompatibleAPI(let operation): return .incompatibleAPI(provider: .volvo, operation: operation)
        case .invalidResponse(let operation): return .invalidResponse(operation: operation)
        case .responseTooLarge(let operation): return .responseTooLarge(operation: operation)
        case .unsupported(let service): return .unsupported(provider: .volvo, service: service)
        case .temporarilyUnavailable(let service): return .temporarilyUnavailable(provider: .volvo, service: service)
        case .secureStorage: return .secureStorage
        case .notConfigured: return .notConfigured
        }
    }
}

