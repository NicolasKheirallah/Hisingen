import Foundation

enum PolestarDataPortalError: Error, LocalizedError, Sendable {
    case appNotConfigured
    case authenticationRequired(AuthFailureReason)
    case network(URLError)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    case client(statusCode: Int, message: String? = nil)
    case permissionDenied(operation: String)
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
        case .appNotConfigured:
            return L10n.text("Add your Polestar Developer Portal Client ID and Client Secret in Settings first.")
        case .authenticationRequired(.invalidCredentials):
            return L10n.text("Sign in failed. Check your Polestar Developer Portal Client ID and Secret.")
        case .authenticationRequired(.callbackRejected):
            return L10n.text("Polestar rejected the authorization request. Open Settings and check your credentials.")
        case .authenticationRequired:
            return L10n.text("Polestar Developer Portal authorization is required.")
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.text("Offline: showing the last available vehicle data.")
            case .timedOut:
                return L10n.text("Polestar Developer Portal took too long to respond. Retrying automatically.")
            default:
                return L10n.text("Polestar Developer Portal is temporarily unreachable. Retrying automatically.")
            }
        case .rateLimited:
            return L10n.text("Polestar rate limit reached (10,000 calls/day max). Retrying later.")
        case .server:
            return L10n.text("Polestar Developer Portal is temporarily unavailable. Retrying automatically.")
        case .client(_, let message):
            if let message, !message.isEmpty {
                return L10n.format("Polestar rejected the request: %@", message)
            }
            return L10n.text("Polestar Developer Portal rejected the request. Open Settings if this continues.")
        case .permissionDenied(let operation):
            return L10n.format("This Polestar client is not authorized for %@.", operation)
        case .unsupported(let service):
            return L10n.format("The %@ service is not supported by Polestar Developer Portal.", service)
        case .temporarilyUnavailable:
            return L10n.text("A Polestar vehicle service is temporarily unavailable. Retrying automatically.")
        case .decoding, .incompatibleAPI, .invalidResponse, .responseTooLarge:
            return L10n.text("Polestar Developer Portal returned an unexpected response.")
        case .secureStorage:
            return L10n.text("Hisingen couldn't update its protected Keychain session.")
        case .notConfigured:
            return L10n.text("Open Settings to configure Polestar Developer Portal.")
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .authenticationRequired, .appNotConfigured: return true
        default: return false
        }
    }

    var isRejectedCredential: Bool {
        if case .authenticationRequired(.invalidCredentials) = self { return true }
        return false
    }

    var asVehicleServiceError: VehicleServiceError {
        switch self {
        case .appNotConfigured, .notConfigured:
            return .notConfigured
        case .authenticationRequired(let reason):
            return .authenticationRequired(provider: .polestar, reason: reason)
        case .network(let error):
            return .network(error)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .server(let code):
            return .server(statusCode: code)
        case .client(let code, _):
            return .client(statusCode: code)
        case .permissionDenied(let op):
            return .permissionDenied(provider: .polestar, operation: op)
        case .decoding(let op):
            return .decoding(provider: .polestar, operation: op)
        case .incompatibleAPI(let op):
            return .incompatibleAPI(provider: .polestar, operation: op)
        case .invalidResponse(let op):
            return .invalidResponse(operation: op)
        case .responseTooLarge(let op):
            return .responseTooLarge(operation: op)
        case .unsupported(let s):
            return .unsupported(provider: .polestar, service: s)
        case .temporarilyUnavailable(let s):
            return .temporarilyUnavailable(provider: .polestar, service: s)
        case .secureStorage:
            return .secureStorage
        }
    }
}
