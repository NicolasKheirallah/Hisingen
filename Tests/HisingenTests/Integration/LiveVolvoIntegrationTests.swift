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
        let login = environment["POLESTAR_LOGIN"] ?? environment["HISINGEN_TEST_EMAIL"] ?? "nicolas.kheirallah@gmail.com"
        let pass = environment["POLESTAR_PASS"] ?? environment["HISINGEN_TEST_PASSWORD"] ?? "satdoj-4kowho-zuFbuf"

        print("\n========================================================")
        print("🔍 [1. VOLVO OIDC DISCOVERY & IDENTITY]")
        let oidcURL = URL(string: "https://volvoid.eu.volvocars.com/.well-known/openid-configuration")!
        let (oidcData, _) = try await URLSession.shared.data(from: oidcURL)
        if let oidcJson = try? JSONSerialization.jsonObject(with: oidcData) as? [String: Any] {
            print("  • Token Endpoint:          \(oidcJson["token_endpoint"] ?? "N/A")")
            print("  • Authorization Endpoint:  \(oidcJson["authorization_endpoint"] ?? "N/A")")
            print("  • UserInfo Endpoint:       \(oidcJson["userinfo_endpoint"] ?? "N/A")")
            print("  • Scopes Supported Count:  \((oidcJson["scopes_supported"] as? [String])?.count ?? 0)")
            print("  • Grant Types Supported:   \(oidcJson["grant_types_supported"] ?? "N/A")")
        }

        print("\n========================================================")
        print("🔑 [2. VOLVO TOKEN ENDPOINT PROBE]")
        var token: String? = nil

        // Probe 2a: client_credentials grant
        let tokenURL = URL(string: "https://volvoid.eu.volvocars.com/as/token.oauth2")!
        var ccReq = URLRequest(url: tokenURL)
        ccReq.httpMethod = "POST"
        ccReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let authBasic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        ccReq.setValue("Basic \(authBasic)", forHTTPHeaderField: "Authorization")
        ccReq.httpBody = "grant_type=client_credentials".data(using: .utf8)
        let (ccData, ccRes) = try await URLSession.shared.data(for: ccReq)
        let ccHttp = ccRes as? HTTPURLResponse
        print("  • Client Credentials Status: HTTP \(ccHttp?.statusCode ?? 0)")
        if let ccJson = try? JSONSerialization.jsonObject(with: ccData) as? [String: Any] {
            if let err = ccJson["error"] {
                print("    - Result: error=\(err), desc=\(ccJson["error_description"] ?? "")")
            } else if let tok = ccJson["access_token"] as? String {
                print("    - Acquired Client Token: \(tok.prefix(15))...")
                token = tok
            }
        }

        // Probe 2b: Resource Owner Password Credentials (ROPC)
        var ropcReq = URLRequest(url: tokenURL)
        ropcReq.httpMethod = "POST"
        ropcReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        ropcReq.setValue("Basic \(authBasic)", forHTTPHeaderField: "Authorization")
        let ropcBody = "grant_type=password&username=\(login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&password=\(pass.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&scope=openid"
        ropcReq.httpBody = ropcBody.data(using: .utf8)
        let (ropcData, ropcRes) = try await URLSession.shared.data(for: ropcReq)
        let ropcHttp = ropcRes as? HTTPURLResponse
        print("  • ROPC Password Grant Status: HTTP \(ropcHttp?.statusCode ?? 0)")
        if let ropcJson = try? JSONSerialization.jsonObject(with: ropcData) as? [String: Any] {
            if let err = ropcJson["error"] {
                print("    - Result: error=\(err), desc=\(ropcJson["error_description"] ?? "")")
            } else if let tok = ropcJson["access_token"] as? String {
                print("    - Acquired User Token: \(tok.prefix(15))...")
                token = tok
            }
        }

        print("\n========================================================")
        print("📡 [3. VOLVO DEVELOPER API GATEWAY & LIVE ENDPOINTS]")
        print("  • Target Host:             https://api.volvocars.com")
        print("  • Client ID:               \(clientID)")
        print("  • VCC API Key:             \(vccApiKey.prefix(8))...")
        print("  • Target VIN:              \(vin)")

        let endpoints: [(name: String, path: String, method: String)] = [
            ("Vehicles Discovery", "/connected-vehicle/v2/vehicles", "GET"),
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
            ("Extended Vehicle Telematics", "/extended-vehicle/v1/vehicles/\(vin)/resources", "GET")
        ]

        for ep in endpoints {
            let url = URL(string: "https://api.volvocars.com\(ep.path)")!
            var req = URLRequest(url: url)
            req.httpMethod = ep.method
            req.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, res) = try await URLSession.shared.data(for: req)
            let http = res as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let statusBadge = (200...299).contains(status) ? "✅ HTTP \(status)" : (status == 401 ? "🔒 HTTP 401 (Auth Required)" : "⚠️ HTTP \(status)")
            print("  • [\(ep.method)] \(ep.name.padding(toLength: 28, withPad: " ", startingAt: 0)) -> \(statusBadge)")
            if let bodyStr = String(data: data, encoding: .utf8), !bodyStr.isEmpty, status != 401 {
                let trimmed = bodyStr.trimmingCharacters(in: .whitespacesAndNewlines)
                print("    Payload: \(trimmed.prefix(120))...")
            }
        }

        print("\n========================================================")
        print("🎨 [4. VOLVO CAS & STUDIO IMAGE CDN PROBE]")
        let cdnURLs: [(name: String, url: String)] = [
            ("Volvo Global Image CDN", "https://images.volvocars.com/is/image/VolvoInformationTechnologyAB/xc40_exterior"),
            ("Volvo CAS Configurator V1", "https://cas.volvocars.com/image/v1/cars/volvo/2024/XC40/exterior/front-three-quarter.png"),
            ("Volvo Static Assets CDN", "https://www.volvocars.com/static/cars/xc40-recharge.png")
        ]

        for cdn in cdnURLs {
            if let u = URL(string: cdn.url) {
                var req = URLRequest(url: u)
                req.httpMethod = "HEAD"
                let (_, res) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
                let status = (res as? HTTPURLResponse)?.statusCode ?? 0
                print("  • \(cdn.name.padding(toLength: 28, withPad: " ", startingAt: 0)) -> HTTP \(status)")
            }
        }

        print("========================================================\n")
    }
}
#endif


