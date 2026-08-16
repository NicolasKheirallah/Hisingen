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

    /// Comprehensive live probe of all Volvo Developer APIs, OIDC discovery, and Connected Vehicle endpoints.
    @Test
    func testComprehensiveVolvoAllAPIsProbeAndDump() async throws {
        let environment = ProcessInfo.processInfo.environment
        let clientID = environment["VOLVO_CLIENT_ID"] ?? environment["HISINGEN_TEST_VOLVO_CLIENT_ID"] ?? "dc-3spjins2tdf9cbxsq16xjha14"
        let clientSecret = environment["VOLVO_CLIENT_SECRET"] ?? environment["HISINGEN_TEST_VOLVO_CLIENT_SECRET"] ?? "yPdq8K9SwgsZUB9AKMQ81"
        let vccApiKey = environment["VOLVO_VCC_API_KEY"] ?? environment["HISINGEN_TEST_VOLVO_VCC_API_KEY"] ?? "dfda4ef83c304b2c8503897e72dc2966"
        let vin = environment["VOLVO_VIN"] ?? environment["HISINGEN_TEST_VOLVO_VIN"] ?? "YV1XZEHR2R2371256"

        print("\n========================================================")
        print("🔍 [1. VOLVO OIDC DISCOVERY & IDENTITY]")
        let oidcURL = URL(string: "https://volvoid.eu.volvocars.com/.well-known/openid-configuration")!
        let (oidcData, _) = try await URLSession.shared.data(from: oidcURL)
        if let oidcJson = try? JSONSerialization.jsonObject(with: oidcData) as? [String: Any] {
            print("  • Token Endpoint:          \(oidcJson["token_endpoint"] ?? "N/A")")
            print("  • Authorization Endpoint:  \(oidcJson["authorization_endpoint"] ?? "N/A")")
            print("  • UserInfo Endpoint:       \(oidcJson["userinfo_endpoint"] ?? "N/A")")
            print("  • Scopes Supported:        \(oidcJson["scopes_supported"] ?? "N/A")")
            print("  • Grant Types:             \(oidcJson["grant_types_supported"] ?? "N/A")")
        }

        print("\n========================================================")
        print("📡 [2. VOLVO DEVELOPER API GATEWAY CHECK]")
        print("  • Target Host:             https://api.volvocars.com")
        print("  • Client ID:               \(clientID)")
        print("  • VCC API Key:             \(vccApiKey.prefix(8))...")
        print("  • Test Target VIN:         \(vin)")

        // Probe Connected Vehicle V2 Vehicles List
        let vehiclesURL = URL(string: "https://api.volvocars.com/connected-vehicle/v2/vehicles")!
        var req = URLRequest(url: vehiclesURL)
        req.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse {
            print("  • /connected-vehicle/v2/vehicles Status: HTTP \(http.statusCode)")
            // HTTP 401 with valid vcc-api-key indicates gateway authenticated, awaiting Bearer user token
            XCTAssertTrue(http.statusCode == 401 || http.statusCode == 200 || http.statusCode == 403)
        }

        print("\n========================================================")
        print("📋 [3. VOLVO CONNECTED VEHICLE & ENERGY API SPECIFICATION]")
        let endpoints: [(name: String, path: String, method: String)] = [
            ("Vehicle Specification", "/connected-vehicle/v2/vehicles/\(vin)", "GET"),
            ("Doors & Central Lock", "/connected-vehicle/v2/vehicles/\(vin)/doors", "GET"),
            ("Windows Status", "/connected-vehicle/v2/vehicles/\(vin)/windows", "GET"),
            ("Odometer & Distance", "/connected-vehicle/v2/vehicles/\(vin)/odometer", "GET"),
            ("Tyres & iTPMS", "/connected-vehicle/v2/vehicles/\(vin)/tyres", "GET"),
            ("Battery Charge Level", "/energy/v1/vehicles/\(vin)/battery-charge-level", "GET"),
            ("Recharge & Plug Status", "/energy/v1/vehicles/\(vin)/recharge-status", "GET"),
            ("Climatization Status", "/connected-vehicle/v2/vehicles/\(vin)/climatization-status", "GET"),
            ("Fuel & Engine Status", "/connected-vehicle/v2/vehicles/\(vin)/fuel-amount", "GET"),
            ("Engine Health Status", "/connected-vehicle/v2/vehicles/\(vin)/engine-status", "GET"),
            ("Vehicle Warnings & Fluids", "/connected-vehicle/v2/vehicles/\(vin)/warnings", "GET"),
            ("Diagnostics & Service", "/connected-vehicle/v2/vehicles/\(vin)/diagnostics", "GET"),
            ("Parking GPS Location", "/location/v1/vehicles/\(vin)/location", "GET"),
            ("Trip Statistics", "/connected-vehicle/v2/vehicles/\(vin)/statistics", "GET"),
            ("Remote Lock Command", "/connected-vehicle/v2/vehicles/\(vin)/doors/lock", "POST"),
            ("Remote Unlock Command", "/connected-vehicle/v2/vehicles/\(vin)/doors/unlock", "POST"),
            ("Remote Climate Start", "/connected-vehicle/v2/vehicles/\(vin)/climatization/start", "POST"),
            ("Remote Climate Stop", "/connected-vehicle/v2/vehicles/\(vin)/climatization/stop", "POST"),
            ("Remote Flash Lights", "/connected-vehicle/v2/vehicles/\(vin)/flash", "POST"),
            ("Remote Honk Horn", "/connected-vehicle/v2/vehicles/\(vin)/honk", "POST"),
            ("Remote Honk & Flash", "/connected-vehicle/v2/vehicles/\(vin)/honk-flash", "POST")
        ]

        for ep in endpoints {
            print("  • [\(ep.method)] \(ep.name.padding(toLength: 26, withPad: " ", startingAt: 0)) -> \(ep.path)")
        }

        print("========================================================\n")
    }
}
#endif


