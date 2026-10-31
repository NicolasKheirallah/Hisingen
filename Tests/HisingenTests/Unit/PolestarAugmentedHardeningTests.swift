import Foundation
import Testing
@testable import Hisingen

struct PolestarAugmentedHardeningTests {
    @Test func locationOnlyDoesNotFetchConsumerSnapshot() async throws {
        let primary = AugmentedHardeningProvider(battery: nil, model: "Portal")
        let fallback = AugmentedHardeningProvider(battery: 80, model: "Consumer")
        let provider = PolestarAugmentedProvider(telemetryProvider: primary, commandProvider: fallback)
        let state = try await provider.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleLocation]))
        #expect(state.identity.modelName == "Portal")
        #expect(await fallback.fetchCount == 0)
    }

    @Test func batteryFallbackPreservesPortalValues() async throws {
        let primary = AugmentedHardeningProvider(battery: nil, model: "Portal")
        let fallback = AugmentedHardeningProvider(battery: 80, model: "Consumer")
        let provider = PolestarAugmentedProvider(telemetryProvider: primary, commandProvider: fallback)
        let state = try await provider.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.chargingDetails]))
        #expect(state.identity.modelName == "Portal")
        #expect(state.energy.batteryPercentage == 80)
        #expect(state.freshness.servedByFallback == true)
        #expect(await fallback.fetchCount == 1)
    }
    @Test func cancellationDoesNotStartFallback() async throws {
        let primary = AugmentedHardeningProvider(battery: nil, model: "Portal", cancel: true)
        let fallback = AugmentedHardeningProvider(battery: 80, model: "Consumer")
        let provider = PolestarAugmentedProvider(telemetryProvider: primary, commandProvider: fallback)
        do {
            _ = try await provider.fetchVehicleState(vin: "VIN", features: .default)
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
        #expect(await fallback.fetchCount == 0)
    }

}

private actor AugmentedHardeningProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let battery: Double?
    let model: String
    let cancel: Bool
    private(set) var fetchCount = 0
    init(battery: Double?, model: String, cancel: Bool = false) { self.battery = battery; self.model = model; self.cancel = cancel }
    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws { }
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws { }
    func resetSession() async { }
    func signOut() async throws { }
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws { }
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        if cancel { throw CancellationError() }
        return VehicleState(energy: EnergyAndChargingSnapshot(batteryPercentage: battery),
                            identity: VehicleIdentitySnapshot(availability: .unknown, modelName: model, vin: vin),
                            freshness: SnapshotFreshness(fetchedAt: Date(), readingObservations: [:]))
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        throw RemoteCommandError.unsupported
    }
}
