import Foundation

struct ServiceErrorDecision: Sendable {
    let error: VehicleServiceError
}

/// Application-wide error classification. Provider error enums retain transport-specific detail;
/// refresh and presentation code consume this one policy instead of reimplementing the mapping.
/// The decision carries the mapped error only — callers needing retry/session signals read
/// `VehicleServiceError.allowsAutomaticRetry`/`requiresNewSession` directly.
enum ServiceErrorPolicy {
    static func decision(_ error: Error, provider: VehicleBrand) -> ServiceErrorDecision {
        ServiceErrorDecision(error: VehicleServiceError.map(error, provider: provider))
    }
}
