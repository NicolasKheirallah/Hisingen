import Foundation

struct ServiceErrorDecision: Sendable {
    let error: VehicleServiceError
    let retryAutomatically: Bool
    let requiresNewSession: Bool
}

/// Application-wide error classification. Provider error enums retain transport-specific detail;
/// refresh and presentation code consume this one policy instead of reimplementing the mapping.
enum ServiceErrorPolicy {
    static func decision(_ error: Error, provider: VehicleBrand) -> ServiceErrorDecision {
        let mapped = VehicleServiceError.map(error, provider: provider)
        return ServiceErrorDecision(
            error: mapped,
            retryAutomatically: mapped.allowsAutomaticRetry,
            requiresNewSession: mapped.requiresNewSession
        )
    }
}
