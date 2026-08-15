#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen


private let liveVolvoCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["HISINGEN_TEST_VOLVO_CLIENT_ID"]?.isEmpty == false
        && environment["HISINGEN_TEST_VOLVO_CLIENT_SECRET"]?.isEmpty == false
        && environment["HISINGEN_TEST_VOLVO_VCC_API_KEY"]?.isEmpty == false
        && environment["HISINGEN_TEST_VOLVO_REFRESH_TOKEN"]?.isEmpty == false
}()

@MainActor
struct LiveVolvoReadOnlyIntegrationTests {
    @Test(.disabled(if: !liveVolvoCredentialsConfigured, "Live Volvo credentials are not configured"))
    func testResumeDiscoveryFetchAndSessionPersistence() async throws {
        let environment = ProcessInfo.processInfo.environment
        let clientID = try XCTUnwrap(environment["HISINGEN_TEST_VOLVO_CLIENT_ID"])
        let clientSecret = try XCTUnwrap(environment["HISINGEN_TEST_VOLVO_CLIENT_SECRET"])
        let vccApiKey = try XCTUnwrap(environment["HISINGEN_TEST_VOLVO_VCC_API_KEY"])
        let refreshToken = try XCTUnwrap(environment["HISINGEN_TEST_VOLVO_REFRESH_TOKEN"])
        let preferredVIN = environment["HISINGEN_TEST_VOLVO_VIN"].flatMap { $0.isEmpty ? nil : $0 }


        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-tests")
        try? keychain.deleteVolvoSessionToken()
        let api = VolvoAPI(keychain: keychain)

        var features = FeatureSelection.default
        for feature in AppFeature.allCases where !feature.isRemoteControl {
            features.set(feature, enabled: true)
        }

        await api.configure(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey)
        try await api.restoreSession(token: refreshToken, preferredVIN: preferredVIN, features: features)

        let cars = await api.cars
        XCTAssertFalse(cars.isEmpty)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)

        let state = try await api.fetchVehicleState(vin: vin, features: features)
        XCTAssertEqual(state.vin, vin)


        XCTAssertTrue(
            state.batteryPercentage != nil || state.rangeKm != nil
                || state.fuelRangeKm != nil || state.odometerKm != nil
        )
        XCTAssertNotEqual(state.powertrain, .unknown)


        await api.resetSession()
        let persistedToken = try XCTUnwrap(try keychain.readVolvoSessionToken())
        let resumed = VolvoAPI(keychain: keychain)
        await resumed.configure(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey)
        try await resumed.restoreSession(token: persistedToken, preferredVIN: vin, features: features)
        let resumedState = try await resumed.fetchVehicleState(vin: vin, features: features)
        XCTAssertEqual(resumedState.vin, vin)

        try? keychain.deleteVolvoSessionToken()
    }
}
#endif


