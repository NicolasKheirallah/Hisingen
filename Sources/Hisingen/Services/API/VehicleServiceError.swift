import Foundation


enum VehicleServiceError: Error, LocalizedError, Sendable {
    case authenticationRequired(provider: VehicleBrand, reason: AuthFailureReason)
    case network(URLError)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    case client(statusCode: Int)
    case permissionDenied(provider: VehicleBrand, operation: String)
    case upstreamError(provider: VehicleBrand, hasPartialData: Bool)
    case decoding(provider: VehicleBrand, operation: String)
    case incompatibleAPI(provider: VehicleBrand, operation: String)
    case invalidResponse(operation: String)
    case responseTooLarge(operation: String)


    case unsupported(provider: VehicleBrand, service: String)


    case temporarilyUnavailable(provider: VehicleBrand, service: String)
    case secureStorage
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider, .invalidCredentials):
            return L10n.format("Sign in failed. Check your %@ ID and password.", provider.displayName)
        case .authenticationRequired(let provider, .callbackRejected):
            return L10n.format(
                "%@ requested an additional or changed sign-in step. Open Settings and try again.",
                provider.displayName
            )
        case .authenticationRequired:
            return L10n.text("Sign in is required.")
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.text("Offline — showing the last available vehicle data.")
            case .timedOut:
                return L10n.text("The vehicle service took too long to respond. Retrying automatically.")
            default:
                return L10n.text("The vehicle service is temporarily unreachable. Retrying automatically.")
            }
        case .rateLimited:
            return L10n.text("The vehicle service asked Hisingen to refresh less often. Retrying later.")
        case .server:
            return L10n.text("The vehicle service is temporarily unavailable. Retrying automatically.")
        case .client:
            return L10n.text("The vehicle service rejected the request. Open Settings if this continues.")
        case .permissionDenied(let provider, _):
            return L10n.format("This %@ account is not permitted to use that vehicle service.", provider.displayName)
        case .upstreamError(_, let partial) where partial:
            return L10n.text("Some vehicle information is temporarily unavailable.")
        case .unsupported:
            return L10n.text("This vehicle service is not available for your vehicle.")
        case .temporarilyUnavailable:
            return L10n.text("A vehicle service is temporarily unavailable. Retrying automatically.")
        case .upstreamError, .decoding, .incompatibleAPI, .invalidResponse, .responseTooLarge:
            return L10n.text("The vehicle service returned an unexpected response.")
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
        case .network, .rateLimited, .server, .temporarilyUnavailable: return true
        default: return false
        }
    }


    static func map(_ error: Error, provider: VehicleBrand) -> VehicleServiceError {
        if let already = error as? VehicleServiceError { return already }
        if let polestar = error as? PolestarError { return polestar.asVehicleServiceError }
        if let volvo = error as? VolvoError { return volvo.asVehicleServiceError }
        if let urlError = error as? URLError { return .network(urlError) }
        if error is KeychainError { return .secureStorage }
        switch provider {
        case .polestar: return .invalidResponse(operation: "network request")
        case .volvo: return .invalidResponse(operation: "network request")
        }
    }
}


