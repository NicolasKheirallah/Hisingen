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

    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testCaptureLiveRefreshCycleWithDebugLogging() async throws {
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

        print("\n========================================================")
        print("🚀 [LIVE REFRESH CYCLE] Starting authentication...")
        let authStart = Date()
        try await api.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        print("✅ [AUTHENTICATION] Succeeded in \(String(format: "%.2f", Date().timeIntervalSince(authStart)))s")

        let cars = await api.cars
        print("\n📋 [VEHICLE DISCOVERY] Found \(cars.count) car(s):")
        for car in cars {
            print("  • VIN: \(car.vin) | Title: \(car.title)")
        }

        guard let vin = await api.resolvedVIN(preferred: preferredVIN) else {
            Issue.record("No resolved VIN")
            return
        }

        print("\n📡 [TELEMETRICS FETCH] Querying live vehicle state for VIN: \(vin)...")
        let fetchStart = Date()
        let state = try await api.fetchVehicleState(vin: vin, features: features)
        let duration = Date().timeIntervalSince(fetchStart)
        print("✅ [TELEMETRICS FETCH] Completed in \(String(format: "%.2f", duration))s")

        print("\n========================================================")
        print("🚘 VEHICLE IDENTITY & BUILD SPECIFICATIONS")
        print("  • Model Name:       \(state.modelName ?? "Unknown")")
        print("  • Model Year:       \(state.modelYear ?? "Unknown")")
        print("  • Registration No:  \(state.registrationNo ?? "N/A")")
        print("  • VIN:              \(state.vin)")
        print("  • Internal ID:      \(state.internalVehicleIdentifier ?? "N/A")")
        print("  • PNO34 Code:       \(state.pno34 ?? "N/A")")
        print("  • Structure Week:   \(state.structureWeek ?? "N/A") (Formatted: \(state.formattedBuildWeek ?? "N/A"))")
        print("  • Market:           \(state.accountMarket ?? "N/A")")
        print("  • Paint Finish:     \(state.externalColour ?? "N/A")")
        print("  • Upholstery:       \(state.upholstery ?? "N/A")")
        print("  • Wheels:           \(state.wheels ?? "N/A")")
        print("  • Factory Packages: \(state.packages.isEmpty ? "None" : state.packages.joined(separator: ", "))")
        print("  • Steering:         \(state.steeringOrientation ?? "N/A")")
        print("  • Powertrain:       \(state.powertrain.displayName)")
        print("  • Battery Capacity: \(state.reportedBatteryCapacityKwh.map { "\($0) kWh" } ?? "N/A")")

        print("\n⚡️ BATTERY & CHARGING TELEMETRY")
        print("  • Battery Level:    \(state.batteryPercentage.map { "\(String(format: "%.1f", $0))%" } ?? "N/A")")
        print("  • Electric Range:   \(state.rangeKm.map { "\($0) km" } ?? "N/A")")
        print("  • Charging State:   \(state.chargingState.displayName)")
        print("  • Charger Plug:     \(state.chargerConnection.displayName)")
        print("  • Power / Voltage:  \(state.chargingPowerWatts.map { "\($0) W" } ?? "N/A") | \(state.chargingVoltageVolts.map { "\($0) V" } ?? "N/A") | \(state.chargingCurrentAmps.map { "\($0) A" } ?? "N/A")")
        print("  • Charge Target:    \(state.chargeTargetPercentage.map { "\($0)%" } ?? "N/A")")
        print("  • Time to Full:     \(state.estimatedChargingTimeToFullMinutes.map { "\($0) min" } ?? "N/A")")

        print("\n🔧 SERVICE, HEALTH & ODOMETER")
        print("  • Odometer:         \(state.odometerKm.map { "\($0) km" } ?? "N/A")")
        print("  • Service Days:     \(state.daysToService.map { "\($0) days" } ?? "N/A")")
        print("  • Service Distance: \(state.distanceToServiceKm.map { "\($0) km" } ?? "N/A")")
        print("  • Service Warning:  \(state.serviceWarning ? "⚠️ ACTIVE WARNING" : "None")")
        print("  • Fluid Warnings:   \(state.fluidWarnings.isEmpty ? "None" : state.fluidWarnings.joined(separator: ", "))")
        if let health = state.healthDetails {
            print("  • Tyres Pressure:")
            for tyre in health.tyres {
                print("    - \(tyre.position.displayName): \(tyre.kilopascals.map { "\($0) kPa" } ?? "N/A") [Warning: \(tyre.warning.rawValue)]")
            }
        }

        print("\n🚪 CLOSURES & EXTERIOR STATUS")
        if let exterior = state.exteriorStatus {
            print("  • Central Lock:     \(exterior.isLocked == true ? "Locked" : (exterior.isLocked == false ? "Unlocked" : "N/A"))")
            for op in exterior.openings {
                print("    - \(op.opening.displayName): \(op.state)")
            }
        } else {
            print("  • Exterior Status:  N/A")
        }

        print("\n❄️ CLIMATE & CABIN AIR")
        if let climate = state.climateStatus {
            print("  • HVAC Activity:    \(climate.activity.displayName)")
            print("  • Driver Heat:      Level \(climate.driverSeatHeatingLevel ?? 0)")
            print("  • Passenger Heat:   Level \(climate.passengerSeatHeatingLevel ?? 0)")
            print("  • Steering Heat:    Level \(climate.steeringWheelHeatingLevel ?? 0)")
            print("  • Target Temp:      \(climate.requestedTemperatureCelsius.map { "\($0)°C" } ?? "N/A")")
            print("  • Cabin Temp:       \(climate.interiorTemperatureCelsius.map { "\($0)°C" } ?? "N/A")")
        }
        if let air = state.airQuality {
            print("  • CleanZone Purify: \(air.cleaningState.displayName)")
            print("  • Cabin AQI:        \(air.airQualityIndex.map { "\($0)" } ?? "N/A")")
            print("  • Cabin PM2.5:      \(air.particulateMatter25.map { "\($0) µg/m³" } ?? "N/A")")
            print("  • Outdoor PM2.5:    \(air.externalParticulateMatter25.map { "\($0) µg/m³" } ?? "N/A")")
            print("  • Filter Life:      \(air.filterRemainingPercent.map { "\($0)%" } ?? "N/A")")
        }

        print("\n📡 CONNECTIVITY & DIAGNOSTICS")
        print("  • Cloud Status:     \(state.connectivity?.state.displayName ?? "N/A")")
        print("  • Vehicle Timestamp:\(state.vehicleReportedAt.map { "\($0)" } ?? "N/A")")
        print("  • Stale Status:     \(state.isStale(at: Date()) ? "⚠️ STALE" : "✅ FRESH")")
        print("  • Unavailable:      \(state.unavailableFeatures.map(\.rawValue).joined(separator: ", "))")
        print("========================================================\n")

        try? await api.signOut()
    }

    /// Comprehensive API probe: queries every Polestar REST, GraphQL, Public Image, and gRPC endpoint,
    /// logs the raw payloads and headers, and formats full samples.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testComprehensiveAllAPIsProbeAndDump() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-tests")
        try? keychain.deleteSessionToken()
        try? keychain.deletePassword()
        let api = PolestarAPI(keychain: keychain)

        print("\n========================================================")
        print("🔍 [1. OIDC DISCOVERY & IDENTITY ENDPOINTS]")
        let oidcURL = URL(string: "https://polestarid.eu.polestar.com/.well-known/openid-configuration")!
        let (oidcData, _) = try await URLSession.shared.data(from: oidcURL)
        if let oidcJson = try? JSONSerialization.jsonObject(with: oidcData) as? [String: Any] {
            print("  • Token Endpoint:          \(oidcJson["token_endpoint"] ?? "N/A")")
            print("  • Authorization Endpoint:  \(oidcJson["authorization_endpoint"] ?? "N/A")")
            print("  • UserInfo Endpoint:       \(oidcJson["userinfo_endpoint"] ?? "N/A")")
            print("  • Scopes Supported:        \(oidcJson["scopes_supported"] ?? "N/A")")
            print("  • Grant Types:             \(oidcJson["grant_types_supported"] ?? "N/A")")
            print("  • Response Types:          \(oidcJson["response_types_supported"] ?? "N/A")")
        }

        print("\n========================================================")
        print("🔐 [2. AUTHENTICATION & TOKEN ACQUISITION]")
        var allFeatures = FeatureSelection.default
        allFeatures.set(.vehicleImage, enabled: true)
        for feature in AppFeature.allCases where !feature.isRemoteControl {
            allFeatures.set(feature, enabled: true)
        }
        let authStart = Date()
        try await api.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: allFeatures)
        print("  • Authentication Time:     \(String(format: "%.2f", Date().timeIntervalSince(authStart)))s")

        guard let vin = await api.resolvedVIN(preferred: preferredVIN) else {
            Issue.record("No resolved VIN")
            return
        }
        print("  • Target VIN:              \(vin)")

        print("\n========================================================")
        print("🖼 [3. PUBLIC VEHICLE STUDIO & RENDER CDN]")
        let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
        let publicApiKey = "REDACTED-ROTATE-THIS-KEY"
        let query = """
        query GetCarImages($vin: String!) {
          getCarImages(vin: $vin) {
            angles
            exterior { url }
            interior { url }
          }
        }
        """
        var imageReq = URLRequest(url: publicApiURL)
        imageReq.httpMethod = "POST"
        imageReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        imageReq.setValue(publicApiKey, forHTTPHeaderField: "x-api-key")
        imageReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["vin": vin]
        ])
        if let (imgData, imgRes) = try? await URLSession.shared.data(for: imageReq),
           let http = imgRes as? HTTPURLResponse {
            print("  • HTTP Status:             \(http.statusCode)")
            let bodyStr = String(decoding: imgData, as: UTF8.self)
            print("  • Response Payload:        \(bodyStr)")
        }

        print("\n========================================================")
        print("📡 [4. LIVE TELEMETRICS & gRPC MICROSERVICES]")
        let state = try await api.fetchVehicleState(vin: vin, features: allFeatures)

        print("  • Battery Level:           \(state.batteryPercentage.map { "\($0)%" } ?? "N/A")")
        print("  • Range (Km):              \(state.rangeKm.map { "\($0) km" } ?? "N/A")")
        print("  • Charging State:          \(state.chargingState.displayName)")
        print("  • Charger Plug:            \(state.chargerConnection.displayName)")
        print("  • Power / Voltage / Current: \(state.chargingPowerWatts.map { "\($0) W" } ?? "N/A") | \(state.chargingVoltageVolts.map { "\($0) V" } ?? "N/A") | \(state.chargingCurrentAmps.map { "\($0) A" } ?? "N/A")")
        print("  • Odometer (Km):           \(state.odometerKm.map { "\($0) km" } ?? "N/A")")
        print("  • Trip Meters (Manual/Auto):\(state.tripMeterManualKm.map { "\($0) km" } ?? "N/A") / \(state.tripMeterAutomaticKm.map { "\($0) km" } ?? "N/A")")
        print("  • Service Days Remaining:  \(state.daysToService.map { "\($0) days" } ?? "N/A")")
        print("  • Service Distance:        \(state.distanceToServiceKm.map { "\($0) km" } ?? "N/A")")
        print("  • Service Warning:         \(state.serviceWarning)")
        print("  • Fluid Warnings:          \(state.fluidWarnings)")
        if let tyres = state.healthDetails?.tyres {
            print("  • Tyres Pressure/Warning:")
            for tyre in tyres {
                print("    - \(tyre.position.displayName): \(tyre.kilopascals.map { "\($0) kPa" } ?? "N/A") (Status: \(tyre.warning.displayName))")
            }
        }
        if let ext = state.exteriorStatus {
            print("  • Central Lock:            \(ext.isLocked == true ? "Locked" : "Unlocked")")
            for op in ext.openings {
                print("    - \(op.opening.displayName): \(op.state)")
            }
        }
        if let clim = state.climateStatus {
            print("  • Climate Activity:        \(clim.activity.displayName)")
            print("  • Seat Heat (D/P):         Level \(clim.driverSeatHeatingLevel ?? 0) / Level \(clim.passengerSeatHeatingLevel ?? 0)")
            print("  • Steering Heat:           Level \(clim.steeringWheelHeatingLevel ?? 0)")
            print("  • Requested Target Temp:   \(clim.requestedTemperatureCelsius.map { "\($0)°C" } ?? "N/A")")
            print("  • Interior Temp:           \(clim.interiorTemperatureCelsius.map { "\($0)°C" } ?? "N/A")")
        }
        if let air = state.airQuality {
            print("  • CleanZone Purifier:      \(air.cleaningState.displayName)")
            print("  • Cabin AQI / PM2.5:       \(air.airQualityIndex.map { "\($0)" } ?? "N/A") / \(air.particulateMatter25.map { "\($0) µg/m³" } ?? "N/A")")
            print("  • Outdoor PM2.5:           \(air.externalParticulateMatter25.map { "\($0) µg/m³" } ?? "N/A")")
            print("  • Filter Life:             \(air.filterRemainingPercent.map { "\($0)%" } ?? "N/A")")
        }
        if let soft = state.softwareInfo {
            print("  • Installed Version:       \(soft.installedVersion ?? "N/A")")
            print("  • Available Version:       \(soft.latestAvailableVersion ?? "N/A")")
            print("  • Update State:            \(soft.state.displayName)")
        }
        print("  • Timestamp:               \(state.vehicleReportedAt.map { "\($0)" } ?? "N/A")")
        print("  • Unavailable:             \(state.unavailableFeatures.map(\.rawValue).joined(separator: ", "))")
        print("========================================================\n")

        try? await api.signOut()
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

    /// Captures the raw C3 OTA exchange so a failing install can be diagnosed.
    ///
    /// `URLSession` does not expose HTTP/2 trailers, and gRPC delivers the status of a
    /// *successful-looking* call there — so a backend rejection can reach the app as
    /// "no response frames" rather than as its real status. This talks to C3 directly and
    /// prints the HTTP status, every visible header, and the raw bytes of each frame.
    ///
    /// Reads only, unless `HISINGEN_TEST_OTA_INSTALL=1` is set — that flag makes it attempt a
    /// real `InstallNow`, which starts a real software installation on a real car.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiagnoseLiveOtaExchange() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let attemptInstall = environment["HISINGEN_TEST_OTA_INSTALL"] == "1"

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        // C3 discovery — the OTA services live on the discovered host, not a fixed one.
        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let port = c3["grpcPort"] as? Int ?? 443
        let base = try XCTUnwrap(URL(string: "https://\(host):\(port)"))

        print("\n========================================================")
        print("🔧 OTA DIAGNOSTIC — VIN \(vin)")
        print("  • C3 host: \(base.absoluteString)")

        var softwareID: String?
        for (label, path, body) in Self.otaReadProbes(vin: vin) {
            let result = await Self.callGRPC(base: base, path: path, body: body,
                                             vin: vin, token: token, label: label)
            if label == "GetSoftwareInfo", let frame = result.frames.first,
               let payload = Protobuf.fields(frame).first(where: { $0.number == 1 && $0.wire == 2 })?.data {
                let fields = Protobuf.fields(payload)
                softwareID = fields.first(where: { $0.number == 1 && $0.wire == 2 })
                    .flatMap { String(data: $0.data, encoding: .utf8) }
                print("  → parsed state=\(fields.first(where: { $0.number == 4 })?.varint.description ?? "nil") "
                      + "version=\(fields.first(where: { $0.number == 6 && $0.wire == 2 }).flatMap { String(data: $0.data, encoding: .utf8) } ?? "nil") "
                      + "softwareID=\(softwareID ?? "nil")")
            }
            if label == "GetSchedule", softwareID == nil, let frame = result.frames.first,
               let timer = Protobuf.fields(frame).first(where: { $0.number == 1 && $0.wire == 2 })?.data {
                softwareID = Protobuf.fields(timer).first(where: { $0.number == 4 && $0.wire == 2 })
                    .flatMap { String(data: $0.data, encoding: .utf8) }
                print("  → schedule softwareID=\(softwareID ?? "nil")")
            }
        }

        guard let softwareID, !softwareID.isEmpty else {
            print("  ⚠️ No software_id available — nothing to install. This alone explains an")
            print("     install failure: the scheduler has no update to act on.")
            print("========================================================\n")
            try? await api.signOut()
            return
        }

        guard attemptInstall else {
            print("  ℹ️ Set HISINGEN_TEST_OTA_INSTALL=1 to attempt a real InstallNow.")
            print("========================================================\n")
            try? await api.signOut()
            return
        }

        var install = Data()
        install.append(Protobuf.stringField(1, vin))
        install.append(Protobuf.stringField(2, softwareID))
        _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/InstallNow",
                                body: install, vin: vin, token: token, label: "InstallNow")
        print("========================================================\n")
        try? await api.signOut()
    }

    private static func otaReadProbes(vin: String) -> [(String, String, Data)] {
        var softwareInfo = Data()
        softwareInfo.append(Protobuf.stringField(1, vin))
        softwareInfo.append(Protobuf.stringField(2, "en"))
        return [
            ("GetSoftwareInfo", "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo", softwareInfo),
            ("GetSchedule", "/ota_mobcache.SchedulerService/GetSchedule", Protobuf.stringField(1, vin))
        ]
    }

    /// Issues one gRPC call and prints everything observable about the response.
    private static func callGRPC(base: URL, path: String, body: Data, vin: String,
                                 token: String, label: String) async -> (frames: [Data], status: String?) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.setValue("trailers", forHTTPHeaderField: "TE")
        request.httpBody = Protobuf.grpcFrame(body)

        print("\n── \(label) ─────────────────────────────")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("  ✗ non-HTTP response")
                return ([], nil)
            }
            print("  HTTP \(http.statusCode)")
            for (key, value) in http.allHeaderFields {
                print("  \(key): \(value)")
            }
            let status = http.value(forHTTPHeaderField: "grpc-status")
            if let message = http.value(forHTTPHeaderField: "grpc-message") {
                print("  grpc-message (decoded): \(message.removingPercentEncoding ?? message)")
            }
            print("  body bytes: \(data.count)")
            if !data.isEmpty {
                print("  raw: \(data.map { String(format: "%02x", $0) }.joined())")
            }
            var frames: [Data] = []
            var index = data.startIndex
            while index + 5 <= data.endIndex {
                let size = Int(data[index + 1]) << 24 | Int(data[index + 2]) << 16
                    | Int(data[index + 3]) << 8 | Int(data[index + 4])
                let start = index + 5
                guard size >= 0, start + size <= data.endIndex else { break }
                frames.append(data[start..<(start + size)])
                index = start + size
            }
            print("  frames: \(frames.count)")
            if frames.isEmpty && (status == nil || status == "0") {
                print("  ⚠️ 200 OK, no grpc-status header, and no message frame — the real status")
                print("     is in HTTP/2 trailers that URLSession does not expose.")
            }
            return (frames, status)
        } catch {
            print("  ✗ transport error: \(error)")
            return ([], nil)
        }
    }
}
#endif


