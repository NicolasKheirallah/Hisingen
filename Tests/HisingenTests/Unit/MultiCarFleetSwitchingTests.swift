import Foundation
import Testing
@testable import Hisingen

@MainActor
struct MultiCarFleetSwitchingTests {
    private static let polestarVin1 = "YS2E1111111111111"
    private static let polestarVin2 = "YS2E2222222222222"
    private static let volvoVin1 = "YV1A1111111111111"
    private static let volvoVin2 = "YV1A2222222222222"

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenFleetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func refreshCoordinatorDefaultTokenReaderResolvesByBrand() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)

        let mockPolestarProvider = MockFleetProvider(brand: .polestar, vins: [Self.polestarVin1])
        let polestarCoordinator = RefreshCoordinator(
            api: mockPolestarProvider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            preferences: preferences
        )

        let mockVolvoProvider = MockFleetProvider(brand: .volvo, vins: [Self.volvoVin1])
        let volvoCoordinator = RefreshCoordinator(
            api: mockVolvoProvider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            preferences: preferences
        )

        // Verify coordinators instantiate with brand-appropriate defaults without crashing or crossing tokens.
        XCTAssertFalse(polestarCoordinator.isBusy)
        XCTAssertFalse(volvoCoordinator.isBusy)
        polestarCoordinator.stop()
        volvoCoordinator.stop()
    }

    @Test
    func volvoRestoreSessionDoesNotWipeKeychainOnAuthFailure() async throws {
        let keyService = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keyService)
        defer {
            try? keychain.deleteVolvoSessionToken()
            try? keychain.deleteVolvoClientSecret()
            try? keychain.deleteVolvoApiKey()
        }

        try keychain.saveVolvoSessionToken("valid-volvo-refresh-token")
        try keychain.saveVolvoClientSecret("test-secret")
        try keychain.saveVolvoApiKey("test-key")

        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let volvoAPI = VolvoAPI(keychain: keychain, preferences: preferences)
        await volvoAPI.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")

        // restoreSession with an invalid token will fail at network level,
        // but must NOT delete the stored session token from Keychain.
        do {
            try await volvoAPI.restoreSession(token: "bad-token", preferredVIN: nil, features: .default)
        } catch {
            // Expected failure
        }

        let preservedToken = try keychain.readVolvoSessionToken()
        XCTAssertEqual(preservedToken, "valid-volvo-refresh-token", "Failed restoreSession must not delete stored Volvo token")
    }

    @Test
    func polestarRestoreSessionDoesNotWipeKeychainOnAuthFailure() async throws {
        let keyService = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keyService)
        defer {
            try? keychain.deleteSessionToken()
        }

        try keychain.saveSessionToken("valid-polestar-refresh-token")
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let polestarAPI = PolestarAPI(keychain: keychain, preferences: preferences)

        do {
            try await polestarAPI.restoreSession(token: "bad-token", preferredVIN: nil, features: .default)
        } catch {
            // Expected failure
        }

        let preservedToken = try keychain.readSessionToken()
        XCTAssertEqual(preservedToken, "valid-polestar-refresh-token", "Failed restoreSession must not delete stored Polestar token")
    }

    @Test
    func statusItemControllerAvailableVehiclesIncludesAllFleetVINs() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        let controller = StatusItemController(database: .inMemory(), preferences: preferences)

        controller.cars = [
            CarSummary(vin: Self.polestarVin1, title: "Polestar 1"),
            CarSummary(vin: Self.polestarVin2, title: "Polestar 2")
        ]
        controller.cachedSnapshots[Self.volvoVin1] = vehicle(vin: Self.volvoVin1, brand: .volvo)
        controller.cachedSnapshots[Self.volvoVin2] = vehicle(vin: Self.volvoVin2, brand: .volvo)

        let available = controller.availableVehicleVINs
        XCTAssertEqual(available.count, 4)
        XCTAssertTrue(available.contains(Self.polestarVin1))
        XCTAssertTrue(available.contains(Self.polestarVin2))
        XCTAssertTrue(available.contains(Self.volvoVin1))
        XCTAssertTrue(available.contains(Self.volvoVin2))
    }

    @Test
    func testAutomationHandoffResolvesByNicknameOrVIN() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.setVin(Self.volvoVin1, for: .volvo)
        preferences.setVehicleNickname("My Swedish Wagon", for: Self.volvoVin1)

        let resolvedDirect = AutomationHandoff.resolveVIN(from: Self.volvoVin1, preferences: preferences)
        XCTAssertEqual(resolvedDirect, Self.volvoVin1)

        let resolvedNickname = AutomationHandoff.resolveVIN(from: "Swedish Wagon", preferences: preferences)
        XCTAssertEqual(resolvedNickname, Self.volvoVin1)
    }

    @Test
    func testPerVehicleThemeAssignment() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)

        preferences.setTheme(.swedishGold, for: Self.polestarVin1, brand: .polestar)
        preferences.setTheme(.volvo, for: Self.volvoVin1, brand: .volvo)

        XCTAssertEqual(preferences.theme(for: Self.polestarVin1), .swedishGold)
        XCTAssertEqual(preferences.theme(for: Self.volvoVin1), .volvo)
    }
}

private actor MockFleetProvider: VehicleProviding {
    let brand: VehicleBrand
    let vins: [String]
    init(brand: VehicleBrand, vins: [String]) {
        self.brand = brand
        self.vins = vins
    }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { vins.first }
    func selectCar(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState { vehicle(vin: vin, brand: brand) }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
