import Foundation
import Testing
@testable import Hisingen

@MainActor
struct SessionManagerTests {
    @Test
    func routineResumePrefersTokenAndRecoversUsingTheRotatedStoredToken() async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        let provider = SessionTestProvider(brand: .polestar)
        var storedToken = "first"
        var passwordCleared = false
        let manager = SessionManager(readToken: { _ in storedToken }, readPassword: { Issue.record("A valid token must not read the password"); return "password" },
                                     clearPassword: { passwordCleared = true })
        try await manager.restore(api: provider, preferences: preferences)
        storedToken = "rotated"
        try await manager.restore(api: provider, preferences: preferences)
        #expect(await provider.calls == ["restore:first", "restore:rotated"])
        #expect(!passwordCleared)
    }

    @Test
    func deniedTokenReadStopsWithoutPasswordFallback() async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        let provider = SessionTestProvider(brand: .polestar)
        let manager = SessionManager(readToken: { _ in throw KeychainError.status(-128) },
            readPassword: { Issue.record("Denied token access must not trigger a password prompt"); return nil })
        do {
            try await manager.restore(api: provider, preferences: preferences)
            Issue.record("Expected Keychain access failure")
        } catch {
            #expect(error is KeychainError)
        }
        #expect(await provider.calls.isEmpty)
    }

    @Test
    func changedCredentialsUsePasswordBeforeAStoredToken() async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.email = "new@example.invalid"
        let provider = SessionTestProvider(brand: .polestar)
        var cleared = false
        let manager = SessionManager(readToken: { _ in Issue.record("Changed credentials must not read the old token"); return "old-token" }, readPassword: { "new-password" },
                                     clearPassword: { cleared = true })
        try await manager.restore(api: provider, preferences: preferences, intent: .credentialsChanged)
        #expect(await provider.calls == ["authenticate:new@example.invalid:new-password"])
        #expect(cleared)
    }

    @Test(arguments: [true, false])
    func onlyAuthenticationFailuresAllowPasswordFallback(authenticationFailure: Bool) async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.email = "person@example.invalid"
        let provider = SessionTestProvider(brand: .polestar)
        await provider.failRestore(with: authenticationFailure
            ? .authenticationRequired(provider: .polestar, reason: .expiredSession)
            : .rateLimited(retryAfter: 30))
        var cleared = false
        let manager = SessionManager(readToken: { _ in "token" }, readPassword: {
                                         #expect(authenticationFailure)
                                         return "password"
                                     },
                                     clearPassword: { cleared = true })
        do {
            try await manager.restore(api: provider, preferences: preferences)
            #expect(authenticationFailure)
        } catch {
            #expect(!authenticationFailure)
            guard case .rateLimited(let retryAfter) = error as? VehicleServiceError else {
                Issue.record("Expected the original rate-limit failure")
                return
            }
            #expect(retryAfter == 30)
        }
        #expect(await provider.calls.count == (authenticationFailure ? 2 : 1))
        #expect(cleared == authenticationFailure)
    }

    @Test
    func failedNewCredentialsAreRetainedAndDoNotFallBackToOldToken() async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.email = "person@example.invalid"
        let provider = SessionTestProvider(brand: .polestar)
        await provider.failAuthentication()
        var cleared = false
        let manager = SessionManager(readToken: { _ in "old-token" }, readPassword: { "wrong" },
                                     clearPassword: { cleared = true })
        do {
            try await manager.restore(api: provider, preferences: preferences, intent: .credentialsChanged)
            Issue.record("Invalid new credentials must fail")
        } catch {
            #expect(VehicleServiceError.map(error, provider: .polestar).requiresAuthentication)
        }
        #expect(await provider.calls == ["authenticate:person@example.invalid:wrong"])
        #expect(!cleared)
    }

    @Test
    func volvoUsesItsOwnTokenAndConfigurationWithoutReadingPolestarPassword() async throws {
        let suite = "SessionManagerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.activeBrand = .polestar
        preferences.setVin("VOLVO", for: .volvo)
        let provider = SessionTestProvider(brand: .volvo)
        let manager = SessionManager(readToken: { $0 == .volvo ? "volvo-token" : "polestar-token" },
                                     readPassword: { Issue.record("Volvo must not read a Polestar password"); return nil },
                                     clearPassword: { Issue.record("Volvo must not delete a Polestar password") },
                                     configure: { api, _ in
                                         #expect(api.brand == .volvo)
                                         await provider.recordConfiguration()
                                     })
        try await manager.restore(api: provider, preferences: preferences)
        #expect(await provider.calls == ["configure", "restore:volvo-token"])
        #expect(await provider.lastVIN == "VOLVO")
    }
}

actor SessionTestProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand
    var cars: [CarSummary] { [CarSummary(vin: lastVIN ?? "P1", title: "Test vehicle")] }
    var hasWarmSession: Bool { true }
    private(set) var calls: [String] = []
    private(set) var lastVIN: String?
    private var restoreError: VehicleServiceError?
    private var authenticationFails = false

    init(brand: VehicleBrand) { self.brand = brand }
    func recordConfiguration() { calls.append("configure") }
    func failRestore(with error: VehicleServiceError) { restoreError = error }
    func failAuthentication() { authenticationFails = true }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        calls.append("authenticate:\(email):\(password)")
        if authenticationFails { throw VehicleServiceError.authenticationRequired(provider: brand, reason: .expiredSession) }
        lastVIN = preferredVIN
    }
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        calls.append("restore:\(token)")
        if let restoreError { throw restoreError }
        lastVIN = preferredVIN
    }
    func resetSession() async { calls.append("reset") }
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred ?? lastVIN ?? "P1" }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin, brand: brand)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        .init(outcome: .completed, message: nil)
    }
}
