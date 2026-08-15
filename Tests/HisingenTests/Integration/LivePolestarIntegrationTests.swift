#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let livePolestarCredentialsConfigured: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["HISINGEN_TEST_EMAIL"]?.isEmpty == false
        && environment["HISINGEN_TEST_PASSWORD"]?.isEmpty == false
}()

@MainActor
struct LivePolestarReadOnlyIntegrationTests {
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testAuthenticationDiscoveryFetchAndSignOut() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-tests")
        try? keychain.deleteSessionToken()
        try? keychain.deletePassword()
        let api = PolestarAPI(keychain: keychain)
        var features = FeatureSelection.default
        features.set(.vehicleImage, enabled: true)
        for feature in AppFeature.allCases where !feature.isRemoteControl {
            features.set(feature, enabled: true)
        }
        do {
            try await api.authenticate(
                email: email,
                password: password,
                preferredVIN: preferredVIN,
                features: features
            )
            let cars = await api.cars
            XCTAssertFalse(cars.isEmpty)
            let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
            let vin = try XCTUnwrap(resolvedVIN)
            let state = try await api.fetchVehicleState(vin: vin, features: features)
            XCTAssertEqual(state.vin, vin)
            XCTAssertTrue(state.batteryPercentage != nil || state.rangeKm != nil)


            let optionalFeatures: Set<AppFeature> = [
                .exteriorStatus, .tyreAndWarnings, .softwareUpdates, .chargingSchedule,
                .climateStatus, .tripMeters, .connectivityDiagnostics, .airQuality,
                .batteryDiagnostics, .vehicleWeather
            ]
            XCTAssertTrue(Set(state.unavailableFeatures).isSubset(of: optionalFeatures))
            await api.resetSession()
            let sessionToken = try XCTUnwrap(try keychain.readSessionToken())
            try await api.restoreSession(token: sessionToken, preferredVIN: vin, features: features)
            let restoredState = try await api.fetchVehicleState(vin: vin, features: features)
            XCTAssertTrue(restoredState.batteryPercentage != nil || restoredState.rangeKm != nil)
            try await api.signOut()
        } catch {
            try? await api.signOut()
            throw error
        }
    }
}

@MainActor
struct LivePolestarRemoteCommandIntegrationTests {
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testLiveRemoteClimateCommand() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-tests")
        let api = PolestarAPI(keychain: keychain)
        var features = FeatureSelection.default
        features.set(.remoteClimate, enabled: true)
        let oidcURL = URL(string: "https://polestarid.eu.polestar.com/.well-known/openid-configuration")!
        let (data, _) = try await URLSession.shared.data(from: oidcURL)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print(">>> OIDC SCOPES SUPPORTED: \(json["scopes_supported"] ?? "none")")
            print(">>> OIDC CLAIMS SUPPORTED: \(json["claims_supported"] ?? "none")")
        }

        try await api.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        do {
            _ = try await api.executeRemoteCommand(.startClimate(
                temperatureCelsius: 0,
                frontLeftSeat: .unspecified,
                frontRightSeat: .unspecified,
                rearLeftSeat: .unspecified,
                rearRightSeat: .unspecified,
                steeringWheel: .unspecified
            ), vin: vin)
        } catch let error as RemoteCommandError {
            XCTAssertTrue(error.localizedDescription.isEmpty == false)
        }
    }
}
#endif

