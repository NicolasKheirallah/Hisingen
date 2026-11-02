import Foundation
import Testing
@testable import Hisingen

@MainActor
struct RefreshCancellationTests {
    @Test(arguments: [true, false])
    func providerCancellationRetriesWithoutReportingANetworkFailure(duringRestore: Bool) async throws {
        let suite = "RefreshCancellationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.vin = "VIN-A"
        let provider = CancelledRefreshProvider(cancelRestore: duringRestore)
        let delays = TestEvent<TimeInterval>()
        let ticks = TestEvent<Void>()
        let states = TestEvent<Void>()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        var failures = 0
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            scheduler: AsyncTimerLoop(wait: { delay in
                await delays.yield(delay)
                _ = try await ticks.next()
            }),
            now: { instant }
        )
        defer { coordinator.stop(); ticks.cancel() }
        coordinator.onEvent = { event in
            if case .failed = event { failures += 1 }
            if case .state = event { states.yield(()) }
        }
        coordinator.start(preferredVIN: "VIN-A")
        if !duringRestore {
            _ = try await states.next()
            _ = try await delays.next()
            await provider.cancelNextReading()
            coordinator.refreshNow()
        }
        #expect(try await delays.next() == 5)
        #expect(failures == 0)
        #expect(coordinator.refreshFailures == 0)
        #expect(coordinator.lastError == nil)
        ticks.yield(())
        _ = try await states.next()
        #expect(coordinator.lastError == nil)
        #expect(await provider.restoreCount == (duringRestore ? 2 : 1))
    }
}

private actor CancelledRefreshProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "VIN-A", title: "Polestar")]
    var hasWarmSession: Bool { restoreCount > 0 }
    private var cancelRestore: Bool
    private var cancelReading = false
    private(set) var restoreCount = 0

    init(cancelRestore: Bool) { self.cancelRestore = cancelRestore }
    func cancelNextReading() { cancelReading = true }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        restoreCount += 1
        if cancelRestore {
            cancelRestore = false
            throw CancellationError()
        }
    }
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? "VIN-A" }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        if cancelReading {
            cancelReading = false
            throw CancellationError()
        }
        return vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        .init(outcome: .completed, message: nil)
    }
}
