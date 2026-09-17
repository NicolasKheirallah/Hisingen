#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let livePortalCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["POLESTAR_CLIENT_ID"]?.isEmpty == false
        && environment["POLESTAR_CLIENT_SECRET"]?.isEmpty == false
}()

@MainActor
struct LivePolestarDataPortalIntegrationTests {
    @Test(
        .disabled(
            if: !livePortalCredentialsConfigured,
            "Polestar Data Portal credentials are not configured in environment"
        )
    )
    func testLivePortalTokenGrantAndDiscovery() async throws {
        let env = ProcessInfo.processInfo.environment
        let clientID = try #require(env["POLESTAR_CLIENT_ID"])
        let clientSecret = try #require(env["POLESTAR_CLIENT_SECRET"])
        let accountID = env["POLESTAR_ACCOUNT_ID"] ?? "0a7f033f-4e9c-4473-9b7a-c5998b44da23"
        let preferredVIN = env["POLESTAR_VIN"]

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-portal.\(UUID().uuidString)")
        try? keychain.deletePolestarDataPortalCredentials()
        try? keychain.deletePolestarDataPortalToken()
        defer {
            try? keychain.deletePolestarDataPortalCredentials()
            try? keychain.deletePolestarDataPortalToken()
        }

        try keychain.savePolestarDataPortalCredentials(
            accountID: accountID,
            clientID: clientID,
            clientSecret: clientSecret
        )

        let suite = "io.kheirallah.hisingen.live-portal-prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.polestarConnectionMode = .dataPortal
        preferences.polestarDataPortalAccountID = accountID
        preferences.polestarDataPortalClientID = clientID

        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences)
        try await api.restoreSession(token: "unused", preferredVIN: preferredVIN, features: .default)

        let token = try await api.ensureAccessToken()
        #expect(!token.isEmpty)
        #expect(await api.hasWarmSession == true)

        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        #expect(resolved == preferredVIN)

        let targetVIN = preferredVIN ?? "YSMVSEDE6PL147228"
        let state = try await api.fetchVehicleState(vin: targetVIN, features: .default)
        #expect(state.identity.modelName == "Polestar")
        #expect(state.identity.vin == targetVIN)

        try await api.signOut()
        #expect(await api.hasWarmSession == false)
    }
}
#endif
