import Foundation

extension VolvoAPI {
    /// Premium VOC subscription state, the third endpoint of the Energy API family.
    ///
    /// Volvo's documentation is explicit about the scope: "This only affects PHEV Classic
    /// vehicles and does not apply to BEVs and non-classic PHEVs", and a request returns 200 with
    /// the flag "whether or not the vehicle has a premium subscription". So a `false` on a BEV is
    /// not a lapse, not an error and not evidence of anything: the field has no meaning there.
    /// Asking a BEV costs a request per hour to answer a question that does not apply to it, which
    /// is why the read is gated on the powertrain.
    ///
    /// It stays read-only and unraised. For the vehicles it does describe, an expired subscription
    /// means the car stops reporting to the cloud, which the freshness banners already say without
    /// needing this flag to say it first.
    ///
    /// The read goes through `optional`, so a 404 (the endpoint returned three in one second on
    /// 2026-11-21, then 200 nineteen minutes later) stands the endpoint down instead of re-asking
    /// on every refresh.
    func fetchVOCSubscriptionImplementation(vin: String) async throws -> Bool? {
        let dto: VolvoVOCSubscriptionDTO? = try await optional(
            enabled: true, key: "voc-subscription", vin: vin
        ) {
            try await self.get("/energy/v2/vehicles/\(vin)/voc-subscription", scope: .vehicle(vin))
        }
        return dto?.hasPremiumSubscription
    }

    /// Non-throwing wrapper for the telemetry sweep: a subscription that cannot be read is an
    /// unknown, never a reason to fail the whole vehicle read.
    func fetchVOCSubscription(vin: String) async -> Bool? {
        try? await fetchVOCSubscriptionImplementation(vin: vin)
    }

    /// Only a plug-in hybrid can be a "PHEV Classic", and the response says nothing about any
    /// other powertrain, so anything else skips the request entirely.
    func fetchVOCSubscriptionIfRelevant(vin: String, powertrain: PowertrainType) async -> Bool? {
        guard powertrain == .phev else { return nil }
        return await fetchVOCSubscription(vin: vin)
    }
}
