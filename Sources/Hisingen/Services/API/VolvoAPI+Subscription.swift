import Foundation

extension VolvoAPI {
    /// Premium VOC subscription state, the third endpoint of the Energy API family.
    ///
    /// It is the one signal that separates a lapsed subscription from every other reason a remote
    /// command is refused. Without it a lapse reached the reader as a generic rejection, sitting
    /// next to privacy mode and a sleeping car as equally plausible explanations.
    func fetchVOCSubscriptionImplementation(vin: String) async throws -> Bool? {
        if let cached = subscriptionCache[vin], cached.expiresAt > Date() { return cached.value }
        guard let dto: VolvoVOCSubscriptionDTO = try? await get(
            "/energy/v2/vehicles/\(vin)/voc-subscription", scope: .vehicle(vin)
        ), let value = dto.hasPremiumSubscription else {
            return nil
        }
        subscriptionCache[vin] = (value, Date().addingTimeInterval(3_600))
        return value
    }

    /// Non-throwing wrapper for the telemetry sweep: a subscription that cannot be read is an
    /// unknown, never a reason to fail the whole vehicle read.
    func fetchVOCSubscription(vin: String) async -> Bool? {
        try? await fetchVOCSubscriptionImplementation(vin: vin)
    }
}
