import Foundation

extension VolvoAPI {
    func fetchEnergyCapabilitiesImplementation(vin: String) async throws -> VolvoEnergyCapabilitiesDTO? {
        if let cached = capabilityCache[vin], cached.expiresAt > Date() { return cached.value }
        guard let caps: VolvoEnergyCapabilitiesDTO = try? await get("/energy/v2/vehicles/\(vin)/capabilities") else {
            return nil
        }
        capabilityCache[vin] = (caps, Date().addingTimeInterval(3_600))
        return caps
    }


    func fetchEnergyCapabilities(vin: String) async throws -> VolvoEnergyCapabilitiesDTO? {
        try await fetchEnergyCapabilitiesImplementation(vin: vin)
    }
}
