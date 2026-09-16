import Foundation
import Testing
@testable import Hisingen

/// The brand→adapter authority: selection and the live-streaming view. Preparing a session is the
/// adapter's own job (`VehicleProviding.prepareSession()`, defaulted to a no-op), and the point of
/// the module is that no caller writes the brand ternary or downcasts an adapter — so the tests
/// assert selection and the streaming view through the registry, and preparation through the
/// provider interface.
@MainActor
struct ProviderRegistryTests {
    @Test
    func selectionReturnsTheAdapterForEachBrand() {
        let registry = ProviderRegistry(
            polestar: RegistryProbeProvider(brand: .polestar),
            volvo: RegistryProbeProvider(brand: .volvo))

        #expect(registry.provider(for: .polestar).brand == .polestar)
        #expect(registry.provider(for: .volvo).brand == .volvo)
    }

    @Test
    func theStreamingViewAnswersOnlyForTheAdapterThatHasALiveStream() async throws {
        let streaming = RegistryStreamingProbe()
        let registry = ProviderRegistry(
            polestar: streaming, volvo: RegistryProbeProvider(brand: .volvo))

        // The conformance test lives in the registry: a caller that would previously have written
        // `as? any VehicleLiveStreaming` gets a typed view or nil.
        let view = try #require(registry.streaming(for: .polestar))
        var updates = try await view.liveVehicleUpdates(vin: "VIN", purpose: .charging)
            .makeAsyncIterator()
        let first = try await updates.next()
        #expect(first == nil, "the probe's stream finishes without a frame")

        #expect(registry.streaming(for: .volvo) == nil)
    }

    @Test
    func restoringASessionPreparesTheAdapterThroughItsOwnInterface() async throws {
        let suite = "io.kheirallah.hisingen.registry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        // Neither stub is a concrete adapter, so the old `as? VolvoAPI` configuration would have
        // skipped both. Going through `prepareSession()` reaches each of them.
        let polestar = RegistryProbeProvider(brand: .polestar)
        let volvo = RegistryProbeProvider(brand: .volvo)
        let manager = SessionManager(readToken: { _ in "token" }, readPassword: { nil }, clearPassword: {})

        _ = try await manager.restore(api: polestar, preferences: preferences)
        _ = try await manager.restore(api: volvo, preferences: preferences)

        #expect(await polestar.prepareCount == 1)
        #expect(await volvo.prepareCount == 1)
    }

    @Test
    func theDefaultPreparationIsANoOpForAnAdapterThatNeedsNothing() async throws {
        // This stub does not implement `prepareSession()`: the protocol extension's no-op is what
        // keeps every existing adapter and mock conforming without a body of its own.
        let provider = RegistryDefaultPreparationProvider()
        try await provider.prepareSession()
        #expect(await provider.resolvedVIN(preferred: "VIN") == "VIN")
    }
}

private actor RegistryProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand

    init(brand: VehicleBrand) {
        self.brand = brand
    }

    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }
    private(set) var prepareCount = 0

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }

    func prepareSession() async throws { prepareCount += 1 }
}

/// An adapter that leans on the protocol extension's no-op preparation.
private actor RegistryDefaultPreparationProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}

/// An adapter with a live stream, so the registry's streaming lookup has something to find.
private actor RegistryStreamingProbe: VehicleProviding, VehicleLiveStreaming {
    nonisolated let brand: VehicleBrand = .polestar
    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func refreshLiveStreamAuthorization() async throws {}
}
