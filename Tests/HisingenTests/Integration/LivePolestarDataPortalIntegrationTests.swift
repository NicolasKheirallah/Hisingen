#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let livePortalCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    if environment["POLESTAR_CLIENT_ID"]?.isEmpty == false
        && environment["POLESTAR_CLIENT_SECRET"]?.isEmpty == false {
        return true
    }
    return !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
        && !BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty
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
        let clientID = env["POLESTAR_CLIENT_ID"] ?? BuiltinPolestarSecrets.dataPortalClientID
        let clientSecret = env["POLESTAR_CLIENT_SECRET"] ?? BuiltinPolestarSecrets.dataPortalClientSecret
        let envAccountID = env["POLESTAR_ACCOUNT_ID"]
        let accountID = (envAccountID?.isEmpty == false) ? envAccountID! : (BuiltinPolestarSecrets.dataPortalAccountID.isEmpty ? "0a7f033f-4e9c-4473-9b7a-c5998b44da23" : BuiltinPolestarSecrets.dataPortalAccountID)
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

        let (vehicleCount, _) = try await api.testConnection()
        #expect(vehicleCount >= 0)

        let isWarm = await api.hasWarmSession
        if preferredVIN != nil || vehicleCount > 0 {
            #expect(isWarm == true)
        } else {
            #expect(isWarm == false)
        }

        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        if let preferredVIN {
            #expect(resolved == preferredVIN)
        } else {
            // No preference given: resolution falls to the discovered garage, so a bound
            // VIN must be selected rather than the empty-garage nil.
            #expect(resolved != nil)
        }

        let targetVIN = preferredVIN ?? "YSMVSEDE6PL147228"
        do {
            let state = try await api.fetchVehicleState(vin: targetVIN, features: .default)
            // The M2M surface carries no model metadata; assembly deliberately leaves the
            // name nil so a name fetched by the consumer API survives the state merge.
            #expect(state.identity.modelName == nil)
            #expect(state.identity.vin == targetVIN)
        } catch PolestarDataPortalError.permissionDenied {
            // VIN telemetry consent is provisioned out-of-band on the account (EU Data Act
            // authorization). When the server revokes or lapses it, that is an account
            // state this smoke test cannot control — skip visibly instead of failing the
            // suite; any other error still fails.
            print("LIVE PORTAL SKIP: VIN \(targetVIN) lacks telemetry consent (AUTHZ_VIN_UNAUTHORIZED); re-provision the account to run the full smoke path.")
        }

        try await api.signOut()
        #expect(await api.hasWarmSession == false)
    }
}
#endif
