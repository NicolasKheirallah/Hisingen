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
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func refreshCoordinatorsConstructPerBrandAndStartIdle() async throws {
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
        #expect(!(polestarCoordinator.isBusy))
        #expect(!(volvoCoordinator.isBusy))
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
        #expect(preservedToken == "valid-volvo-refresh-token", "Failed restoreSession must not delete stored Volvo token")
    }

    @Test
    func polestarRestoreSessionDeadGrantSurfacesNoStoredSessionAndClearsKeychain() async throws {
        let keyService = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keyService)
        defer {
            try? keychain.deleteSessionToken()
        }

        try keychain.saveSessionToken("dead-polestar-refresh-token")
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let polestarAPI = PolestarAPI(keychain: keychain, preferences: preferences)

        // Stub the IdP: real discovery document, then a 400 invalid_grant for the token
        // exchange, so the dead-grant contract is exercised without the live network.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeadGrantTransport.self]
        await polestarAPI.installRestoreTestSession(URLSession(configuration: configuration))

        do {
            try await polestarAPI.restoreSession(token: "dead-polestar-refresh-token", preferredVIN: nil, features: .default)
            Issue.record("A dead refresh grant must not restore a session")
        } catch PolestarError.authenticationRequired(.noStoredSession) {
            // expected: a dead grant surfaces as .noStoredSession (API-07)
        } catch {
            Issue.record("expected .noStoredSession for a dead grant, got \(error)")
        }

        // API-07: the rejected grant is dropped from memory AND storage so nothing can
        // keep replaying a rotated-out token against the IdP.
        #expect(try keychain.readSessionToken() == nil,
                "a dead refresh grant must clear the stored Polestar token")
    }

    @Test
    func transientTokenEndpointFailureKeepsTheStoredRefreshToken() async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteSessionToken() }
        try keychain.saveSessionToken("valid-polestar-refresh-token")

        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let polestarAPI = PolestarAPI(keychain: keychain, preferences: preferences)

        // A 5xx is the IdP being unavailable, not the grant being dead. Discarding here would
        // trade a transient outage for a credential prompt the user cannot satisfy offline.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerErrorTransport.self]
        await polestarAPI.installRestoreTestSession(URLSession(configuration: configuration))

        do {
            try await polestarAPI.restoreSession(token: "valid-polestar-refresh-token", preferredVIN: nil, features: .default)
            Issue.record("a 5xx token exchange must not restore a session")
        } catch {
            // expected: the caller sees a transient failure
        }

        #expect(try keychain.readSessionToken() == "valid-polestar-refresh-token",
                "a 5xx token exchange must not discard a grant that may still be valid")
    }

    @Test
    func statusItemControllerAvailableVehiclesIncludesAllFleetVINs() {
        let cars = [
            CarSummary(vin: Self.polestarVin1, title: "Polestar 1"),
            CarSummary(vin: Self.polestarVin2, title: "Polestar 2")
        ]
        var cachedSnapshots: [String: VehicleState] = [:]
        cachedSnapshots[Self.volvoVin1] = vehicle(vin: Self.volvoVin1, brand: .volvo)
        cachedSnapshots[Self.volvoVin2] = vehicle(vin: Self.volvoVin2, brand: .volvo)

        let available = FleetSnapshot(cars: cars, snapshots: cachedSnapshots).vehicles
        #expect(available.count == 4)
        #expect(available.contains(Self.polestarVin1))
        #expect(available.contains(Self.polestarVin2))
        #expect(available.contains(Self.volvoVin1))
        #expect(available.contains(Self.volvoVin2))
    }

    @Test
    func testAutomationHandoffResolvesByNicknameOrVIN() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.setVin(Self.volvoVin1, for: .volvo)
        preferences.setVehicleNickname("My Swedish Wagon", for: Self.volvoVin1)

        let resolvedDirect = AutomationHandoff.resolveVIN(from: Self.volvoVin1, preferences: preferences)
        #expect(resolvedDirect == Self.volvoVin1)

        let resolvedNickname = AutomationHandoff.resolveVIN(from: "Swedish Wagon", preferences: preferences)
        #expect(resolvedNickname == Self.volvoVin1)
    }

    @Test
    func testPerVehicleThemeAssignment() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)

        preferences.setTheme(.swedishGold, for: Self.polestarVin1, brand: .polestar)
        preferences.setTheme(.volvo, for: Self.volvoVin1, brand: .volvo)

        #expect(preferences.theme(for: Self.polestarVin1) == .swedishGold)
        #expect(preferences.theme(for: Self.volvoVin1) == .volvo)
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
    var hasWarmSession: Bool { !vins.isEmpty }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { vins.first }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState { vehicle(vin: vin, brand: brand) }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}

/// Serves a valid Polestar discovery document and answers the token exchange with a response
/// supplied by the subclass. Separate subclasses rather than one configurable static: test
/// suites run in parallel and a mutable static would race.
private class TokenEndpointTransport: URLProtocol, @unchecked Sendable {
    class var tokenStatus: Int { 400 }
    class var tokenBody: Data { Data(#"{"error":"invalid_grant"}"#.utf8) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(string: "https://polestarid.eu.polestar.com")!
        let body: Data
        let status: Int
        if url.path.hasSuffix(".well-known/openid-configuration") {
            status = 200
            body = Data(#"""
            {"issuer":"https://polestarid.eu.polestar.com",
             "token_endpoint":"https://polestarid.eu.polestar.com/token",
             "authorization_endpoint":"https://polestarid.eu.polestar.com/authorize",
             "userinfo_endpoint":"https://polestarid.eu.polestar.com/userinfo"}
            """#.utf8)
        } else {
            status = Self.tokenStatus
            body = Self.tokenBody
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The OAuth marker of a permanently dead grant (invalid_grant), deterministically.
private final class DeadGrantTransport: TokenEndpointTransport {
    override class var tokenStatus: Int { 400 }
    override class var tokenBody: Data {
        Data(#"{"error":"invalid_grant","error_description":"Token has been revoked"}"#.utf8)
    }
}

/// The IdP answering 5xx, which says nothing about whether the grant is still valid.
private final class ServerErrorTransport: TokenEndpointTransport {
    override class var tokenStatus: Int { 500 }
    override class var tokenBody: Data { Data(#"{"error":"server_error"}"#.utf8) }
}

private extension PolestarAPI {
    func installRestoreTestSession(_ transport: URLSession) {
        session.invalidateAndCancel()
        session = transport
    }
}
