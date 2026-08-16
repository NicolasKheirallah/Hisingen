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

        // Reversible proof that the write path works: schedule an install far enough out that
        // it cannot fire, confirm the scheduler picked it up, then cancel it. Exercises the
        // same service, auth, request shape, and response parsing as InstallNow without
        // committing the car to an installation.
        if environment["HISINGEN_TEST_OTA_SCHEDULE"] == "1" {
            var schedule = Data()
            schedule.append(Protobuf.stringField(1, vin))
            schedule.append(Protobuf.intField(2, 720))  // 720 MINUTES = 12 hours out
            schedule.append(Protobuf.stringField(3, softwareID))
            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/Schedule",
                                    body: schedule, vin: vin, token: token, label: "Schedule (+720 min)")

            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/GetSchedule",
                                    body: Protobuf.stringField(1, vin), vin: vin, token: token,
                                    label: "GetSchedule (after scheduling)")

            var cancel = Data()
            cancel.append(Protobuf.stringField(1, vin))
            cancel.append(Protobuf.stringField(2, softwareID))
            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/CancelSchedule",
                                    body: cancel, vin: vin, token: token, label: "CancelSchedule")

            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/GetSchedule",
                                    body: Protobuf.stringField(1, vin), vin: vin, token: token,
                                    label: "GetSchedule (after cancelling)")
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

    /// Drives the real `PolestarAPI` OTA path end to end and asserts the failure it produces is
    /// specific and actionable rather than the old catch-all
    /// "Polestar's vehicle service returned an unexpected response."
    ///
    /// Safe to run: with the update in `available` (not yet downloaded) the client refuses
    /// before dispatching, and the backend refuses if it ever got that far.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testLiveOtaInstallReportsActionableFailure() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        features.set(.remoteOTA, enabled: true)
        features.set(.softwareUpdates, enabled: true)
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        let state = try await api.fetchVehicleState(vin: vin, features: features)
        print("\n🔧 OTA via PolestarAPI — state=\(state.softwareInfo?.state.displayName ?? "nil") "
              + "installed=\(state.softwareInfo?.installedVersion ?? "nil") "
              + "available=\(state.softwareInfo?.latestAvailableVersion ?? "nil")")

        do {
            let result = try await api.executeRemoteCommand(.installOTANow, vin: vin)
            print("  ⚠️ InstallNow was ACCEPTED: \(result.outcome) \(result.message ?? "")")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("  ✅ InstallNow refused with: \(description)")
            XCTAssertFalse(
                description.contains("unexpected response"),
                "OTA failures must name a cause, not fall back to the generic message"
            )
            XCTAssertFalse(description.isEmpty)
        }
        try? await api.signOut()
    }

    /// Isolates whether vehicle discovery fails because of the OIDC client Hisingen signs in
    /// with. Runs the full authorize + token exchange against each candidate client and prints
    /// the raw response of both discovery queries.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiagnoseOidcClientAndVehicleDiscovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])

        let candidates = [
            ("web + write scope", "l3oopkc_10", "https://www.polestar.com/sign-in-callback",
             "openid profile email customer:attributes customer:attributes:write"),
            ("web baseline", "l3oopkc_10", "https://www.polestar.com/sign-in-callback",
             "openid profile email customer:attributes")
        ]

        for (label, clientID, redirect, scope) in candidates {
            print("\n════════ OIDC CLIENT: \(label) (\(clientID)) ════════")
            do {
                let token = try await Self.authorize(email: email, password: password,
                                                     clientID: clientID, redirect: redirect, scope: scope)
                print("  ✅ token acquired (\(token.count) chars)")
                await Self.probeDiscovery(token: token)
            } catch {
                print("  ✗ auth failed: \(error)")
            }
        }
    }

    /// Minimal standalone OIDC/PKCE flow so each client can be tested independently of
    /// `PolestarAPI`'s configured constants.
    private static func authorize(email: String, password: String, clientID: String,
                                  redirect: String, scope: String) async throws -> String {
        final class Catcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var callback: URL?
            let scheme: String
            init(scheme: String) { self.scheme = scheme }
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping (URLRequest?) -> Void) {
                if request.url?.scheme == scheme, request.url?.query?.contains("code=") == true {
                    callback = request.url
                    completionHandler(nil)
                    return
                }
                completionHandler(request)
            }
        }
        let redirectURL = try XCTUnwrap(URL(string: redirect))
        let catcher = Catcher(scheme: redirectURL.scheme ?? "https")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)

        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        let items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
        var authComponents = URLComponents(string: "https://polestarid.eu.polestar.com/as/authorization.oauth2")!
        authComponents.queryItems = items
        let (pageData, pageResponse) = try await session.data(from: authComponents.url!)
        print("  authorize page: HTTP \((pageResponse as? HTTPURLResponse)?.statusCode ?? -1)")
        let html = String(decoding: pageData, as: UTF8.self)
        guard let resumePath = PolestarAPI.extractResumePath(from: html) else {
            print("  ✗ no resume path; first 300 chars: \(html.prefix(300))")
            throw VolvoError.appNotConfigured
        }
        var loginComponents = URLComponents(string: "https://polestarid.eu.polestar.com" + resumePath)!
        loginComponents.queryItems = (loginComponents.queryItems ?? []) + items
        var login = URLRequest(url: loginComponents.url!)
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = "pf.username=\(email.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&pf.pass=\(password.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)".data(using: .utf8)
        let (_, loginResponse) = try await session.data(for: login)
        print("  login POST: HTTP \((loginResponse as? HTTPURLResponse)?.statusCode ?? -1)")

        let callback = catcher.callback ?? (loginResponse as? HTTPURLResponse)?.url
        guard let code = callback.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            print("  ✗ no code in callback: \(callback?.absoluteString ?? "nil")")
            throw VolvoError.appNotConfigured
        }
        var tokenRequest = URLRequest(url: URL(string: "https://polestarid.eu.polestar.com/as/token.oauth2")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=authorization_code&client_id=\(clientID)&code=\(code)"
            + "&redirect_uri=\(redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
            + "&code_verifier=\(verifier)"
        tokenRequest.httpBody = form.data(using: .utf8)
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        let code2 = (tokenResponse as? HTTPURLResponse)?.statusCode ?? -1
        print("  token exchange: HTTP \(code2)")
        guard let json = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any] else {
            print("  ✗ token body: \(String(decoding: tokenData, as: UTF8.self).prefix(300))")
            throw VolvoError.appNotConfigured
        }
        if let scopeGranted = json["scope"] as? String { print("  granted scope: \(scopeGranted)") }
        guard let accessToken = json["access_token"] as? String else {
            print("  ✗ token body: \(json)")
            throw VolvoError.appNotConfigured
        }
        return accessToken
    }

    private static func probeDiscovery(token: String) async {
        let queries: [(String, URL, String, [String: String])] = [
            ("getConsumerCarsV2",
             URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!,
             "query GetConsumerCarsV2 { getConsumerCarsV2 { vin modelName modelYear } }",
             ["Authorization": "Bearer \(token)"]),
            ("GetVDMSCars (app-backend)",
             URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!,
             "query GetVDMSCars { vdms { getVehiclesInformation { vin registrationNo modelYear content { model { name } } } } }",
             ["X-PolestarId-Authorization": "Bearer \(token)"])
        ]
        for (label, url, query, headers) in queries {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(decoding: data, as: UTF8.self)
                print("  • \(label): HTTP \(status) → \(body.prefix(400))")
            } catch {
                print("  • \(label): transport error \(error)")
            }
        }
    }

    /// Answers "can the app make the car download a pending update?" by asking the server
    /// which OTA methods exist. gRPC answers an unknown method with status 12 (UNIMPLEMENTED)
    /// without running anything, so absence is provable without side effects.
    ///
    /// Tries server reflection first; falls back to probing candidate method names.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiscoverAvailableOtaMethods() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let base = try XCTUnwrap(URL(string: "https://\(host):\(c3["grpcPort"] as? Int ?? 443)"))

        print("\n========================================================")
        print("🔎 OTA METHOD DISCOVERY")

        // Only names that would *start a download* or report state — deliberately not probing
        // anything that could begin an installation beyond the two we already know about.
        let candidates = [
            ("/ota_mobcache.OtaDiscoveryService", ["GetSoftwareInfo", "Download", "StartDownload",
                                                   "RequestDownload", "DownloadNow", "AcceptSoftware",
                                                   "Accept", "Approve", "SetDownloadConsent"]),
            ("/ota_mobcache.SchedulerService", ["GetSchedule", "ScheduleDownload", "DownloadNow"])
        ]
        for (service, methods) in candidates {
            print("\n── \(service)")
            for method in methods {
                let status = await Self.methodStatus(base: base, path: "\(service)/\(method)",
                                                     vin: vin, token: token)
                let verdict: String
                switch status {
                case "12": verdict = "does not exist (UNIMPLEMENTED)"
                case nil: verdict = "EXISTS — returned a message body"
                case "3": verdict = "EXISTS — rejected our request shape (INVALID_ARGUMENT)"
                default: verdict = "EXISTS — grpc-status \(status ?? "?")"
                }
                print("  \(method.padding(toLength: 20, withPad: " ", startingAt: 0)) \(verdict)")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Sends a minimal `{1: vin}` request and reports only the gRPC status.
    private static func methodStatus(base: URL, path: String, vin: String, token: String) async -> String? {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.httpBody = Protobuf.grpcFrame(Protobuf.stringField(1, vin))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return "?" }
            let status = http.value(forHTTPHeaderField: "grpc-status")
            if let message = http.value(forHTTPHeaderField: "grpc-message"),
               let decoded = message.removingPercentEncoding, !decoded.isEmpty {
                print("      ↳ \(decoded)")
            }
            for try await _ in stream { break }  // release the connection
            return status
        } catch {
            return "?"
        }
    }

    /// Hunts for any interface that can make the car download a pending update, since the
    /// five known `ota_mobcache` methods cannot. Four avenues, none of them mutating:
    /// the raw C3 discovery document, gRPC server reflection, GraphQL introspection on
    /// `mystar-v2`, and the app-backend's HTTP 428 precondition.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testHuntForSoftwareDownloadInterface() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        print("\n========================================================")
        print("🕵️  DOWNLOAD-INTERFACE HUNT")

        // (1) The full C3 discovery document — what other environments/hosts exist?
        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        print("\n── [1] C3 discovery document")
        print(String(decoding: discoveryData, as: UTF8.self))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))

        // (2) gRPC server reflection — if enabled, it lists every service the host exposes.
        print("\n── [2] gRPC server reflection")
        for service in ["/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
                        "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo"] {
            let status = await Self.methodStatus(base: base, path: service, vin: vin, token: token)
            print("  \(service) → grpc-status \(status ?? "none (responded)")")
        }

        // (3) GraphQL introspection on mystar-v2 — looking for any software/OTA mutation.
        print("\n── [3] mystar-v2 GraphQL introspection")
        await Self.introspect(
            url: URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!,
            headers: ["Authorization": "Bearer \(token)"]
        )

        // (4) The app-backend answered 428 with force-update-version 5.5.0. Try newer values —
        // if the precondition clears, that host's schema becomes reachable too.
        print("\n── [4] app-backend force-update-version precondition")
        for version in ["5.5.0", "6.0.0", "7.0.0", "99.0.0"] {
            var request = URLRequest(url: URL(string:
                "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "X-PolestarId-Authorization")
            request.setValue(version, forHTTPHeaderField: "X-Polestar-Force-Update-Version")
            request.setValue("PolestarApp/\(version)b1102 Android/14", forHTTPHeaderField: "User-Agent")
            request.setValue("SE", forHTTPHeaderField: "X-Polestar-Locale")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "operationName": "GetVDMSCars", "variables": [:],
                "query": "query GetVDMSCars { vdms { getVehiclesInformation { vin } } }"
            ])
            if let (data, response) = try? await URLSession.shared.data(for: request) {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("  version \(version) → HTTP \(code) \(String(decoding: data, as: UTF8.self).prefix(160))")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Follow-up to the hunt: the app-backend rejects the token's *format*, not the token,
    /// and mystar-v2 blocks only part of introspection. Both are worth pushing on.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeAppBackendAuthAndSchemaShape() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        print("\n========================================================")
        print("🔬 APP-BACKEND AUTH + SCHEMA SHAPE")

        let appBackend = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!
        let carsQuery = "query GetVDMSCars { vdms { getVehiclesInformation { vin } } }"

        print("\n── app-backend token formats")
        let formats: [(String, [String: String])] = [
            ("X-PolestarId-Authorization: Bearer …", ["X-PolestarId-Authorization": "Bearer \(token)"]),
            ("X-PolestarId-Authorization: <raw>",    ["X-PolestarId-Authorization": token]),
            ("Authorization: Bearer …",              ["Authorization": "Bearer \(token)"]),
            ("both headers",                          ["Authorization": "Bearer \(token)",
                                                       "X-PolestarId-Authorization": token])
        ]
        for (label, headers) in formats {
            var request = URLRequest(url: appBackend)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("PolestarApp/5.5.0b1102 Android/14", forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "operationName": "GetVDMSCars", "variables": [:], "query": carsQuery
            ])
            if let (data, response) = try? await URLSession.shared.data(for: request) {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("  \(label) → HTTP \(code) \(String(decoding: data, as: UTF8.self).prefix(150))")
            }
        }

        print("\n── mystar-v2 schema shape")
        let shapes = [
            ("__schema.types", "{ __schema { types { name } } }"),
            ("__type(Mutation)", "{ __type(name: \"Mutation\") { fields { name } } }"),
            ("__type(Query)", "{ __type(name: \"Query\") { fields { name } } }"),
            ("__typename", "{ __typename }")
        ]
        for (label, query) in shapes {
            var request = URLRequest(url: URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { continue }
            let body = String(decoding: data, as: UTF8.self)
            let interesting = ["software", "ota", "update", "download", "firmware", "install"]
            var hits: Set<String> = []
            for match in body.components(separatedBy: "\"name\":\"").dropFirst() {
                let name = String(match.prefix(while: { $0 != "\"" }))
                if interesting.contains(where: { name.lowercased().contains($0) }) { hits.insert(name) }
            }
            if hits.isEmpty {
                print("  \(label) → \(body.prefix(220))")
            } else {
                print("  \(label) → ⭐️ \(hits.sorted().joined(separator: ", "))")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// mystar-v2 strips `__Schema.types`/`__Type.fields`, so the schema cannot be enumerated.
    /// But its validator distinguishes "no such field" (`FieldUndefined`) from every other
    /// failure, which makes it an oracle: a name that exists fails differently from one that
    /// does not. Probes for any software/OTA operation, without invoking one successfully.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeMystarSchemaForSoftwareOperations() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        print("\n========================================================")
        print("🧬 mystar-v2 SCHEMA NAME ORACLE")

        print("\n── does a mutation root exist?")
        print("  " + (await Self.oracle(query: "mutation { __typename }", token: token)))

        let queryNames = [
            "getConsumerCarsV2", "getCarImages",
            "getSoftwareInfo", "getSoftwareStatus", "getSoftwareUpdate", "getOtaStatus",
            "getVehicleSoftware", "softwareUpdate", "otaStatus"
        ]
        print("\n── query fields (getConsumerCarsV2 is the known-good control)")
        for name in queryNames {
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                  + (await Self.oracle(query: "{ \(name) { __typename } }", token: token)))
        }

        let mutationNames = [
            "startSoftwareDownload", "downloadSoftware", "startOtaDownload",
            "installSoftware", "installSoftwareUpdate", "scheduleSoftwareInstallation",
            "acceptSoftwareUpdate", "updateSoftware", "requestSoftwareDownload"
        ]
        print("\n── mutation fields")
        for name in mutationNames {
            print("  \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) "
                  + (await Self.oracle(query: "mutation { \(name)(vin: \"\(vin)\") { __typename } }",
                                       token: token)))
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Last avenue: `invocation.InvocationService` is the generic write RPC behind Lock,
    /// Unlock, ClimatizationStart, WindowControl and HonkFlash. If a software/download action
    /// exists anywhere outside `ota_mobcache`, this is where it would live. Probes names on
    /// both hosts; UNIMPLEMENTED proves absence without invoking anything.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeInvocationServiceForSoftwareActions() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let c3Base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))
        let pccsBase = URL(string: "https://api.pccs-prod.plstr.io:443")!

        print("\n========================================================")
        print("🧰 InvocationService PROBE")

        let methods = ["Lock", "SoftwareUpdate", "SoftwareDownload", "OtaDownload",
                       "DownloadSoftware", "StartSoftwareDownload", "UpdateSoftware",
                       "InstallSoftware", "AcceptSoftwareUpdate"]
        for (label, base, service) in [
            ("C3   invocation.InvocationService", c3Base, "/invocation.InvocationService"),
            ("PCCS invocation.InvocationService", pccsBase, "/invocation.InvocationService"),
            ("PCCS pccs.invocation.v1.InvocationService", pccsBase, "/pccs.invocation.v1.InvocationService")
        ] {
            print("\n── \(label)")
            for method in methods {
                let status = await Self.methodStatus(base: base, path: "\(service)/\(method)",
                                                     vin: vin, token: token)
                let verdict = status == "12" ? "absent" : "PRESENT (grpc-status \(status ?? "none"))"
                print("  \(method.padding(toLength: 24, withPad: " ", startingAt: 0)) \(verdict)")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Verifies the corrected PCCS invocation path end to end, through the real `PolestarAPI`
    /// request builders rather than a hand-made probe — and re-checks whether the pending
    /// update has finished downloading, which is the only thing gating installation.
    ///
    /// Dispatches `.lock`: the safe direction (a car that ends up locked is not a worse
    /// outcome than one that was already locked) and trivially reversible.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testLiveInvocationWritePathAndOtaReadiness() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        for feature in [AppFeature.remoteLocks, .remoteOTA, .softwareUpdates,
                        .chargingDetails, .exteriorStatus] {
            features.set(feature, enabled: true)
        }
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let state = try await api.fetchVehicleState(vin: vin, features: features)

        print("\n========================================================")
        print("🚗 OTA READINESS")
        if let software = state.softwareInfo {
            print("  state:     \(software.state.displayName)")
            print("  available: \(software.latestAvailableVersion ?? "—")")
            print("  installed: \(software.installedVersion ?? "—")")
            let ready = software.state == .downloaded || software.state == .deferred
            print("  → \(ready ? "READY TO INSTALL" : "not installable yet (car has not downloaded it)")")
        } else {
            print("  no software payload")
        }

        print("\n🔐 INVOCATION WRITE PATH (pccs.invocation.v1.InvocationService)")
        print("  charge target read back: \(state.chargeTargetPercentage.map(String.init) ?? "—")")
        print("  lock state before:       \(state.exteriorStatus?.isLocked.map(String.init) ?? "unknown")")
        do {
            let result = try await api.executeRemoteCommand(.lock, vin: vin)
            print("  ✅ Lock ACCEPTED → outcome=\(result.outcome) message=\(result.message ?? "—")")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("  ✗ Lock refused → \(text)")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// PCCS denies invocation writes at auth ("Access denied"), but C3's `invocation.
    /// InvocationService` answered an earlier malformed probe with `Application error
    /// processing RPC` — it reached the handler. Sends the *real* request envelope to C3 to
    /// find out whether remote commands work there.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testInvocationOnC3WithRealEnvelope() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let c3Base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))
        let pccs = URL(string: "https://api.pccs-prod.plstr.io:443")!

        print("\n========================================================")
        print("🔁 INVOCATION: C3 vs PCCS, real envelope")
        // The exact bytes the app would send for a lock command.
        let envelope = PolestarGRPC.lockRequest(vin)
        for (label, base, path) in [
            ("C3   invocation.InvocationService/Lock", c3Base, "/invocation.InvocationService/Lock"),
            ("PCCS pccs.invocation.v1.InvocationService/Lock", pccs, "/pccs.invocation.v1.InvocationService/Lock")
        ] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(vin, forHTTPHeaderField: "vin")
            request.httpBody = Protobuf.grpcFrame(envelope)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: config)
            print("\n── \(label)")
            guard let (stream, response) = try? await session.bytes(for: request),
                  let http = response as? HTTPURLResponse else {
                print("  transport error"); continue
            }
            print("  HTTP \(http.statusCode)  grpc-status=\(http.value(forHTTPHeaderField: "grpc-status") ?? "none")")
            if let message = http.value(forHTTPHeaderField: "grpc-message") {
                print("  grpc-message: \(message.removingPercentEncoding ?? message)")
            }
            var header: [UInt8] = []; var body = Data(); var expected: Int?
            do {
                for try await byte in stream {
                    if expected == nil {
                        header.append(byte)
                        guard header.count == 5 else { continue }
                        expected = Int(header[1]) << 24 | Int(header[2]) << 16
                            | Int(header[3]) << 8 | Int(header[4])
                        if expected == 0 { break }
                        continue
                    }
                    body.append(byte)
                    if body.count == expected { break }
                }
            } catch { print("  (stream: \(error.localizedDescription))") }
            if body.isEmpty {
                print("  no message frame")
            } else {
                print("  frame: \(body.map { String(format: "%02x", $0) }.joined())")
                print("  parsed: \((try? PolestarGRPC.parseInvocationResult(body)).map { "\($0.outcome) \($0.message ?? "")" } ?? "rejected")")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// C3 rejects `l3oopkc_10` for invocation with a message that names the allowed client ids,
    /// and `lp8dyrd_10` is among them. That client cannot read vehicles, but it may be able to
    /// issue commands — which would mean the app needs a token from each.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testCommandClientTokenCanInvoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        // VIN + C3 host come from the web client, which is the one that can list vehicles.
        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedWebToken = try await api.validAccessToken()
        let webToken = try XCTUnwrap(resolvedWebToken)
        let vin = try XCTUnwrap(resolvedVIN)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let c3Base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))

        // A second sign-in, as the command-capable client.
        let commandToken = try await Self.authorize(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write"
        )
        print("\n========================================================")
        print("🔑 COMMAND-CLIENT TOKEN (lp8dyrd_10) — Lock")

        for (label, base, path) in [
            ("C3   invocation.InvocationService/Lock", c3Base, "/invocation.InvocationService/Lock"),
            ("PCCS pccs.invocation.v1.InvocationService/Lock",
             URL(string: "https://api.pccs-prod.plstr.io:443")!,
             "/pccs.invocation.v1.InvocationService/Lock")
        ] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(commandToken)", forHTTPHeaderField: "Authorization")
            request.setValue(vin, forHTTPHeaderField: "vin")
            request.httpBody = Protobuf.grpcFrame(PolestarGRPC.lockRequest(vin))
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            let session = URLSession(configuration: config)
            print("\n── \(label)")
            guard let (stream, response) = try? await session.bytes(for: request),
                  let http = response as? HTTPURLResponse else { print("  transport error"); continue }
            print("  HTTP \(http.statusCode)  grpc-status=\(http.value(forHTTPHeaderField: "grpc-status") ?? "none")")
            if let message = http.value(forHTTPHeaderField: "grpc-message") {
                print("  grpc-message: \(message.removingPercentEncoding ?? message)")
            }
            var header: [UInt8] = []; var body = Data(); var expected: Int?
            do {
                for try await byte in stream {
                    if expected == nil {
                        header.append(byte)
                        guard header.count == 5 else { continue }
                        expected = Int(header[1]) << 24 | Int(header[2]) << 16
                            | Int(header[3]) << 8 | Int(header[4])
                        if expected == 0 { break }
                        continue
                    }
                    body.append(byte)
                    if body.count == expected { break }
                }
            } catch { print("  (stream: \(error.localizedDescription))") }
            if body.isEmpty {
                print("  no message frame")
            } else {
                print("  frame: \(body.map { String(format: "%02x", $0) }.joined())")
                if let parsed = try? PolestarGRPC.parseInvocationResult(body) {
                    print("  ⭐️ ACCEPTED → outcome=\(parsed.outcome) message=\(parsed.message ?? "—")")
                }
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Last two avenues for getting the car to download a pending update:
    /// (1) every OTA call so far used the *web* token; the allowlisted command client may be
    ///     treated differently by the scheduler.
    /// (2) C3 distinguishes "Method not found: <svc>/<m>" (service exists) from
    ///     "Service is unimplemented." — a service-name oracle that can enumerate what else
    ///     is on the host beyond the two OTA services already known.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDownloadTriggerLastResort() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedWeb = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let webToken = try XCTUnwrap(resolvedWeb)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))

        let commandToken = try await Self.authorize(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")

        // Re-read software info with the command token to get a fresh software_id.
        var infoRequest = Data()
        infoRequest.append(Protobuf.stringField(1, vin))
        infoRequest.append(Protobuf.stringField(2, "en"))
        let info = await Self.callGRPC(base: base, path: "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo",
                                       body: infoRequest, vin: vin, token: commandToken,
                                       label: "GetSoftwareInfo (command client)")
        var softwareID = ""
        if let frame = info.frames.first,
           let payload = Protobuf.fields(frame).first(where: { $0.number == 1 && $0.wire == 2 })?.data {
            softwareID = Protobuf.fields(payload)
                .first(where: { $0.number == 1 && $0.wire == 2 })
                .flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        }
        print("\n🔑 OTA WRITES WITH COMMAND-CLIENT TOKEN (software_id=\(softwareID))")
        if !softwareID.isEmpty {
            var schedule = Data()
            schedule.append(Protobuf.stringField(1, vin))
            schedule.append(Protobuf.intField(2, 60))
            schedule.append(Protobuf.stringField(3, softwareID))
            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/Schedule",
                                    body: schedule, vin: vin, token: commandToken,
                                    label: "Schedule (+60 min, command client)")
            var install = Data()
            install.append(Protobuf.stringField(1, vin))
            install.append(Protobuf.stringField(2, softwareID))
            _ = await Self.callGRPC(base: base, path: "/ota_mobcache.SchedulerService/InstallNow",
                                    body: install, vin: vin, token: commandToken,
                                    label: "InstallNow (command client)")
        }

        print("\n🗂  C3 SERVICE ENUMERATION (does the package exist at all?)")
        let services = [
            "ota_mobcache.OtaDiscoveryService", "ota_mobcache.SchedulerService",
            "ota_mobcache.ConsentService", "ota_mobcache.DownloadService",
            "ota_mobcache.OtaService", "ota_mobcache.SoftwareService",
            "ota_mobcache.NotificationService", "ota_mobcache.CampaignService",
            "ota.OtaService", "software.SoftwareService",
            "services.vehiclestates.software.SoftwareService",
            "services.vehiclestates.ota.OtaService"
        ]
        for service in services {
            let path = "/\(service)/__probe__"
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(commandToken)", forHTTPHeaderField: "Authorization")
            request.setValue(vin, forHTTPHeaderField: "vin")
            request.httpBody = Protobuf.grpcFrame(Protobuf.stringField(1, vin))
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            guard let (stream, response) = try? await URLSession(configuration: config).bytes(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            let message = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? ""
            for try await _ in stream { break }
            let verdict = message.contains("Method not found")
                ? "⭐️ SERVICE EXISTS" : (message.isEmpty ? "?" : "no such service")
            print("  \(service.padding(toLength: 46, withPad: " ", startingAt: 0)) \(verdict)")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Hunts for a `WakeUp` RPC. An independent client models `WakeUpRequest {1: reason}` with
    /// `reason = 1 (OTA_DOWNLOAD)` — precisely the "make the car fetch the update" trigger —
    /// but reports it missing from `invocation.InvocationService`. The model exists, so the
    /// method exists somewhere; this looks for it across services and hosts.
    ///
    /// The method-name oracle is sound here: a real method answers with a business error
    /// (e.g. "Language can not be empty"), a missing one answers "Method not found: <svc>/<m>".
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testHuntForWakeUpWithOtaDownloadReason() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedWeb = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let webToken = try XCTUnwrap(resolvedWeb)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let c3Base = try XCTUnwrap(URL(string:
            "https://\(c3["grpcHost"] as! String):\(c3["grpcPort"] as? Int ?? 443)"))
        let pccs = URL(string: "https://api.pccs-prod.plstr.io:443")!

        let commandToken = try await Self.authorize(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")

        print("\n========================================================")
        print("⏰ WAKEUP HUNT (reason = 1, OTA_DOWNLOAD)")

        // WakeUpRequest is `{1: reason}`; the invocation envelope wraps `{1: {1: vin}}`.
        var wakeBody = PolestarGRPC.invocationOnlyRequest(vin)
        wakeBody.append(Protobuf.intField(2, 1))          // reason = OTA_DOWNLOAD
        let bare = Protobuf.intField(1, 1)                 // bare WakeUpRequest{reason: 1}

        let targets: [(String, URL, String)] = [
            ("C3   invocation.InvocationService/WakeUp", c3Base, "/invocation.InvocationService/WakeUp"),
            ("C3   invocation.InvocationService/Wakeup", c3Base, "/invocation.InvocationService/Wakeup"),
            ("C3   invocation.InvocationService/WakeUpVehicle", c3Base, "/invocation.InvocationService/WakeUpVehicle"),
            ("C3   ota_mobcache.OtaDiscoveryService/WakeUp", c3Base, "/ota_mobcache.OtaDiscoveryService/WakeUp"),
            ("C3   ota_mobcache.SchedulerService/WakeUp", c3Base, "/ota_mobcache.SchedulerService/WakeUp"),
            ("C3   dtlinternet.DtlInternetService/WakeUp", c3Base, "/dtlinternet.DtlInternetService/WakeUp"),
            ("PCCS pccs.invocation.v1.InvocationService/WakeUp", pccs, "/pccs.invocation.v1.InvocationService/WakeUp")
        ] + ["Wake", "WakeVehicle", "WakeUpCar", "RequestWakeUp", "WakeUpRequest",
             "TriggerDownload", "InitiateDownload", "RequestDownload", "StartDownload",
             "SoftwareDownload", "OtaDownload", "CheckForUpdates", "RefreshSoftware",
             "SetConsent", "GiveConsent", "ConfirmUpdate", "PrepareInstallation"]
            .map { ("C3   invocation.InvocationService/\($0)", c3Base,
                    "/invocation.InvocationService/\($0)") }
        + ["WakeUp", "Wake", "TriggerDownload", "StartDownload", "RequestDownload",
           "SetConsent", "GiveConsent", "CheckForUpdates", "RefreshSoftwareInfo",
           "PrepareSoftware", "ActivateSoftware", "SetUpdateConsent"]
            .map { ("C3   ota_mobcache.OtaDiscoveryService/\($0)", c3Base,
                    "/ota_mobcache.OtaDiscoveryService/\($0)") }
        for (label, base, path) in targets {
            for (shape, body) in [("envelope+reason", wakeBody), ("bare reason", bare)] {
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.httpMethod = "POST"
                request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
                request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
                request.setValue("Bearer \(commandToken)", forHTTPHeaderField: "Authorization")
                request.setValue(vin, forHTTPHeaderField: "vin")
                request.httpBody = Protobuf.grpcFrame(body)
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 20
                guard let (stream, response) = try? await URLSession(configuration: config).bytes(for: request),
                      let http = response as? HTTPURLResponse else { continue }
                let status = http.value(forHTTPHeaderField: "grpc-status")
                let message = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? ""
                var header: [UInt8] = []; var frame = Data(); var expected: Int?
                do {
                    for try await byte in stream {
                        if expected == nil {
                            header.append(byte)
                            guard header.count == 5 else { continue }
                            expected = Int(header[1]) << 24 | Int(header[2]) << 16
                                | Int(header[3]) << 8 | Int(header[4])
                            if expected == 0 { break }
                            continue
                        }
                        frame.append(byte)
                        if frame.count == expected { break }
                    }
                } catch { }
                if message.contains("Method not found") {
                    print("  \(label) [\(shape)] → absent"); break   // shape is irrelevant if absent
                }
                print("  \(label) [\(shape)] → grpc-status=\(status ?? "OK") \(message)")
                if !frame.isEmpty {
                    print("      ⭐️ RESPONSE: \(frame.map { String(format: "%02x", $0) }.joined())")
                }
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Confirms the PCCS package-prefix rule for every service Hisingen addresses on that host.
    /// `absent` on the left column and `PRESENT` on the right means the current paths are wrong.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testConfirmPccsServicePathPrefixes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedToken = try await api.validAccessToken()
        let vin = try XCTUnwrap(resolvedVIN)
        let token = try XCTUnwrap(resolvedToken)
        let pccs = URL(string: "https://api.pccs-prod.plstr.io:443")!

        print("\n========================================================")
        print("🧭 PCCS SERVICE PATH CONFIRMATION")
        let pairs = [
            ("TargetSoc/GetTargetSoc",
             "/chronos.services.v1.TargetSocService/GetTargetSoc",
             "/pccs.chronos.services.v1.TargetSocService/GetTargetSoc"),
            ("AmpLimit/GetAmpLimit",
             "/chronos.services.v1.AmpLimitService/GetAmpLimit",
             "/pccs.chronos.services.v1.AmpLimitService/GetAmpLimit"),
            ("ChargeNow/StartOverrideChargeTimer",
             "/chronos.services.v1.ChargeNowService/StartOverrideChargeTimer",
             "/pccs.chronos.services.v1.ChargeNowService/StartOverrideChargeTimer"),
            ("GlobalChargeTimer/GetGlobalChargeTimerStream",
             "/chronos.services.v2.GlobalChargeTimerService/GetGlobalChargeTimerStream",
             "/pccs.chronos.services.v2.GlobalChargeTimerService/GetGlobalChargeTimerStream"),
            ("ParkingClimateTimer/GetTimers",
             "/chronos.services.v1.ParkingClimateTimerService/GetTimers",
             "/pccs.chronos.services.v1.ParkingClimateTimerService/GetTimers"),
            ("ChargeLocation/GetChargeLocations",
             "/chronos.services.v1.ChargeLocationService/GetChargeLocations",
             "/pccs.chronos.services.v1.ChargeLocationService/GetChargeLocations")
        ]
        for (label, current, proposed) in pairs {
            let a = await Self.methodStatus(base: pccs, path: current, vin: vin, token: token)
            let b = await Self.methodStatus(base: pccs, path: proposed, vin: vin, token: token)
            func verdict(_ s: String?) -> String { s == "12" ? "absent" : "PRESENT(\(s ?? "ok"))" }
            print("  \(label.padding(toLength: 42, withPad: " ", startingAt: 0)) "
                  + "current=\(verdict(a).padding(toLength: 14, withPad: " ", startingAt: 0)) "
                  + "pccs-prefixed=\(verdict(b))")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Classifies a GraphQL response as "field absent" vs "field exists, call was wrong".
    private static func oracle(query: String, token: String) async -> String {
        var request = URLRequest(url: URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return "transport error"
        }
        let body = String(decoding: data, as: UTF8.self)
        if body.contains("FieldUndefined") || body.contains("of type 'Mutation' is undefined") {
            return "absent"
        }
        if body.contains("\"errors\"") {
            // Trim to the first message so the distinguishing detail is visible.
            if let range = body.range(of: "\"message\":\"") {
                let rest = body[range.upperBound...]
                return "EXISTS? → " + String(rest.prefix(while: { $0 != "\"" }))
            }
            return "EXISTS? → " + String(body.prefix(120))
        }
        return "⭐️ SUCCEEDED → " + String(body.prefix(160))
    }

    private static func introspect(url: URL, headers: [String: String]) async {
        let query = """
        query IntrospectMutations {
          __schema {
            mutationType { fields { name description } }
            queryType { fields { name } }
          }
        }
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            print("  transport error"); return
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        print("  HTTP \(code)")
        // Surface only names that could plausibly relate to software/OTA.
        let interesting = ["software", "ota", "update", "download", "firmware", "install"]
        var hits: [String] = []
        for match in body.components(separatedBy: "\"name\":\"").dropFirst() {
            let name = String(match.prefix(while: { $0 != "\"" }))
            if interesting.contains(where: { name.lowercased().contains($0) }) { hits.append(name) }
        }
        if hits.isEmpty {
            print("  no software/OTA-related fields found; raw: \(body.prefix(300))")
        } else {
            print("  ⭐️ candidates: \(Set(hits).sorted().joined(separator: ", "))")
        }
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
        // `GetSoftwareInfo`/`GetSchedule` are *server-streaming*: the server writes a frame and
        // holds the HTTP/2 stream open. `URLSession.data(for:)` waits for END_STREAM and so
        // just times out — read incrementally and stop at the first complete frame, which is
        // what `PolestarGRPC.firstMessage` does.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("  ✗ non-HTTP response")
                return ([], nil)
            }
            print("  HTTP \(http.statusCode)")
            for (key, value) in http.allHeaderFields { print("  \(key): \(value)") }
            let status = http.value(forHTTPHeaderField: "grpc-status")
            if let message = http.value(forHTTPHeaderField: "grpc-message") {
                print("  grpc-message (decoded): \(message.removingPercentEncoding ?? message)")
            }

            var header: [UInt8] = []
            var body = Data()
            var expected: Int?
            var frames: [Data] = []
            do {
                for try await byte in stream {
                    if expected == nil {
                        header.append(byte)
                        guard header.count == 5 else { continue }
                        expected = Int(header[1]) << 24 | Int(header[2]) << 16
                            | Int(header[3]) << 8 | Int(header[4])
                        if expected == 0 { break }
                        continue
                    }
                    body.append(byte)
                    if body.count == expected { frames.append(body); break }
                }
            } catch {
                print("  (stream ended: \(error.localizedDescription))")
            }
            print("  frames: \(frames.count)")
            for frame in frames {
                print("  raw: \(frame.map { String(format: "%02x", $0) }.joined())")
            }
            if frames.isEmpty && (status == nil || status == "0") {
                print("  ⚠️ 200 OK, no grpc-status header, and no message frame — the real status")
                print("     is in HTTP/2 trailers that URLSession does not expose.")
            }
            return (frames, status)
        } catch {
            print("  ✗ transport error: \(error.localizedDescription)")
            return ([], nil)
        }
    }
}
#endif


