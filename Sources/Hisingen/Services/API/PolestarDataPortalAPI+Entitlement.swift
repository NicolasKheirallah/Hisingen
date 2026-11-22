import Foundation

/// The entitlement probe the portal adapter itself can answer.
///
/// A `PolestarDataPortalError` already classifies why the portal refused: the application's own
/// pair is missing, the owner withdrew access to the VIN, the daily quota is spent, or the
/// gateway is down. This maps that vocabulary once, so the fallback policy and the inspector
/// speak about access rather than about an HTTP status.
extension PolestarDataPortalAPI: PortalEntitlementReporting {
    func probeEntitlement(now date: Date) async -> PortalEntitlement {
        do {
            try await prepareSession()
        } catch let error as PolestarDataPortalError {
            switch error {
            case .appNotConfigured, .notConfigured:
                return .credentialsMissing
            default:
                return .unavailable(reason: error.errorDescription)
            }
        } catch {
            return .unavailable(reason: nil)
        }
        do {
            let discovery: PolestarDataPortalVehiclesDTO = try await authenticatedGET("/v1/vehicles")
            _ = discovery
            return .entitled
        } catch let error as PolestarDataPortalError {
            switch error {
            case .appNotConfigured, .notConfigured:
                return .credentialsMissing
            case .permissionDenied:
                return .accessRevoked(retryAfter: nil)
            case .rateLimited(let retryAfter):
                return .rateLimited(retryAfter: retryAfter.map { date.addingTimeInterval($0) })
            default:
                if error.requiresAuthentication { return .credentialsMissing }
                return .unavailable(reason: error.errorDescription)
            }
        } catch {
            return .unavailable(reason: nil)
        }
    }
}
