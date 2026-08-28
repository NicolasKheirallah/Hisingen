#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let livePolestarCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["HISINGEN_TEST_EMAIL"]?.isEmpty == false
        && environment["HISINGEN_TEST_PASSWORD"]?.isEmpty == false
}()

/// Credential-gated smoke test for the supported Polestar read path. This suite must remain
/// read-only: it runs automatically in CI against a dedicated account, so probe experiments
/// and remote commands belong in an explicitly opted-in local tool, never here.
@MainActor
struct LivePolestarReadOnlyIntegrationTests {
    @Test(.disabled(if: !livePolestarCredentialsConfigured,
                    "Live Polestar credentials are not configured"))
    func testAuthenticationDiscoveryFetchRestoreAndSignOut() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-tests")
        try? keychain.deleteSessionToken()
        try? keychain.deletePassword()
        defer {
            try? keychain.deleteSessionToken()
            try? keychain.deletePassword()
        }

        let api = PolestarAPI(keychain: keychain)
        var features = FeatureSelection.default
        for feature in AppFeature.allCases where !feature.isRemoteControl {
            features.set(feature, enabled: true)
        }

        do {
            try await api.authenticate(
                email: email, password: password, preferredVIN: preferredVIN, features: features
            )
            let cars = await api.cars
            XCTAssertFalse(cars.isEmpty)
            let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
            let vin = try XCTUnwrap(resolvedVIN)
            let state = try await api.fetchVehicleState(vin: vin, features: features)
            XCTAssertEqual(state.vin, vin)
            XCTAssertTrue(state.batteryPercentage != nil || state.rangeKm != nil)

            await api.resetSession()
            let token = try XCTUnwrap(try keychain.readSessionToken())
            try await api.restoreSession(token: token, preferredVIN: vin, features: features)
            let restored = try await api.fetchVehicleState(vin: vin, features: features)
            XCTAssertEqual(restored.vin, vin)
            try await api.signOut()
        } catch {
            try? await api.signOut()
            throw error
        }
    }
}
#endif
