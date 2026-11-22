import Foundation


enum VolvoError: Error, LocalizedError {
    case authenticationRequired(AuthFailureReason)


    case appNotConfigured
    /// Volvo's identity provider refused the application's own client ID and secret
    /// (`invalid_client` / `unauthorized_client`). Distinct from `appNotConfigured`, which means
    /// nothing was entered: here the values are present and Volvo has stopped accepting them,
    /// as it did when it retired the original `dc-` applications.
    case appCredentialsRejected
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
    /// A command went out and the answer does not say whether the vehicle acted: a timeout or a
    /// dropped connection after the request left, a 5xx, or a 2xx that could not be read.
    /// Polestar's stack has the same case; both must keep the reader from repeating the command.
    case commandOutcomeUnknown(operation: String)
    case secureStorage
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .authenticationRequired(.invalidCredentials):
            return L10n.text("Sign in failed. Check your Volvo ID credentials.")
        case .authenticationRequired(.callbackRejected):
            return L10n.text("Volvo requested an additional or changed sign-in step. Open Settings and try again.")
        case .authenticationRequired(.signInSystemChanged):
            return L10n.text("Volvo moved to a new sign-in system. Sign in again to keep your vehicle data.")
        case .authenticationRequired:
            return L10n.text("Sign in is required.")
        case .appNotConfigured:
            return L10n.text("Add your Volvo Developer Portal client ID, client secret, and VCC API key in Settings first.")
        case .appCredentialsRejected:
            return L10n.text("Volvo no longer accepts this application's client ID. Sign in with your Volvo ID, or enter credentials for the new sign-in system in Settings.")
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.text("Offline: showing the last available vehicle data.")
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
        case .commandOutcomeUnknown:
            return L10n.text("The command may have reached the vehicle. Check its status before trying again.")
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
        case .authenticationRequired, .appNotConfigured, .appCredentialsRejected: return true
        default: return false
        }
    }

    static func httpFailure(statusCode: Int, retryAfter: TimeInterval? = nil,
                            operation: String = "request") -> VolvoError? {
        // The status ladder is shared; only this vocabulary mapping is Volvo's own.
        switch ServiceResponseClassifier.failure(status: statusCode, retryAfter: retryAfter,
                                                 operation: operation) {
        case nil: return nil
        case .authenticationRequired: return .authenticationRequired(.expiredSession)
        case .permissionDenied(let operation): return .permissionDenied(operation: operation)
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .server(let statusCode): return .server(statusCode: statusCode)
        case .client(let statusCode, _, _): return .client(statusCode: statusCode)
        }
    }

    var asVehicleServiceError: VehicleServiceError {
        switch self {
        case .authenticationRequired(let reason): return .authenticationRequired(provider: .volvo, reason: reason)
        case .appNotConfigured: return .notConfigured
        case .appCredentialsRejected: return .appCredentialsRejected(provider: .volvo)
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
        case .commandOutcomeUnknown(let operation): return .commandOutcomeUnknown(operation: operation)
        case .secureStorage: return .secureStorage
        case .notConfigured: return .notConfigured
        }
    }
}
