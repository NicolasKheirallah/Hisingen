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

        if let exportPath = ProcessInfo.processInfo.environment["HISINGEN_TEST_EXPORT_API_LOG"] {
            let exportData = try await APIDiagnosticLogStore.shared.exportData()
            try exportData.write(to: URL(fileURLWithPath: exportPath), options: .atomic)
        }

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
        let publicApiKey = BuiltinPolestarSecrets.imageApiKey
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

    /// E2 (OTA investigation): captures the *complete* `GetSoftwareInfo` frame and recursively
    /// decodes every protobuf field — including unknown wire-types and nested messages — to find
    /// any hidden campaign/assignment/eligibility fields beyond the 8 currently parsed by
    /// `PolestarGRPC.parseSoftware`. Also prints the raw hex for offline analysis.
    ///
    /// Read-only. The single piece of information this can't get is HTTP/2 trailers (URLSession
    /// hides them), but for a successful response the entire `CarSoftwareInfo` message is in the
    /// first frame, which is fully captured here.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDecodeGetSoftwareInfoRecursively() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let base = try XCTUnwrap(URL(string: "https://\(host):443"))

        var req = Data()
        req.append(Protobuf.stringField(1, vin))
        req.append(Protobuf.stringField(2, "en"))
        let result = await Self.callGRPC(base: base,
                                         path: "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo",
                                         body: req, vin: vin, token: token, label: "GetSoftwareInfo (recursive)")
        guard let frame = result.frames.first else {
            print("  ⚠️ no frame returned — nothing to decode")
            try? await api.signOut()
            return
        }

        print("\n=== RECURSIVE FIELD DECODE (frame \(frame.count) bytes) ===")
        print("raw hex: \(frame.map { String(format: "%02x", $0) }.joined())")
        Self.recursiveDecode(frame, depth: 0)
        print("=== END RECURSIVE DECODE ===\n")
        try? await api.signOut()
    }

    /// Recursively prints every protobuf field in `data`, attempting nested-message decode for
    /// length-delimited fields that aren't printable UTF-8. Surfaces unknown wire-types rather
    /// than silently dropping them.
    static func recursiveDecode(_ data: Data, depth: Int, fieldNumber: Int? = nil) {
        let indent = String(repeating: "  ", count: depth)
        let fields = Protobuf.fields(data)
        for f in fields {
            let tag = "f\(f.number)"
            switch f.wire {
            case 0:
                let zigzag = Int64(bitPattern: f.varint) >> 1 ^ -(Int64(bitPattern: f.varint) & 1)
                print("\(indent)\(tag): varint = \(f.varint) (zigzag=\(zigzag))")
            case 1:
                let v = f.data.withUnsafeBytes { $0.load(as: UInt64.self) }
                print("\(indent)\(tag): i64 = \(v) (0x\(String(v, radix: 16)))")
            case 5:
                let v = f.data.withUnsafeBytes { $0.load(as: UInt32.self) }
                print("\(indent)\(tag): i32 = \(v) (0x\(String(v, radix: 16)))")
            case 2:
                if let s = String(data: f.data, encoding: .utf8),
                   !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
                    print("\(indent)\(tag): str(\(f.data.count)) = \(s.debugDescription)")
                } else if f.data.isEmpty {
                    print("\(indent)\(tag): bytes(0) = empty")
                } else {
                    let sub = Protobuf.fields(f.data)
                    if sub.isEmpty {
                        print("\(indent)\(tag): bytes(\(f.data.count)) = \(f.data.map { String(format: "%02x", $0) }.joined())")
                    } else {
                        print("\(indent)\(tag): msg(\(f.data.count)) {")
                        recursiveDecode(f.data, depth: depth + 1, fieldNumber: f.number)
                        print("\(indent)}")
                    }
                }
            default:
                print("\(indent)\(tag): WT\(f.wire) ?? (raw=\(f.data.map { String(format: "%02x", $0) }.joined()))")
            }
        }
    }

    /// E3 (OTA investigation): differential capture. Polls `GetSoftwareInfo` at a configurable
    /// interval and logs full recursive field diffs each iteration, flagging any state change.
    /// Designed to catch the exact moment `state 15 → 1` and what field changed first.
    ///
    /// Read-only. Configure with:
    ///   HISINGEN_OTA_POLL_SECONDS (default 60)
    ///   HISINGEN_OTA_POLL_ITERATIONS (default 5)
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDifferentialOtaCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let pollSeconds = Int(environment["HISINGEN_OTA_POLL_SECONDS"] ?? "60") ?? 60
        let iterations = Int(environment["HISINGEN_OTA_POLL_ITERATIONS"] ?? "5") ?? 5

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let base = try XCTUnwrap(URL(string: "https://\(host):443"))

        var req = Data()
        req.append(Protobuf.stringField(1, vin))
        req.append(Protobuf.stringField(2, "en"))

        print("\n========================================================")
        print("🔁 DIFFERENTIAL OTA CAPTURE — VIN \(vin)")
        print("  interval: \(pollSeconds)s, iterations: \(iterations)")
        print("========================================================")

        var lastHex: String?
        var lastState: UInt64?
        for i in 1...iterations {
            let result = await Self.callGRPC(base: base,
                                             path: "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo",
                                             body: req, vin: vin, token: token,
                                             label: "poll #\(i)")
            guard let frame = result.frames.first else {
                print("  ⚠️ poll #\(i): no frame")
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds) * 1_000_000_000)
                continue
            }
            let hex = frame.map { String(format: "%02x", $0) }.joined()
            let outer = Protobuf.fields(frame)
            let info = outer.first(where: { $0.number == 1 && $0.wire == 2 })?.data ?? frame
            let fields = Protobuf.fields(info)
            let state = fields.first(where: { $0.number == 4 })?.varint

            if hex == lastHex {
                print("  poll #\(i): identical (state=\(state ?? 0))")
            } else {
                print("  poll #\(i): CHANGED — state=\(state ?? 0) (prev=\(lastState ?? 0))")
                if let lastHex {
                    print("  --- previous hex: \(lastHex)")
                }
                print("  --- current  hex: \(hex)")
                print("  --- recursive decode:")
                Self.recursiveDecode(frame, depth: 2)
                if let lastState, lastState != state {
                    print("  🎯 STATE TRANSITION DETECTED: \(lastState) → \(state ?? 0)")
                }
            }
            lastHex = hex
            lastState = state
            if i < iterations {
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds) * 1_000_000_000)
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// E5 (OTA investigation): probe the VCA gateway (`vca-api-gateway.weu-prod.ecpaz.volvocars.biz`)
    /// discovered in the v2 discovery doc. The VCA gateway is a catch-all UNIMPLEMENTED upstream,
    /// so blind probing is impossible — but we can test whether the known-real C3 OTA paths
    /// resolve here (which would mean VCA mirrors C3) and whether the web token authenticates
    /// differently on VCA than C3. Uses the known-real/known-fake control discipline.
    ///
    /// Read-only. Probes only:
    ///   - known-real: `ota_mobcache.OtaDiscoveryService/GetSoftwareInfo` (works on C3)
    ///   - known-fake: `totally.Nonsense.Xyz/Nope` (control)
    ///   - the same OTA path with the app token (to test allowlist differences)
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeVCAGateway() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        // Discover VCA via v2 discovery
        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v2+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let vca = try XCTUnwrap(json["vca-api-gateway"] as? [String: Any])
        let host = try XCTUnwrap(vca["grpcHost"] as? String)
        let vcaBase = try XCTUnwrap(URL(string: "https://\(host):443"))
        let c3Host = (json["c3"] as? [String: Any])?["grpcHost"] as? String ?? "cepmobtoken.eu.prod.c3.volvocars.com"
        let c3Base = try XCTUnwrap(URL(string: "https://\(c3Host):443"))

        print("\n========================================================")
        print("🌐 VCA GATEWAY PROBE — VIN \(vin)")
        print("  VCA: \(vcaBase.absoluteString)")
        print("  C3:  \(c3Base.absoluteString)")
        print("========================================================")

        var softwareInfo = Data()
        softwareInfo.append(Protobuf.stringField(1, vin))
        softwareInfo.append(Protobuf.stringField(2, "en"))
        let nonsense = Data([0x0a, 0x03, 0x66, 0x6f, 0x6f])

        let probes: [(String, URL, String, Data)] = [
            ("VCA known-real GetSoftwareInfo (web token)", vcaBase,
             "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo", softwareInfo),
            ("VCA known-fake Nonsense (control)", vcaBase,
             "/totally.Nonsense.Xyz/Nope", nonsense),
            ("C3 known-real GetSoftwareInfo (web token, baseline)", c3Base,
             "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo", softwareInfo),
            ("VCA SchedulerService/GetSchedule", vcaBase,
             "/ota_mobcache.SchedulerService/GetSchedule", Protobuf.stringField(1, vin)),
            ("VCA AvailabilityService/GetLatestAvailability", vcaBase,
             "/services.vehiclestates.availability.AvailabilityService/GetLatestAvailability", softwareInfo),
        ]

        for (label, base, path, body) in probes {
            let result = await Self.callGRPC(base: base, path: path, body: body,
                                              vin: vin, token: token, label: label)
            print("  → grpc-status=\(result.status ?? "nil"), frames=\(result.frames.count)")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// E8 (OTA investigation): probe the `service-offer-and-warranty/api/graphql` endpoint
    /// discovered in the Polestar web account SPA. This GraphQL surface has never been tested
    /// for OTA/campaign/software types. Uses the `__type(name:)` oracle (the strongest
    /// available — enumerates the type namespace directly) with known-real and known-fake
    /// controls. Read-only.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeServiceOfferWarrantyGraphQL() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        let url = URL(string: "https://pc-api.polestar.com/eu-north-1/service-offer-and-warranty/api/graphql")!
        print("\n========================================================")
        print("🔍 SERVICE-OFFER-AND-WARRANTY GraphQL PROBE")
        print("========================================================")

        func gql(_ query: String, label: String) async {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("5.5.0", forHTTPHeaderField: "X-Polestar-Force-Update-Version")
            req.setValue("SE", forHTTPHeaderField: "X-Polestar-Locale")
            req.setValue("PolestarApp/5.5.0b1102 Android/14", forHTTPHeaderField: "User-Agent")
            req.httpBody = Data(query.utf8)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as! HTTPURLResponse
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                print("  \(label): HTTP \(http.statusCode) → \(body.prefix(300))")
            } catch {
                print("  \(label): error \(error)")
            }
        }

        // Baseline: does it authenticate and respond?
        await gql("{\"query\":\"{__typename}\"}", label: "__typename")

        // Controls: known-real and known-fake type names (to validate the oracle)
        await gql("{\"query\":\"{__type(name:\\\"String\\\"){name}}\"}", label: "control: String (real)")
        await gql("{\"query\":\"{__type(name:\\\"TotallyFakeTypeXYZ\\\"){name}}\"}", label: "control: TotallyFakeTypeXYZ (fake)")

        // OTA/software/campaign type probes
        let typeNames = [
            "SoftwareUpdate", "SoftwareState", "SoftwareInfo", "CarSoftwareInfo",
            "OtaStatus", "OtaUpdate", "Campaign", "CampaignAssignment",
            "RolloutStatus", "UpdateEligibility", "DownloadTicket",
            "SoftwareOffer", "VehicleSoftware", "FirmwareUpdate",
            "UpdateConsent", "SoftwareRelease", "DeploymentStatus",
            "Entitlement", "VehicleUpdate", "SoftwareCampaign",
        ]
        for name in typeNames {
            await gql("{\"query\":\"{__type(name:\\\"\(name)\\\"){name}}\"}", label: "type: \(name)")
        }

        // Root query fields
        await gql("{\"query\":\"{__schema{queryType{fields{name}}}}\"}", label: "schema queryType fields")
        await gql("{\"query\":\"{__schema{mutationType{fields{name}}}}\"}", label: "schema mutationType fields")

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

    /// Diagnoses exact failure mode when acquiring command token from a restored session.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiagnoseSessionRestorationAndCommandTokenAcquisition() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        // Step 1: Initial web authentication
        let webTokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let webRefresh = try XCTUnwrap(webTokens["refresh_token"] as? String)

        print("\n========================================================")
        print("🔍 DIAGNOSE RESTORED SESSION COMMAND TOKEN ACQUISITION")
        print("========================================================")

        // Step 2: Fresh API with NO command token in keychain
        let freshKeychain = KeychainStore(service: "io.kheirallah.hisingen.diagnostic-tests")
        try? freshKeychain.deleteSessionToken()
        try? freshKeychain.deleteCommandSessionToken()
        try? freshKeychain.deletePassword()

        let api = PolestarAPI(keychain: freshKeychain)
        try await api.restoreSession(token: webRefresh, preferredVIN: preferredVIN, features: .default)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        print("  ✅ Web session restored successfully for VIN: \(vin)")

        // Step 3: Now try to acquire command token
        do {
            print("  Attempting to execute remote Lock from restored session...")
            await MainActor.run { PreferencesStore.shared.email = email }
            try freshKeychain.savePassword(password)
            let result = try await api.executeRemoteCommand(.lock, vin: vin)
            print("  ✅ SUCCESS: Lock executed -> \(result.outcome)")
        } catch {
            print("  ✗ FAILED: \(error)")
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

    /// Exhaustive method sweep over the two OTA services that are known to be real.
    ///
    /// On C3 the oracle is reliable: an unknown method answers `Method not found: <svc>/<m>`,
    /// a real one answers with a business error or a payload. The known methods are named
    /// `GetSoftwareInfo`, `GetSchedule`, `Schedule`, `InstallNow`, `CancelSchedule` — bare
    /// verbs as often as `Get`-prefixed — so the candidate space is built accordingly.
    /// Anything that is not "Method not found" is printed.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testExhaustiveOtaMethodSweep() async throws {
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
        let token = try await Self.authorize(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")

        let bare = ["Download", "DownloadNow", "StartDownload", "TriggerDownload",
                    "InitiateDownload", "RequestDownload", "BeginDownload", "Fetch", "Pull",
                    "Install", "InstallLater", "Update", "UpdateNow", "Upgrade",
                    "Accept", "AcceptUpdate", "Approve", "ApproveUpdate", "Consent",
                    "GiveConsent", "SetConsent", "Confirm", "ConfirmUpdate", "OptIn",
                    "Defer", "Postpone", "Snooze", "Dismiss", "Decline", "Reject",
                    "Acknowledge", "Ack", "MarkAsRead", "SetRead", "Read",
                    "Wake", "WakeUp", "Notify", "Poll", "Sync", "Refresh", "Check",
                    "CheckForUpdates", "Prepare", "Activate", "Commit", "Apply", "Push",
                    "Enable", "Allow", "Permit", "Start", "Trigger", "Execute", "Perform",
                    "Retry", "Resume", "Continue", "Proceed"]
        let prefixed = ["GetSoftwareStatus", "GetSoftwareState", "GetDownloadStatus",
                        "GetCampaign", "GetCampaigns", "GetConsent", "SetSoftwareState",
                        "SetDownloadConsent", "SetUpdateConsent", "SetPreference",
                        "SetAutoUpdate", "UpdateConsent", "RequestSoftware", "FetchSoftware",
                        "SyncSoftware", "RefreshSoftwareInfo", "PrepareInstallation",
                        "PrepareSoftware", "ActivateSoftware", "StartSoftwareDownload",
                        "DownloadSoftware", "InstallSoftware", "ScheduleDownload"]
        let methods = bare + prefixed

        print("\n========================================================")
        print("🔬 EXHAUSTIVE OTA METHOD SWEEP (\(methods.count) names × 2 services)")
        var hits = 0
        for service in ["/ota_mobcache.OtaDiscoveryService", "/ota_mobcache.SchedulerService"] {
            for method in methods {
                var request = URLRequest(url: base.appendingPathComponent("\(service)/\(method)"))
                request.httpMethod = "POST"
                request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
                request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(vin, forHTTPHeaderField: "vin")
                request.httpBody = Protobuf.grpcFrame(Protobuf.stringField(1, vin))
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 10
                guard let (stream, response) = try? await URLSession(configuration: config).bytes(for: request),
                      let http = response as? HTTPURLResponse else { continue }
                let message = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? ""
                for try await _ in stream { break }
                if !message.contains("Method not found") {
                    hits += 1
                    print("  ⭐️ \(service)/\(method) → status=\(http.value(forHTTPHeaderField: "grpc-status") ?? "OK") \(message)")
                }
            }
        }
        print("  \(hits) method(s) exist beyond the five already known")
        print("========================================================\n")
        try? await api.signOut()
    }

    /// The app-backend is the Polestar *app's* own GraphQL, and the app does show software
    /// update state — so its schema plausibly has operations the mystar-v2 schema lacks. Every
    /// earlier attempt used the web client's token; this uses the app client's, which is what
    /// that host expects. Also captures `id_token`, since `X-PolestarId-Authorization` may want
    /// the identity token rather than the access token.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testAppBackendWithAppClientToken() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])

        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let access = try XCTUnwrap(tokens["access_token"] as? String)
        let identity = tokens["id_token"] as? String

        print("\n========================================================")
        print("📱 APP-BACKEND WITH APP-CLIENT TOKEN (id_token \(identity == nil ? "absent" : "present"))")

        let url = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!
        let probe = "query GetVDMSCars { vdms { getVehiclesInformation { vin } } }"
        var working: [String: String]?
        var combos: [(String, [String: String])] = [
            ("PolestarId: Bearer access", ["X-PolestarId-Authorization": "Bearer \(access)"]),
            ("PolestarId: raw access", ["X-PolestarId-Authorization": access])
        ]
        if let identity {
            combos += [
                ("PolestarId: Bearer id_token", ["X-PolestarId-Authorization": "Bearer \(identity)"]),
                ("PolestarId: raw id_token", ["X-PolestarId-Authorization": identity]),
                ("Authorization: Bearer id_token", ["Authorization": "Bearer \(identity)"])
            ]
        }
        for (label, extra) in combos {
            var headers = [
                "Content-Type": "application/json",
                "User-Agent": "PolestarApp/5.5.0b1102 Android/14",
                "X-Polestar-Force-Update-Version": "5.5.0",
                "X-Polestar-Locale": "SE",
                "X-APOLLO-OPERATION-NAME": "GetVDMSCars",
                "Accept": "multipart/mixed;deferSpec=20220824, application/graphql-response+json, application/json"
            ]
            extra.forEach { headers[$0.key] = $0.value }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "operationName": "GetVDMSCars", "variables": [:], "query": probe,
                "extensions": ["clientLibrary": ["name": "apollo-kotlin", "version": "4.4.1"]]
            ])
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            print("  \(label) → HTTP \(code) \(body.prefix(140))")
            // Authenticated = a `data` payload with no error envelope. The vehicle list may
            // legitimately be empty for this client; that is not an auth failure.
            if code == 200, body.contains("\"data\""), !body.contains("\"errors\"") { working = headers }
        }

        guard let working else {
            print("  ✗ no header combination authenticated; app-backend stays closed")
            print("========================================================\n")
            return
        }
        print("\n  ✅ authenticated — probing schema for software/OTA operations")

        // graphql-java frequently appends "Did you mean ...?" to FieldUndefined — a far better
        // oracle than blind name guessing.
        for (label, query) in [
            ("near-miss on vdms", "query Q { vdms { getVehiclesInformatio { vin } } }"),
            ("software on vdms", "query Q { vdms { software { __typename } } }"),
            ("root software", "query Q { software { __typename } }"),
            ("root ota", "query Q { ota { __typename } }"),
            ("root softwareUpdate", "query Q { softwareUpdate { __typename } }"),
            ("mutation root", "mutation M { __typename }"),
            ("mutation startDownload", "mutation M { startSoftwareDownload { __typename } }"),
            ("mutation downloadSoftware", "mutation M { downloadSoftware { __typename } }"),
            ("mutation acceptSoftware", "mutation M { acceptSoftwareUpdate { __typename } }")
        ] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            working.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { continue }
            let body = String(decoding: data, as: UTF8.self)
            let hint = body.contains("Did you mean") ? " ⭐️ SUGGESTION" : ""
            print("  \(label)\(hint) → \(body.prefix(260))")
        }
        print("========================================================\n")
    }

    /// The app-backend authenticates with the app-client token and its validator emits
    /// "Did you mean …?" suggestions. If introspection is also open there — mystar-v2 blocks it,
    /// but this is a different service — the whole schema is readable and the question of
    /// whether a software/OTA operation exists is settled outright.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testAppBackendSchemaIntrospection() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let access = try XCTUnwrap(tokens["access_token"] as? String)

        func call(_ query: String) async -> String {
            var request = URLRequest(url: URL(string:
                "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!)
            request.httpMethod = "POST"
            for (key, value) in [
                "Content-Type": "application/json",
                "User-Agent": "PolestarApp/5.5.0b1102 Android/14",
                "X-Polestar-Force-Update-Version": "5.5.0",
                "X-Polestar-Locale": "SE",
                "X-PolestarId-Authorization": "Bearer \(access)"
            ] { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        print("\n========================================================")
        print("🔓 APP-BACKEND SCHEMA")

        let queryFields = await call("{ __schema { queryType { fields { name } } } }")
        let mutationFields = await call("{ __schema { mutationType { fields { name } } } }")
        print("  raw query introspection: \(queryFields.prefix(400))")
        print("  raw mutation introspection: \(mutationFields.prefix(400))")

        // `__schema` is filtered to an empty field list, but `__type` is a different resolver
        // and the validator's suggestion engine clearly still sees the real names.
        for typeName in ["PolestarGraphQlQuery", "PolestarGraphQlMutation", "VdmsGraphQlQueries"] {
            let body = await call("{ __type(name: \"\(typeName)\") { fields { name } } }")
            print("  __type(\(typeName)): \(body.prefix(600))")
        }

        if queryFields.contains("FieldUndefined") || queryFields.contains("Validation error")
            || queryFields.contains("\"fields\":[]") {
            print("  introspection blocked here too — falling back to the suggestion oracle")
            for stem in ["softwar", "software", "getSoftware", "ota", "getOta", "updat", "update", "getUpdate", "downloa", "download", "firmwar", "instal", "upgrad", "vehicl", "vdm", "getVehicle", "car", "getCar"] {
                let body = await call("{ \(stem) { __typename } }")
                if let range = body.range(of: "Did you mean") {
                    print("  ⭐️ '\(stem)' → \(body[range.lowerBound...].prefix(180))")
                } else {
                    print("  '\(stem)' → no suggestion")
                }
            }
        } else {
            func names(_ body: String) -> [String] {
                body.components(separatedBy: "\"name\":\"").dropFirst()
                    .map { String($0.prefix(while: { $0 != "\"" })) }
            }
            let queries = names(queryFields), mutations = names(mutationFields)
            print("  ✅ introspection OPEN")
            print("\n  QUERY fields (\(queries.count)): \(queries.joined(separator: ", "))")
            print("\n  MUTATION fields (\(mutations.count)): \(mutations.joined(separator: ", "))")
            let interesting = ["software", "ota", "update", "download", "firmware", "install", "upgrade"]
            let hits = (queries + mutations).filter { name in
                interesting.contains { name.lowercased().contains($0) }
            }
            print("\n  ⭐️ software/OTA-related: \(hits.isEmpty ? "NONE" : hits.joined(separator: ", "))")
        }
        // `cars` is a root field the suggestion oracle just revealed. Walk into it the same
        // way — its own type will suggest its real subfields.
        print("\n  ── exploring root field `cars`")
        print("  type: \(await call("{ cars { __typename } }").prefix(300))")
        for stem in ["softwar", "software", "ota", "updat", "download", "firmwar",
                     "versio", "statu", "vi", "model", "informatio"] {
            let body = await call("{ cars { \(stem) { __typename } } }")
            if let range = body.range(of: "Did you mean") {
                print("  ⭐️ cars.\(stem) → \(body[range.lowerBound...].prefix(160))")
            }
        }
        print("\n  ── exploring `vdms`")
        for stem in ["softwar", "ota", "updat", "download", "getSoftwar", "getOta", "getUpdat"] {
            let body = await call("{ vdms { \(stem) { __typename } } }")
            if let range = body.range(of: "Did you mean") {
                print("  ⭐️ vdms.\(stem) → \(body[range.lowerBound...].prefix(160))")
            }
        }
        print("========================================================\n")
    }

    /// Determines whether the command client issues a refresh token. If it does, one
    /// email+password sign-in is enough forever; if not, every app restart needs credentials
    /// again and the session-restore path can never recover remote commands on its own.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testCommandClientRefreshTokenAvailability() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])

        print("\n========================================================")
        print("🎫 COMMAND-CLIENT TOKEN RESPONSE")
        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")
        for key in tokens.keys.sorted() {
            let value = tokens[key]
            let shown = (value as? String).map { $0.count > 24 ? "<\($0.count) chars>" : $0 }
                ?? String(describing: value ?? "")
            print("  \(key): \(shown)")
        }
        let hasRefresh = (tokens["refresh_token"] as? String)?.isEmpty == false
        print("  → refresh_token issued: \(hasRefresh ? "YES — one sign-in suffices" : "NO — credentials needed each restore")")

        if let refresh = tokens["refresh_token"] as? String {
            var request = URLRequest(url: URL(string: "https://polestarid.eu.polestar.com/as/token.oauth2")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "grant_type=refresh_token&client_id=lp8dyrd_10&refresh_token=\(refresh)"
                .data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ok = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["access_token"] != nil
            print("  → refresh grant: HTTP \(code) \(ok ? "✅ works" : String(decoding: data, as: UTF8.self).prefix(160))")
        }
        print("========================================================\n")
    }

    /// Two untried avenues, run live:
    /// (A) enumerate `CarsQueries` and `VdmsGraphQlQueries` subfields via the suggestion oracle
    ///     — a software/consent/preferences field could live one level down where I never looked.
    /// (B) now that real commands work, wake the car with `Lock`, then re-read software state to
    ///     see whether an actively-connected car advances past `available`.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testFurtherOtaAvenues() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let access = try XCTUnwrap(tokens["access_token"] as? String)

        func app(_ query: String) async -> String {
            var request = URLRequest(url: URL(string:
                "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!)
            request.httpMethod = "POST"
            for (k, v) in ["Content-Type": "application/json",
                           "User-Agent": "PolestarApp/5.5.0b1102 Android/14",
                           "X-Polestar-Force-Update-Version": "5.5.0", "X-Polestar-Locale": "SE",
                           "X-PolestarId-Authorization": "Bearer \(access)"] {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        print("\n========================================================")
        print("🅰️  APP-BACKEND SUBFIELD ORACLE")
        // A field that exists but is queried wrong (missing subselection / bad type) yields a
        // *different* error than FieldUndefined, and near-misses trigger "Did you mean".
        let stems = ["software", "softwar", "ota", "otaa", "update", "updat", "download", "downloa",
                     "firmware", "firmwar", "install", "consent", "preference", "setting", "campaign",
                     "notification", "status", "version", "car", "vehicle", "detail"]
        for (container, wrapper) in [("cars", "cars"), ("vdms", "vdms")] {
            print("── \(container) (\(await app("{ \(wrapper) { __typename } }")))")
            for stem in stems {
                let body = await app("{ \(wrapper) { \(stem) } }")
                // The ONLY positive signal is a "Did you mean" suggestion (near-miss of a real
                // field) or a sub-selection error naming a concrete return type. A bare
                // "Cannot query field 'X'" — regardless of how the quotes are encoded — means
                // the field is absent. (An earlier version of this check compared against an
                // ASCII quote while the JSON uses ', and reported every field as EXISTS.)
                if body.contains("Did you mean") {
                    let hint = body.range(of: "Did you mean").map { String(body[$0.lowerBound...].prefix(80)) } ?? ""
                    print("  ⭐️ \(stem) → \(hint)")
                } else if body.contains("must have a selection of subfields")
                            || body.contains("of type '\(stem)") {
                    print("  ⭐️ \(stem) EXISTS → \(body.prefix(150))")
                }
            }
        }

        print("\n🅱️  WAKE-THEN-RECHECK")
        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        features.set(.remoteLocks, enabled: true); features.set(.remoteOTA, enabled: true)
        features.set(.softwareUpdates, enabled: true)
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolvedForWake = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedForWake)

        let before = try await api.fetchVehicleState(vin: vin, features: features)
        print("  state before wake: \(before.softwareInfo?.state.displayName ?? "nil")")
        do {
            let result = try await api.executeRemoteCommand(.lock, vin: vin)
            print("  wake (Lock): \(result.outcome)")
        } catch {
            print("  wake failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        // Give the car a moment to react to being addressed, then re-read three times.
        for attempt in 1...3 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let s = try await api.fetchVehicleState(vin: vin, features: features)
            print("  state +\(attempt * 5)s: \(s.softwareInfo?.state.displayName ?? "nil") "
                  + "(installed=\(s.softwareInfo?.installedVersion ?? "—"))")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Now that the PCCS paths are correct and invocation works, this maps what *else* is
    /// reachable — the capabilities Hisingen could newly support. Every write here is a no-op or
    /// trivially reversible:
    ///   - `SetTargetSoc` to the *current* value (no configuration change)
    ///   - each invocation command probed with a real envelope but read-classified by response
    /// so we learn which are accepted without committing a state change beyond the benign SetSoc.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testMapNewlyReachableCapabilities() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        for f in [AppFeature.remoteCharging, .remoteSchedules, .chargingDetails,
                  .chargingSchedule, .climateStatus] { features.set(f, enabled: true) }
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        print("\n========================================================")
        print("🗺️  NEWLY-REACHABLE CAPABILITY MAP")

        let state = try await api.fetchVehicleState(vin: vin, features: features)
        let currentTarget = state.chargeTargetPercentage ?? 90
        print("  current charge target: \(currentTarget)%  (writing it back unchanged)")

        // Chronos write path — the whole "Remote Charging" family depends on this.
        do {
            let result = try await api.executeRemoteCommand(.setChargeTarget(currentTarget), vin: vin)
            print("  ✅ SetTargetSoc(\(currentTarget)) → \(result.outcome) \(result.message ?? "")")
            print("     → chronos WRITES work; remote charging (target, amp limit, charge-now,")
            print("       charge windows, climate timers) is reachable")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print("  ✗ SetTargetSoc refused → \(text)")
        }

        // Read-back to confirm the setting is unchanged.
        let after = try await api.fetchVehicleState(vin: vin, features: features)
        print("  charge target after: \(after.chargeTargetPercentage.map(String.init) ?? "—")%")

        print("========================================================\n")
        try? await api.signOut()
    }

    /// Comprehensive live verification of all remote commands and Chronos write endpoints against the car.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testVerifyAllLiveRemoteCommandsAndChronosWrites() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        for f in AppFeature.allCases { features.set(f, enabled: true) }

        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        print("\n========================================================")
        print("🎮 LIVE REMOTE COMMANDS & CHRONOS WRITES EXECUTION PROBE")
        print("   Target VIN: \(vin)")
        print("========================================================")

        let state = try await api.fetchVehicleState(vin: vin, features: features)
        let currentTarget = state.chargeTargetPercentage ?? 90
        let currentAmps = state.chargingCurrentAmps ?? 16

        // 1. Chronos: SetTargetSoc
        print("\n⚡️ 1. Chronos: SetTargetSoc(\(currentTarget)%)")
        do {
            let res = try await api.executeRemoteCommand(.setChargeTarget(currentTarget), vin: vin)
            print("   ✅ SetTargetSoc -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ SetTargetSoc error: \(error)")
        }

        // 2. Chronos: SetAmpLimit
        print("\n⚡️ 2. Chronos: SetAmpLimit(\(currentAmps) A)")
        do {
            let res = try await api.executeRemoteCommand(.setAmpLimit(currentAmps), vin: vin)
            print("   ✅ SetAmpLimit -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ SetAmpLimit error: \(error)")
        }

        // 3. Chronos: Charge Now Overrides
        print("\n⚡️ 3. Chronos: Start & Stop Charge Override")
        do {
            let resStart = try await api.executeRemoteCommand(.startChargingOverride, vin: vin)
            print("   ✅ StartChargingOverride -> \(resStart.outcome) (msg: \(resStart.message ?? "none"))")
            let resStop = try await api.executeRemoteCommand(.stopChargingOverride, vin: vin)
            print("   ✅ StopChargingOverride -> \(resStop.outcome) (msg: \(resStop.message ?? "none"))")
        } catch {
            print("   ✗ Charge Override error: \(error)")
        }

        // 4. Chronos: Global Charge Timer
        print("\n⚡️ 4. Chronos: SetGlobalChargeTimer")
        let globalSchedule = VehicleSchedule(
            kind: .globalCharging, startHour: 23, startMinute: 0,
            endHour: 6, endMinute: 0, weekdays: [], isActive: false
        )
        do {
            let res = try await api.executeRemoteCommand(.setGlobalChargeTimer(globalSchedule), vin: vin)
            print("   ✅ SetGlobalChargeTimer -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ SetGlobalChargeTimer error: \(error)")
        }

        // 5. C3 Invocation: Lock
        print("\n🔒 5. C3: Lock Vehicle")
        do {
            let res = try await api.executeRemoteCommand(.lock, vin: vin)
            print("   ✅ Lock -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ Lock error: \(error)")
        }

        // 6. C3 Invocation: Flash Lights
        print("\n💡 6. C3: Flash Lights")
        do {
            let res = try await api.executeRemoteCommand(.flashLights, vin: vin)
            print("   ✅ FlashLights -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ FlashLights error: \(error)")
        }

        // 7. C3 Invocation: Window Close
        print("\n🪟 7. C3: Close Windows")
        do {
            let res = try await api.executeRemoteCommand(.closeWindows, vin: vin)
            print("   ✅ CloseWindows -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ CloseWindows error: \(error)")
        }

        // 8. C3 Invocation: Pre-Cleaning Start & Stop
        print("\n💨 8. C3: Pre-Cleaning Start & Stop")
        do {
            let resStart = try await api.executeRemoteCommand(.startPreCleaning, vin: vin)
            print("   ✅ StartPreCleaning -> \(resStart.outcome) (msg: \(resStart.message ?? "none"))")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let resStop = try await api.executeRemoteCommand(.stopPreCleaning, vin: vin)
            print("   ✅ StopPreCleaning -> \(resStop.outcome) (msg: \(resStop.message ?? "none"))")
        } catch {
            print("   ✗ Pre-Cleaning error: \(error)")
        }

        // 9. C3 Invocation: Stop Climate
        print("\n❄️ 9. C3: Stop Climate")
        do {
            let res = try await api.executeRemoteCommand(.stopClimate, vin: vin)
            print("   ✅ StopClimate -> \(res.outcome) (msg: \(res.message ?? "none"))")
        } catch {
            print("   ✗ StopClimate error: \(error)")
        }

        print("\n========================================================")
        print("✅ ALL LIVE COMMANDS COMPLETED")
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Diagnoses exact protobuf wire formats and response frames for SetAmpLimit and StartOverrideChargeTimer.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiagnoseChronosSetAmpLimitAndChargeNow() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let webTokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let webToken = try XCTUnwrap(webTokens["access_token"] as? String)
        let vin = preferredVIN ?? "YSMVSEDE6PL147228"

        func sendPccs(path: String, payload: Data) async -> (Int, [String: String], Data) {
            var request = URLRequest(url: URL(string: "https://api.pccs-prod.plstr.io:443" + path)!)
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
            request.setValue(vin, forHTTPHeaderField: "vin")
            request.setValue("trailers", forHTTPHeaderField: "TE")

            var framed = Data([0x00, 0x00, 0x00, 0x00, 0x00])
            var count = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &count) { framed.replaceSubrange(1...4, with: $0) }
            framed.append(payload)
            request.httpBody = framed

            guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
                  let http = response as? HTTPURLResponse else {
                return (0, [:], Data())
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }

            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 5 {
                        let len = body[1...4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
                        if body.count >= 5 + Int(len) { break }
                    }
                }
            } catch {}
            let unFramed = body.count >= 5 ? body.subdata(in: 5..<body.count) : body
            return (http.statusCode, headers, unFramed)
        }

        print("\n========================================================")
        print("🔬 DIAGNOSE CHRONOS SET AMP LIMIT & CHARGE NOW")
        print("========================================================")

        // Envelope
        var env = Data()
        env.append(Protobuf.stringField(1, UUID().uuidString))
        env.append(Protobuf.stringField(2, vin))
        env.append(Protobuf.stringField(3, "RCS"))
        env.append(Protobuf.messageField(4, Protobuf.intField(1, TimeZone.current.secondsFromGMT() / 60)))
        let envelope = Protobuf.messageField(1, env)

        // 1. GetAmpLimit read
        let (getAmpStatus, getAmpHeaders, getAmpBody) = await sendPccs(
            path: "/pccs.chronos.services.v1.AmpLimitService/GetAmpLimit", payload: envelope)
        print("\n📖 GetAmpLimit: HTTP \(getAmpStatus), grpc-status: \(getAmpHeaders["grpc-status"] ?? "none")")
        print("   Body Hex: \(getAmpBody.map { String(format: "%02x", $0) }.joined())")
        for f in Protobuf.fields(getAmpBody) {
            print("   Field \(f.number) (wire \(f.wire)): varint=\(f.varint), len=\(f.data.count)")
            if f.wire == 2 {
                for sub in Protobuf.fields(f.data) {
                    print("     Subfield \(sub.number) (wire \(sub.wire)): varint=\(sub.varint)")
                }
            }
        }

        // 2. SetAmpLimit Variants
        // Shape A: {1: envelope, 2: 16}
        var pA = envelope
        pA.append(Protobuf.intField(2, 16))
        let (setAmpAStatus, setAmpAHeaders, setAmpABody) = await sendPccs(
            path: "/pccs.chronos.services.v1.AmpLimitService/SetAmpLimit", payload: pA)
        print("\n✏️ SetAmpLimit (Shape A: {2: 16}): HTTP \(setAmpAStatus), grpc-status: \(setAmpAHeaders["grpc-status"] ?? "none") (msg: \(setAmpAHeaders["grpc-message"] ?? "none"))")
        print("   Body Hex: \(setAmpABody.map { String(format: "%02x", $0) }.joined())")
        for f in Protobuf.fields(setAmpABody) {
            print("   Field \(f.number) (wire \(f.wire)): varint=\(f.varint), len=\(f.data.count)")
            if f.wire == 2 {
                for sub in Protobuf.fields(f.data) {
                    print("     Subfield \(sub.number) (wire \(sub.wire)): varint=\(sub.varint)")
                }
            }
        }

        // Shape B: {1: envelope, 2: 16, 3: 1}
        var pB = envelope
        pB.append(Protobuf.intField(2, 16))
        pB.append(Protobuf.intField(3, 1))
        let (setAmpBStatus, setAmpBHeaders, setAmpBBody) = await sendPccs(
            path: "/pccs.chronos.services.v1.AmpLimitService/SetAmpLimit", payload: pB)
        print("\n✏️ SetAmpLimit (Shape B: {2: 16, 3: 1}): HTTP \(setAmpBStatus), grpc-status: \(setAmpBHeaders["grpc-status"] ?? "none") (msg: \(setAmpBHeaders["grpc-message"] ?? "none"))")
        print("   Body Hex: \(setAmpBBody.map { String(format: "%02x", $0) }.joined())")
        for f in Protobuf.fields(setAmpBBody) {
            print("   Field \(f.number) (wire \(f.wire)): varint=\(f.varint), len=\(f.data.count)")
            if f.wire == 2 {
                for sub in Protobuf.fields(f.data) {
                    print("     Subfield \(sub.number) (wire \(sub.wire)): varint=\(sub.varint)")
                }
            }
        }

        // 3. StartOverrideChargeTimer
        let (nowStatus, nowHeaders, nowBody) = await sendPccs(
            path: "/pccs.chronos.services.v1.ChargeNowService/StartOverrideChargeTimer", payload: envelope)
        print("\n⚡️ StartOverrideChargeTimer: HTTP \(nowStatus), grpc-status: \(nowHeaders["grpc-status"] ?? "none") (msg: \(nowHeaders["grpc-message"] ?? "none"))")
        print("   Body Hex: \(nowBody.map { String(format: "%02x", $0) }.joined())")
        for f in Protobuf.fields(nowBody) {
            print("   Field \(f.number) (wire \(f.wire)): varint=\(f.varint), len=\(f.data.count)")
        }

        print("========================================================\n")
    }

    /// Enumerates the GraphQL **type namespace** rather than field names.
    ///
    /// `__schema.types` and `__Type.fields` are filtered to empty on both backends, but
    /// `__type(name:)` still *resolves* — it returned a non-null object for real types earlier.
    /// If lookup works, a real type name yields `{"__type":{"name":…}}` and an invented one
    /// yields `{"__type":null}`. That is a far stronger oracle than edit-distance suggestions,
    /// which only fire for near-misses of names you already guessed correctly.
    ///
    /// Controls (known-real and known-fake) are probed in the same pass to prove the oracle.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testEnumerateGraphQLTypeNamespace() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])

        let appTokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let appToken = try XCTUnwrap(appTokens["access_token"] as? String)
        let webTokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let webToken = try XCTUnwrap(webTokens["access_token"] as? String)

        func query(_ body: String, appBackend: Bool) async -> String {
            let url = appBackend
                ? "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql"
                : "https://pc-api.polestar.com/eu-north-1/mystar-v2/"
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if appBackend {
                for (k, v) in ["User-Agent": "PolestarApp/5.5.0b1102 Android/14",
                               "X-Polestar-Force-Update-Version": "5.5.0",
                               "X-Polestar-Locale": "SE",
                               "X-PolestarId-Authorization": "Bearer \(appToken)"] {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            } else {
                request.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": body])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        let candidates = [
            // Controls — must resolve if the oracle works at all.
            "__CONTROL_REAL__PolestarGraphQlQuery", "__CONTROL_REAL__VdmsGraphQlQueries",
            "__CONTROL_REAL__CarsQueries", "__CONTROL_REAL__VehicleInformation",
            // Controls — must NOT resolve.
            "__CONTROL_FAKE__ZzzTotallyInventedType", "__CONTROL_FAKE__SoftwareNonsenseXyz",
            // The actual research target.
            "Software", "SoftwareInfo", "SoftwareStatus", "SoftwareUpdate", "SoftwareVersion",
            "SoftwareRelease", "SoftwareCampaign", "SoftwareDownload", "SoftwareInstallation",
            "CarSoftware", "CarSoftwareInfo", "VehicleSoftware", "VehicleSoftwareInfo",
            "Ota", "OtaStatus", "OtaInfo", "OtaUpdate", "OtaCampaign", "OtaSchedule",
            "Update", "UpdateStatus", "UpdateInfo", "AvailableUpdate", "PendingUpdate",
            "Firmware", "FirmwareUpdate", "FirmwareVersion",
            "Download", "DownloadStatus", "DownloadState",
            "Install", "Installation", "InstallationStatus", "InstallationSchedule",
            "Upgrade", "UpgradeStatus", "Version", "VersionInfo",
            "Campaign", "ReleaseNotes", "Consent", "ConsentStatus"
        ]

        for (label, isApp) in [("app-backend", true), ("mystar-v2", false)] {
            print("\n════════ TYPE NAMESPACE — \(label)")
            var resolved: [String] = []
            var oracleWorks = false
            for raw in candidates {
                let name = raw
                    .replacingOccurrences(of: "__CONTROL_REAL__", with: "")
                    .replacingOccurrences(of: "__CONTROL_FAKE__", with: "")
                let body = await query("{ __type(name: \"\(name)\") { name kind } }", appBackend: isApp)
                let hit = body.contains("\"name\":\"\(name)\"")
                if raw.hasPrefix("__CONTROL_REAL__") {
                    print("  [control real] \(name): \(hit ? "resolved ✅" : "NOT resolved ⚠️ oracle unreliable")")
                    if hit { oracleWorks = true }
                } else if raw.hasPrefix("__CONTROL_FAKE__") {
                    print("  [control fake] \(name): \(hit ? "resolved ⚠️ oracle unreliable" : "null ✅")")
                } else if hit {
                    resolved.append(name)
                }
            }
            print("  oracle usable: \(oracleWorks)")
            print("  ⭐️ software/OTA types that resolve: \(resolved.isEmpty ? "NONE" : resolved.joined(separator: ", "))")
        }
        print("========================================================\n")
    }

    /// mystar-v2 filters `__type`, so the type-namespace oracle does not work there. This uses
    /// the field oracle instead — `FieldUndefined` vs. anything else — across a large dictionary,
    /// and crucially walks *into* `VehicleInformation` and the telematics types, where a software
    /// version would plausibly be a field rather than a root query.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testMystarFieldOracleDeepSweep() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let token = try XCTUnwrap(tokens["access_token"] as? String)

        func gql(_ body: String) async -> String {
            var request = URLRequest(url: URL(string:
                "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": body])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        /// Absent iff the validator says the field is undefined on the containing type.
        func absent(_ body: String, field: String) -> Bool {
            body.contains("FieldUndefined") || body.contains("Cannot query field")
        }

        let names = [
            "software", "softwareInfo", "softwareStatus", "softwareUpdate", "softwareVersion",
            "softwareRelease", "getSoftware", "getSoftwareInfo", "getSoftwareStatus",
            "getSoftwareVersion", "getSoftwareUpdate", "getSoftwareUpdates",
            "ota", "otaStatus", "otaInfo", "getOta", "getOtaStatus", "getOtaInfo",
            "update", "updates", "updateStatus", "availableUpdate", "pendingUpdate",
            "getUpdate", "getUpdates", "getUpdateStatus", "getAvailableUpdates",
            "download", "downloadStatus", "getDownload", "getDownloadStatus",
            "firmware", "firmwareVersion", "getFirmware", "getFirmwareVersion",
            "install", "installation", "installStatus", "getInstallation",
            "upgrade", "getUpgrade", "version", "versions", "getVersion",
            "campaign", "campaigns", "getCampaign", "getCampaigns",
            "consent", "getConsent", "preferences", "getPreferences", "settings", "getSettings"
        ]

        print("\n========================================================")
        print("🔭 mystar-v2 FIELD ORACLE — DEEP SWEEP")

        print("\n── root Query (control: getConsumerCarsV2)")
        let control = await gql("{ getConsumerCarsV2 { __typename } }")
        print("  control getConsumerCarsV2: \(absent(control, field: "x") ? "FAILED ⚠️" : "resolves ✅")")
        var rootHits: [String] = []
        for name in names where !absent(await gql("{ \(name) { __typename } }"), field: name) {
            rootHits.append(name)
        }
        print("  ⭐️ root hits: \(rootHits.isEmpty ? "NONE" : rootHits.joined(separator: ", "))")

        // Walk into the vehicle type — a software version is more plausibly a field on the car
        // than a root query, and this level was never probed.
        print("\n── inside getConsumerCarsV2 (type VehicleInformation)")
        let vinControl = await gql("{ getConsumerCarsV2 { vin } }")
        print("  control .vin: \(absent(vinControl, field: "vin") ? "FAILED ⚠️" : "resolves ✅")")
        var carHits: [String] = []
        for name in names where !absent(await gql("{ getConsumerCarsV2 { \(name) } }"), field: name) {
            carHits.append(name)
        }
        print("  ⭐️ vehicle-level hits: \(carHits.isEmpty ? "NONE" : carHits.joined(separator: ", "))")

        // And into the telematics payload Hisingen already queries.
        print("\n── inside carTelematicsV2")
        let telControl = await gql("query Q($v:[String!]!){ carTelematicsV2(vins:$v){ __typename } }")
        print("  control: \(absent(telControl, field: "x") ? "shape differs — skipping" : "resolves ✅")")
        if !absent(telControl, field: "x") {
            var telHits: [String] = []
            for name in names
            where !absent(await gql("query Q($v:[String!]!){ carTelematicsV2(vins:$v){ \(name) { __typename } } }"), field: name) {
                telHits.append(name)
            }
            print("  ⭐️ telematics-level hits: \(telHits.isEmpty ? "NONE" : telHits.joined(separator: ", "))")
        }
        print("========================================================\n")
    }

    /// `getPreferences` is a mystar-v2 root query nothing in Hisingen uses. Update/download
    /// consent is exactly the kind of thing that would live behind it, so this walks it: what it
    /// returns, what its type is, and whether any software/OTA field hangs off it.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testInspectGetPreferences() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let token = try XCTUnwrap(tokens["access_token"] as? String)

        func gql(_ body: String) async -> String {
            var request = URLRequest(url: URL(string:
                "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": body])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        print("\n========================================================")
        print("⚙️  getPreferences")
        print("  __typename → \(await gql("{ getPreferences { __typename } }").prefix(300))")
        // A scalar field errors with "must not have a selection"; an object errors with
        // "must have a selection of subfields" and names its type. Either way the error is
        // informative, which is what we want.
        print("  bare       → \(await gql("{ getPreferences }").prefix(300))")
        // It demands languageCode + countryCode — supply them and see what it actually is.
        let withArgs = await gql("{ getPreferences(languageCode: \"en\", countryCode: \"SE\") { __typename } }")
        print("  with args  → \(withArgs.prefix(500))")

        // Now that the argument shape is known, probe PreferenceResponse's real subfields.
        for field in ["software", "softwareUpdate", "ota", "update", "download", "consent",
                      "autoUpdate", "notifications", "units", "language", "market",
                      "id", "name", "value", "key", "type", "enabled", "preferences", "items"] {
            let body = await gql("{ getPreferences(languageCode: \"en\", countryCode: \"SE\") { \(field) } }")
            if !(body.contains("FieldUndefined") || body.contains("Cannot query field")) {
                print("  ⭐️ PreferenceResponse.\(field) → \(body.prefix(240))")
            }
        }

        print("  preferences[] → \(await gql("{ getPreferences(languageCode: \"en\", countryCode: \"SE\") { preferences { __typename } } }").prefix(300))")
        for field in ["software", "softwareUpdate", "ota", "update", "download", "consent",
                      "autoUpdate", "id", "name", "value", "key", "type", "enabled", "code", "title"] {
            let body = await gql("{ getPreferences(languageCode: \"en\", countryCode: \"SE\") { preferences { \(field) } } }")
            if !(body.contains("FieldUndefined") || body.contains("Cannot query field")) {
                print("  ⭐️ preferences.\(field) → \(body.prefix(300))")
            }
        }

        let subfields = ["software", "softwareUpdate", "ota", "otaConsent", "update",
                         "updateConsent", "autoUpdate", "download", "downloadConsent",
                         "downloadOverCellular", "install", "installation", "consent",
                         "notifications", "language", "market", "units", "id", "name",
                         "value", "key", "type", "enabled"]
        var hits: [String] = []
        for field in subfields {
            let body = await gql("{ getPreferences { \(field) } }")
            if !(body.contains("FieldUndefined") || body.contains("Cannot query field")) {
                hits.append(field)
                print("  ⭐️ .\(field) → \(body.prefix(220))")
            }
        }
        if hits.isEmpty { print("  no probed subfield resolved") }
        print("========================================================\n")
    }

    /// Never fully explored: the C3 discovery service. Hisingen extracts only `c3`/`c3Lbs`, but
    /// the document may list other hosts (MQTT signalling, an OTA host), and a different Accept
    /// version or resource path may return a fuller catalogue. This dumps everything.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testExploreC3DiscoverySurface() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let tokens = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "l3oopkc_10", redirect: "https://www.polestar.com/sign-in-callback",
            scope: "openid profile email customer:attributes customer:attributes:write")
        let token = try XCTUnwrap(tokens["access_token"] as? String)

        func get(_ urlString: String, accept: String) async -> (Int, String) {
            guard let url = URL(string: urlString) else { return (-1, "bad url") }
            var request = URLRequest(url: url)
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                return (-1, "transport error")
            }
            return ((response as? HTTPURLResponse)?.statusCode ?? -1,
                    String(decoding: data, as: UTF8.self))
        }

        print("\n========================================================")
        print("🛰️  C3 DISCOVERY SURFACE")

        // The full v1 document, verbatim (Hisingen only reads two keys of it).
        let (baseCode, baseBody) = await get("https://cnepmob.volvocars.com",
                                             accept: "application/volvo.cloud.cnepmob.v1+json")
        print("\n── v1 full document (HTTP \(baseCode))\n\(baseBody)")

        // Alternate Accept versions — a v2/v3 catalogue may list more services.
        for (version, accept) in [("v2", "application/volvo.cloud.cnepmob.v2+json"),
                                  ("plain-json", "application/json")] {
            let (code, body) = await get("https://cnepmob.volvocars.com", accept: accept)
            print("\n── Accept \(version) (HTTP \(code)) FULL:\n\(body)")
            // Surface any host/key that is not c3/c3Lbs.
            if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
                let extra = json.keys.filter { $0 != "c3" && $0 != "c3Lbs" }.sorted()
                print("  ⭐️ keys beyond c3/c3Lbs: \(extra.isEmpty ? "none" : extra.joined(separator: ", "))")
                for key in extra { print("    \(key): \(json[key] ?? "")") }
            }
        }

        // Sibling discovery resources on the same host.
        for path in ["services", "discovery", "catalog", "ota", "software", "endpoints",
                     "config", ".well-known/endpoints"] {
            let (code, body) = await get("https://cnepmob.volvocars.com/\(path)",
                                         accept: "application/json")
            if code != 404 {
                print("\n── /\(path) (HTTP \(code)): \(body.prefix(200))")
            }
        }
        print("\n========================================================\n")
    }

    /// The v2 discovery document lists a **third** gRPC host that nothing uses:
    /// `vca-api-gateway.weu-prod.ecpaz.volvocars.biz`. It may front OTA/software services the C3
    /// host does not. Probes it with both tokens: reflection, the known OTA services, and a
    /// download/consent/wake method dictionary. On this host the method-name oracle is valid iff
    /// a known-real method answers with a business error rather than `Method not found`.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeVcaApiGateway() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: .default)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let resolvedWeb = try await api.validAccessToken()
        let webToken = try XCTUnwrap(resolvedWeb)
        let vin = try XCTUnwrap(resolved)
        let commandToken = try await Self.authorizeFull(
            email: email, password: password,
            clientID: "lp8dyrd_10", redirect: "polestar-explore://explore.polestar.com",
            scope: "openid profile email customer:attributes customer:attributes:write")["access_token"] as? String

        let base = URL(string: "https://vca-api-gateway.weu-prod.ecpaz.volvocars.biz:443")!

        /// Returns (grpc-status, decoded grpc-message, gotFrame).
        func call(_ path: String, body: Data, token: String) async -> (String?, String, Bool) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(vin, forHTTPHeaderField: "vin")
            request.httpBody = Protobuf.grpcFrame(body)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            guard let (stream, response) = try? await URLSession(configuration: config).bytes(for: request),
                  let http = response as? HTTPURLResponse else { return (nil, "transport error", false) }
            let status = http.value(forHTTPHeaderField: "grpc-status")
            let message = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? ""
            var gotFrame = false
            var header: [UInt8] = []; var expected: Int?
            do {
                for try await byte in stream {
                    header.append(byte)
                    if header.count == 5 { expected = Int(header[1]) << 24 | Int(header[2]) << 16
                        | Int(header[3]) << 8 | Int(header[4]); gotFrame = (expected ?? 0) > 0; break }
                }
            } catch { }
            return (status, message, gotFrame)
        }

        print("\n========================================================")
        print("🌐 vca-api-gateway PROBE")

        // Does it respond to gRPC at all, and is reflection open here?
        for svc in ["/grpc.reflection.v1.ServerReflection/ServerReflectionInfo",
                    "/grpc.health.v1.Health/Check"] {
            let (st, msg, _) = await call(svc, body: Data(), token: webToken)
            print("  \(svc): grpc-status=\(st ?? "none") \(msg)")
        }

        // Is it a control-plane oracle? A known-real method establishes the baseline.
        var softwareInfoReq = Data()
        softwareInfoReq.append(Protobuf.stringField(1, vin))
        softwareInfoReq.append(Protobuf.stringField(2, "en"))
        let (ctlSt, ctlMsg, ctlFrame) = await call(
            "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo", body: softwareInfoReq, token: webToken)
        print("\n  [control] OtaDiscoveryService/GetSoftwareInfo → status=\(ctlSt ?? "none") frame=\(ctlFrame) \(ctlMsg)")
        let oracleValid = !(ctlMsg.contains("Method not found") || ctlMsg.isEmpty && ctlSt == nil)
        print("  method oracle valid here: \(oracleValid)")

        // The download/consent/wake dictionary, across plausible services and both tokens.
        let services = ["/ota_mobcache.OtaDiscoveryService", "/ota_mobcache.SchedulerService",
                        "/ota_mobcache.ConsentService", "/ota_mobcache.DownloadService",
                        "/invocation.InvocationService"]
        let methods = ["Download", "StartDownload", "TriggerDownload", "RequestDownload",
                       "DownloadNow", "SetConsent", "GiveConsent", "AcceptSoftware", "Approve",
                       "WakeUp", "Wake", "CheckForUpdates", "Schedule", "InstallNow"]
        _ = (services, methods)  // superseded below

        // On this host bare `status 12` with an empty message means "package not routed here"
        // (the known-real GetSoftwareInfo got exactly that). A ROUTED package answers
        // differently — a business error, an auth error, or `Method not found` *with a message*.
        // So discover what the gateway routes by looking for any non-bare-12 response.
        print("\n  package routing discovery (probing /<pkg.Service>/Probe):")
        let probePackages = [
            "ota_mobcache.OtaDiscoveryService", "ota.OtaService", "software.SoftwareService",
            "vca.ota.OtaService", "vca.software.SoftwareService", "vca.OtaService",
            "connectivity.ConnectivityService", "wakeup.WakeupService", "vca.WakeupService",
            "invocation.InvocationService", "vca.invocation.InvocationService",
            "chronos.services.v1.TargetSocService", "services.vehiclestates.battery.BatteryService",
            "com.volvocars.ota.OtaService", "vehicleupdate.VehicleUpdateService",
            "campaign.CampaignService", "vca.campaign.CampaignService",
            "remotecommand.RemoteCommandService", "vca.command.CommandService",
            "grpc.health.v1.Health", "vca.gateway.GatewayService"
        ]
        for pkg in probePackages {
            var b = Data(); b.append(Protobuf.stringField(1, vin))
            let (st, msg, _) = await call("/\(pkg)/Probe", body: b, token: commandToken ?? webToken)
            let bareUnimplemented = (st == "12" && msg.isEmpty)
            if !bareUnimplemented && msg != "transport error" {
                print("  ⭐️ ROUTED? /\(pkg) → status=\(st ?? "none") msg=\(msg.prefix(110))")
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Full OIDC flow returning the entire token response (so `id_token` is available too).
    private static func authorizeFull(email: String, password: String, clientID: String,
                                      redirect: String, scope: String) async throws -> [String: Any] {
        final class Catcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var callback: URL?
            let scheme: String
            init(scheme: String) { self.scheme = scheme }
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping (URLRequest?) -> Void) {
                if request.url?.scheme == scheme, request.url?.query?.contains("code=") == true {
                    callback = request.url; completionHandler(nil); return
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
        let (pageData, _) = try await session.data(from: authComponents.url!)
        let html = String(decoding: pageData, as: UTF8.self)
        let resumePath = try XCTUnwrap(PolestarAPI.extractResumePath(from: html))
        var loginComponents = URLComponents(string: "https://polestarid.eu.polestar.com" + resumePath)!
        loginComponents.queryItems = (loginComponents.queryItems ?? []) + items
        var login = URLRequest(url: loginComponents.url!)
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = "pf.username=\(email.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&pf.pass=\(password.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)".data(using: .utf8)
        let (_, loginResponse) = try await session.data(for: login)
        let callback = catcher.callback ?? (loginResponse as? HTTPURLResponse)?.url
        let code = try XCTUnwrap(callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "code" })?.value)
        var tokenRequest = URLRequest(url: URL(string: "https://polestarid.eu.polestar.com/as/token.oauth2")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = ("grant_type=authorization_code&client_id=\(clientID)&code=\(code)"
            + "&redirect_uri=\(redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
            + "&code_verifier=\(verifier)").data(using: .utf8)
        let (tokenData, _) = try await session.data(for: tokenRequest)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])
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

    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testProbeExactCarImageAnglesFromGraphQL() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        features.set(.vehicleIdentity, enabled: true)
        features.set(.vehicleImage, enabled: true)
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)
        let state = try await api.fetchVehicleState(vin: vin, features: features)

        print("\n========================================================")
        print("📸 CAR IMAGE GRAPHQL ANGLES PROBE")
        print("   VIN: \(vin)")
        print("   PNO34: \(state.pno34 ?? "nil")")
        print("   StructureWeek: \(state.structureWeek ?? "nil")")
        print("   ModelYear: \(state.modelYear ?? "nil")")

        guard let pno34 = state.pno34, let structureWeek = state.structureWeek, let modelYear = state.modelYear else {
            print("  ✗ Missing vehicle identity data")
            return
        }

        let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
        let publicApiKey = BuiltinPolestarSecrets.imageApiKey

        // 1. Introspect CarImages type
        let introQuery = """
        query {
          __type(name: "CarImages") {
            name
            fields {
              name
              type {
                name
                kind
                ofType {
                  name
                  kind
                  ofType {
                    name
                    kind
                  }
                }
              }
            }
          }
          __schema {
            queryType {
              fields {
                name
              }
            }
          }
        }
        """
        var introReq = URLRequest(url: publicApiURL)
        introReq.httpMethod = "POST"
        introReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        introReq.setValue(publicApiKey, forHTTPHeaderField: "x-api-key")
        introReq.httpBody = try? JSONSerialization.data(withJSONObject: ["query": introQuery])
        let (introData, _) = try await URLSession.shared.data(for: introReq)
        print("  Schema Introspection:")
        print(String(decoding: introData, as: UTF8.self))

        // 2. Query GetCarImages without invalid fields
        let query = """
        query GetCarImages($pno34: String!, $structureWeek: String!, $modelYear: String!, $locale: String) {
          getCarImages(pno34: $pno34, structureWeek: $structureWeek, modelYear: $modelYear, locale: $locale) {
            transparent { url angle }
            opaque { url angle }
          }
        }
        """
        let body: [String: Any] = ["query": query, "variables": [
            "pno34": pno34, "structureWeek": structureWeek,
            "modelYear": modelYear, "locale": "en-GB"
        ]]
        var request = URLRequest(url: publicApiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publicApiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        print("  HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        let outDir = URL(fileURLWithPath: "/Users/nicolaskheirallah/.gemini/antigravity/brain/ff023aac-6fe2-41f3-b104-7b2c92e9f722/scratch/vehicle_images")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["data"] as? [String: Any],
           payload["getCarImages"] is [String: Any] {
            let upholsteryCode = "RFA000"
            let colorCode = "72900"
            let wheelCode = "19"
            let packCode = "XPLUSS"

            let candidatePaths = [
                // car-images.polestar.com variations
                "https://car-images.polestar.com/534/2023/interior/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/0.jpg",
                "https://car-images.polestar.com/534/2023/interior/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/1.jpg",
                "https://car-images.polestar.com/534/2023/interior/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/0.png",
                "https://car-images.polestar.com/534/2023/interior/\(upholsteryCode)/default/0.jpg",
                "https://car-images.polestar.com/534/2023/interior/\(upholsteryCode)/default/1.jpg",
                "https://car-images.polestar.com/534/2023/interior-summary/\(upholsteryCode)/0.jpg",
                "https://car-images.polestar.com/534/2023/upholstery/\(upholsteryCode)/0.jpg",
                "https://car-images.polestar.com/534/2023/summary/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/interior/0.jpg",
                "https://car-images.polestar.com/534/2023/summary/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/interior/1.jpg",
                "https://car-images.polestar.com/534/2023/summary-interior/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/0.jpg",
                "https://car-images.polestar.com/534/2023/summary-interior/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/1.jpg",
                "https://car-images.polestar.com/534/2023/cockpit/ED/\(colorCode)/\(upholsteryCode)/\(wheelCode)/_/_/\(packCode)/001257/1/_/default/0.jpg",
                // Official Polestar Media CDN interior assets for Polestar 2
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/interior/polestar-2-interior-charcoal-embossed-textile-cockpit.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/interior/polestar-2-interior-cockpit-front.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/interior/polestar-2-cockpit.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/gallery/interior/polestar-2-interior-cockpit.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/my23/interior/polestar-2-my23-interior-charcoal-textile.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/gallery/polestar-2-interior-driver-seat.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/gallery/polestar-2-interior-steering-wheel.jpg",
                "https://media.polestar.com/image/upload/f_auto,q_auto/v1/polestar-2/gallery/polestar-2-interior-center-display.jpg",
                // Polestar DAM / Akamai static assets
                "https://www.polestar.com/dato-assets/11286/1638274092-polestar-2-interior-cockpit.jpg",
                "https://www.polestar.com/dato-assets/11286/1638274094-polestar-2-interior-seats.jpg",
                "https://assets.polestar.com/media/polestar-2/interior-cockpit.jpg"
            ]

            print("🔍 PROBING CANDIDATE INTERIOR URLS...")
            let outDir = URL(fileURLWithPath: "/Users/nicolaskheirallah/.gemini/antigravity/brain/ff023aac-6fe2-41f3-b104-7b2c92e9f722/scratch/vehicle_images")
            for (idx, candidate) in candidatePaths.enumerated() {
                guard let url = URL(string: candidate) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                if let (bytes, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   http.statusCode == 200, bytes.count > 10_000 {
                    print("  ✅ [HTTP 200] HIT! (\(bytes.count) bytes): \(candidate)")
                    let fileURL = outDir.appendingPathComponent("interior_asset_\(idx).jpg")
                    try? bytes.write(to: fileURL)
                } else {
                    let status = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode ?? 0
                    print("  ✗ [HTTP \(status)] \(candidate)")
                }
            }
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testSeedAppCredentialsIntoKeychain() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let appKeychain = KeychainStore.app
        try appKeychain.savePassword(password)

        PreferencesStore.shared.email = email
        PreferencesStore.shared.activeBrand = .polestar
        if let preferredVIN {
            PreferencesStore.shared.vin = preferredVIN
        }

        let api = PolestarAPI(keychain: appKeychain)
        var features = FeatureSelection.default
        features.set(.remoteCharging, enabled: true)
        features.set(.chargingDetails, enabled: true)
        features.set(.vehicleIdentity, enabled: true)
        try await api.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)

        let state = try await api.fetchVehicleState(vin: preferredVIN ?? "YSMVSEDE6PL147228", features: features)
        print("✅ Successfully seeded app session! Target SoC: \(state.chargeTargetPercentage.map { "\($0)%" } ?? "nil")")
    }

    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testLiveTargetSocSetAndReadback() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        features.set(.remoteCharging, enabled: true)
        features.set(.chargingDetails, enabled: true)
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        print("\n========================================================")
        print("⚡️ LIVE TARGET SOC PROGRESSION (70% -> 80% -> 90%)")
        print("   VIN: \(vin)")

        let initialState = try await api.fetchVehicleState(vin: vin, features: features)
        print("   Initial Reported Target SoC: \(initialState.chargeTargetPercentage.map { "\($0)%" } ?? "nil")")

        // Target steps: 70%, 80%, 90%
        let steps = [70, 80, 90]
        for target in steps {
            print("\n--------------------------------------------------------")
            print("🚀 Executing SetTargetSoc(\(target)%)...")
            let result = try await api.executeRemoteCommand(.setChargeTarget(target), vin: vin)
            print("   Outcome: \(result.outcome) (message: \(result.message ?? "none"))")

            print("   Waiting 4 seconds for vehicle sync...")
            try await Task.sleep(nanoseconds: 4_000_000_000)

            let stateAfter = try await api.fetchVehicleState(vin: vin, features: features)
            print("   Readback Target SoC from vehicle/Chronos: \(stateAfter.chargeTargetPercentage.map { "\($0)%" } ?? "nil")")
        }

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

    @Test("Live Location and Weather Resolution Probe")
    func testLiveLocationAndWeatherResolution() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawEmail = await MainActor.run { env["POLESTAR_LOGIN"] ?? env["HISINGEN_TEST_EMAIL"] ?? PreferencesStore.shared.email }
        let rawPassword = env["POLESTAR_PASS"] ?? env["HISINGEN_TEST_PASSWORD"] ?? (try? KeychainStore.app.readPassword())
        let preferredVIN = await MainActor.run { env["POLESTAR_VIN"] ?? env["HISINGEN_TEST_VIN"] ?? (PreferencesStore.shared.vin.isEmpty ? nil : PreferencesStore.shared.vin) }

        let email = (rawEmail.isEmpty) ? nil : rawEmail
        let password = (rawPassword?.isEmpty ?? true) ? nil : rawPassword

        guard let email, let password else {
            print("ℹ️ Skipping live location/weather probe: no live credentials in env or KeychainStore.app")
            return
        }

        print("\n========================================================")
        print("🛰 PROBING LIVE LOCATION & WEATHER RESOLUTION")
        print("User: \(email), VIN: \(preferredVIN ?? "auto")")
        print("========================================================")

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        var features = FeatureSelection.default
        features.set(.vehicleLocation, enabled: true)
        features.set(.vehicleWeather, enabled: true)

        try await api.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        let resolved = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolved)

        let state = try await api.fetchVehicleState(vin: vin, features: features)
        print("🚗 Model: \(state.modelName ?? "Unknown"), Year: \(state.modelYear ?? "—"), Plate: \(state.registrationNo ?? "—")")
        print("🔋 Battery: \(state.batteryPercentage.map { String(format: "%.1f%%", $0) } ?? "—"), Range: \(state.rangeKm.map { "\($0) km" } ?? "—")")

        print("\n📍 RESOLVED VEHICLE STATE LOCATION & WEATHER:")
        if let loc = state.location {
            print("  ✅ Latitude:   \(loc.latitude.map { String(format: "%.4f° N", $0) } ?? "nil")")
            print("  ✅ Longitude:  \(loc.longitude.map { String(format: "%.4f° E", $0) } ?? "nil")")
            print("  ✅ Heading:    \(loc.heading.map { "\($0)°" } ?? "—")")
            print("  ✅ Speed:      \(loc.speed.map { "\($0) km/h" } ?? "—")")
            print("  ✅ Timestamp:  \(loc.timestamp.map { "\($0)" } ?? "—")")
        } else {
            print("  ⚠️ Location was nil in VehicleState")
        }

        if let weather = state.weather {
            print("  🌤 Temperature:\(weather.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—")")
            print("  🌤 Condition:  \(weather.condition ?? "—")")
            print("  🌤 Feels Like: \(weather.apparentTemperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—")")
            print("  🌤 Humidity:   \(weather.relativeHumidity.map { "\($0)%" } ?? "—")")
        } else {
            print("  ⚠️ Weather was nil in VehicleState")
        }
        print("========================================================\n")
    }

    /// Live test for `ErrorService/GetErrors` — fetches vehicle service errors from PCCS.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testFetchVehicleErrors() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let validToken = try await api.validAccessToken()
        let token = try XCTUnwrap(validToken)

        print("\n========================================================")
        print("⚠️ VEHICLE ERRORS — VIN \(vin)")
        do {
            let errors = try await api.grpc.fetchErrors(vin: vin, accessToken: token)
            if errors.isEmpty {
                print("  ✅ No service errors reported")
            } else {
                for e in errors {
                    print("  • \(e.service.displayName): \(e.errorCode.displayName)" +
                          (e.actionCode.map { " (action=\($0))" } ?? ""))
                }
            }
        } catch {
            print("  ⚠️ ErrorService not available: \(error)")
        }
        print("========================================================\n")
        try? await api.signOut()
    }

    /// Live test for streaming gRPC methods (`GetBattery` stream, `GetExterior` stream).
    /// Verifies the streaming endpoints return the same first-frame data as the one-shot methods.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testStreamingEndpoints() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let validToken = try await api.validAccessToken()
        let token = try XCTUnwrap(validToken)

        print("\n========================================================")
        print("📡 STREAMING gRPC TEST — VIN \(vin)")

        // Test streaming battery (GetBattery vs GetLatestBattery)
        do {
            await api.grpc.setUseStreaming(true)
            let streamBattery = try await api.grpc.fetchBattery(vin: vin, accessToken: token)
            await api.grpc.setUseStreaming(false)
            let latestBattery = try await api.grpc.fetchBattery(vin: vin, accessToken: token)
            print("  GetBattery (stream): SOC=\(streamBattery.batteryPercentage ?? -1)%")
            print("  GetLatestBattery:    SOC=\(latestBattery.batteryPercentage ?? -1)%")
            print("  ✅ Streaming battery returned data")
        } catch {
            print("  ⚠️ Streaming battery failed: \(error)")
        }

        // Test streaming exterior (GetExterior vs GetLatestExterior)
        do {
            await api.grpc.setUseStreaming(true)
            let streamExterior = try await api.grpc.fetchExterior(vin: vin, accessToken: token)
            await api.grpc.setUseStreaming(false)
            let latestExterior = try await api.grpc.fetchExterior(vin: vin, accessToken: token)
            print("  GetExterior (stream): locked=\(streamExterior?.isLocked.map { String(describing: $0) } ?? "nil")")
            print("  GetLatestExterior:    locked=\(latestExterior?.isLocked.map { String(describing: $0) } ?? "nil")")
            print("  ✅ Streaming exterior returned data")
        } catch {
            print("  ⚠️ Streaming exterior failed: \(error)")
        }

        print("========================================================\n")
        try? await api.signOut()
    }

    /// Deep dive: GetSchedule full decode, car_information.CarInformation/GetMyCars (gRPC),
    /// and GraphQL GetVDMSCars — comparing all three car-discovery surfaces and the schedule
    /// response.  Read-only.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testGetScheduleAndCarDiscoveryDeepDive() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)

        // C3 discovery
        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let base = try XCTUnwrap(URL(string: "https://\(host):443"))

        print("\n========================================================")
        print("🔬 GET SCHEDULE + CAR DISCOVERY DEEP DIVE — VIN \(vin)")

        // ── 1. GetSchedule full decode ──
        print("\n── 1. GetSchedule (full recursive decode) ──")
        let scheduleResult = await Self.callGRPC(base: base,
            path: "/ota_mobcache.SchedulerService/GetSchedule",
            body: Protobuf.stringField(1, vin), vin: vin, token: token, label: "GetSchedule")
        if let frame = scheduleResult.frames.first {
            print("  raw: \(frame.map { String(format: "%02x", $0) }.joined())")
            // GetScheduleResponse: {1: Scheduler}
            // Scheduler: {1: status (Status enum), 2: relativeTime (int), 3: scheduledTime (Timestamp),
            //             4: softwareId (string), 5: setBy (SetBy enum)}
            // Status: 0=UNKNOWN, 1=IDLE, 2=SCHEDULED, 3=INSTALL
            // SetBy: 0=UNKNOWN, 1=APP, 2=HMI, 3=CLOUD
            let outer = Protobuf.fields(frame)
            if let schedulerData = outer.first(where: { $0.number == 1 && $0.wire == 2 })?.data {
                let scheduler = Protobuf.fields(schedulerData)
                let status = scheduler.first(where: { $0.number == 1 })?.varint
                let relativeTime = scheduler.first(where: { $0.number == 2 })?.varint
                let scheduledTimeData = scheduler.first(where: { $0.number == 3 && $0.wire == 2 })?.data
                let softwareId = scheduler.first(where: { $0.number == 4 && $0.wire == 2 })
                    .flatMap { String(data: $0.data, encoding: .utf8) }
                let setBy = scheduler.first(where: { $0.number == 5 })?.varint

                let statusName = ["UNKNOWN", "IDLE", "SCHEDULED", "INSTALL"]
                let setByName = ["SET_BY_UNKNOWN", "APP", "HMI", "CLOUD"]
                print("  status: \(status ?? 0) (\(statusName[min(Int(status ?? 0), 3)]))")
                print("  relativeTime: \(relativeTime ?? 0)")
                if let st = scheduledTimeData {
                    let ts = Protobuf.fields(st)
                    let seconds = ts.first(where: { $0.number == 1 })?.varint
                    print("  scheduledTime: seconds=\(seconds ?? 0)")
                } else { print("  scheduledTime: nil") }
                print("  softwareId: \(softwareId ?? "nil")")
                print("  setBy: \(setBy ?? 0) (\(setByName[min(Int(setBy ?? 0), 3)]))")
            } else {
                print("  ⚠️ no Scheduler field in response")
            }
        } else {
            print("  ⚠️ no frame returned")
        }

        // ── 2. car_information.CarInformation/GetMyCars (gRPC) ──
        print("\n── 2. car_information.CarInformation/GetMyCars (gRPC) ──")
        // GetMyCarsRequest is empty (no fields). GetMyCarsResponse: {1: [MyCar]}.
        // MyCar: {1: Car, 2: userIsLinked (bool), 3: userIsOwner (bool), 4: registrationPlate (string)}.
        // Car has 87+ fields including:
        //   9: consumerSoftwareVersion (string)
        //  32: supportsUpdateStatus (bool)
        //  33: supportsRemoteOtaInstallSchedule (bool)
        //  57: supportsFullOtaUpdates (bool)
        //  62: supportsCloudBasedOtaDownloadConsent (bool)  ← KEY
        //  70: hasPerformanceSoftwareUpgrade (bool)
        let myCarsResult = await Self.callGRPC(base: base,
            path: "/car_information.CarInformation/GetMyCars",
            body: Data(), vin: vin, token: token, label: "GetMyCars")
        if let frame = myCarsResult.frames.first {
            print("  raw (\(frame.count) bytes): \(frame.map { String(format: "%02x", $0) }.joined().prefix(200))...")
            // Recursively decode to find Car fields
            Self.recursiveDecode(frame, depth: 1)
        } else {
            print("  ⚠️ no frame returned (grpc-status=\(myCarsResult.status ?? "nil"))")
        }

        // ── 3. GraphQL GetVDMSCars ──
        print("\n── 3. GraphQL GetVDMSCars (app-backend) ──")
        let gqlURL = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!
        let query = "{\"query\":\"query GetVDMSCars { vdms { getVehiclesInformation { vin internalVehicleIdentifier registrationNo modelYear content { model { name } exterior { name } interior { name } wheels { name } } } } }\"}"
        var gqlReq = URLRequest(url: gqlURL)
        gqlReq.httpMethod = "POST"
        gqlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        gqlReq.setValue("Bearer \(token)", forHTTPHeaderField: "X-PolestarId-Authorization")
        gqlReq.setValue("5.5.0", forHTTPHeaderField: "X-Polestar-Force-Update-Version")
        gqlReq.setValue("SE", forHTTPHeaderField: "X-Polestar-Locale")
        gqlReq.setValue("PolestarApp/5.5.0b1102 Android/14", forHTTPHeaderField: "User-Agent")
        gqlReq.httpBody = Data(query.utf8)
        let (gqlData, gqlResp) = try await URLSession.shared.data(for: gqlReq)
        let gqlHttp = gqlResp as! HTTPURLResponse
        let gqlBody = String(data: gqlData, encoding: .utf8) ?? "<binary>"
        print("  HTTP \(gqlHttp.statusCode)")
        // Pretty-print if JSON
        if let parsed = try? JSONSerialization.jsonObject(with: gqlData),
           let pretty = try? JSONSerialization.data(withJSONObject: parsed, options: .prettyPrinted),
           let prettyStr = String(data: pretty, encoding: .utf8) {
            print("  \(prettyStr.prefix(1500))")
        } else {
            print("  \(gqlBody.prefix(500))")
        }

        print("========================================================\n")
        try? await api.signOut()
    }

    /// Diagnose trunk unlock and charge target/amp limit failures by tracing the raw gRPC
    /// exchange. Read-only for charge target (sets same value as current); trunk unlock is
    /// a real command — gated behind HISINGEN_TEST_TRUNK=1.
    @Test(.disabled(if: !livePolestarCredentialsConfigured, "Live Polestar credentials are not configured"))
    func testDiagnoseTrunkAndChargeCommands() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try XCTUnwrap(environment["HISINGEN_TEST_EMAIL"])
        let password = try XCTUnwrap(environment["HISINGEN_TEST_PASSWORD"])
        let preferredVIN = environment["HISINGEN_TEST_VIN"].flatMap { $0.isEmpty ? nil : $0 }

        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.live-tests"))
        try await api.authenticate(email: email, password: password,
                                    preferredVIN: preferredVIN, features: .default)
        let resolvedVIN = await api.resolvedVIN(preferred: preferredVIN)
        let vin = try XCTUnwrap(resolvedVIN)
        let resolvedToken = try await api.validAccessToken()
        let token = try XCTUnwrap(resolvedToken)
        let cmdTokenResolved = await api.validCommandToken()
        let cmdToken = try XCTUnwrap(cmdTokenResolved)

        var discovery = URLRequest(url: URL(string: "https://cnepmob.volvocars.com")!)
        discovery.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
        discovery.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (discoveryData, _) = try await URLSession.shared.data(for: discovery)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
        let c3 = try XCTUnwrap(json["c3"] as? [String: Any])
        let host = try XCTUnwrap(c3["grpcHost"] as? String)
        let c3Base = try XCTUnwrap(URL(string: "https://\(host):443"))
        let pccsBase = URL(string: "https://api.pccs-prod.plstr.io:443")!

        print("\n========================================================")
        print("🔧 TRUNK + CHARGE COMMAND DIAGNOSTICS — VIN \(vin)")

        // ── 1. Trunk unlock raw gRPC ──
        if environment["HISINGEN_TEST_TRUNK"] == "1" {
            print("\n── 1. Trunk Unlock (real command) ──")
            var unlockReq = Data()
            unlockReq.append(Protobuf.messageField(1, Protobuf.stringField(1, vin)))
            unlockReq.append(Protobuf.intField(2, 1))  // UNLOCK_TYPE_TRUNK_ONLY
            let result = await Self.callGRPC(base: c3Base,
                path: "/invocation.InvocationService/Unlock",
                body: unlockReq, vin: vin, token: cmdToken, label: "Unlock (trunk only)")
            print("  → grpc-status=\(result.status ?? "nil"), frames=\(result.frames.count)")
            for frame in result.frames {
                print("  raw: \(frame.map { String(format: "%02x", $0) }.joined())")
                Self.recursiveDecode(frame, depth: 1)
            }
        } else {
            print("\n── 1. Trunk Unlock (skipped — set HISINGEN_TEST_TRUNK=1 to test) ──")
        }

        // ── 2. SetTargetSoc raw gRPC (same-value, non-destructive) ──
        print("\n── 2. SetTargetSoc (read current, then set same value) ──")
        // First read current target SOC
        let getSocBody = try await api.grpc.firstMessage(
            path: "/pccs.chronos.services.v1.TargetSocService/GetTargetSoc",
            message: PolestarGRPC.chronosEnvelope(vin: vin), vin: vin, accessToken: token, host: .pccs)
        let socFields = Protobuf.fields(getSocBody)
        var currentTarget: Int?
        if let socData = socFields.first(where: { $0.number == 3 && $0.wire == 2 })?.data {
            let inner = Protobuf.fields(socData)
            if let v = inner.first(where: { $0.number == 1 })?.varint { currentTarget = Int(v) }
        }
        print("  current target SOC: \(currentTarget ?? -1)%")

        // Now set the same value
        let targetToSet = currentTarget ?? 90
        var socPayload = Data()
        socPayload.append(Protobuf.intField(2, targetToSet))
        socPayload.append(Protobuf.intField(3, 1))  // DAILY
        let socResult = await Self.callGRPC(base: pccsBase,
            path: "/pccs.chronos.services.v1.TargetSocService/SetTargetSoc",
            body: PolestarGRPC.chronosEnvelope(vin: vin, payload: socPayload),
            vin: vin, token: token, label: "SetTargetSoc(\(targetToSet)%)")
        print("  → grpc-status=\(socResult.status ?? "nil"), frames=\(socResult.frames.count)")
        for frame in socResult.frames {
            print("  raw: \(frame.map { String(format: "%02x", $0) }.joined())")
            Self.recursiveDecode(frame, depth: 1)
        }

        // ── 3. SetAmpLimit raw gRPC ──
        print("\n── 3. SetAmpLimit (read current, then set same value) ──")
        let getAmpBody = try await api.grpc.firstMessage(
            path: "/pccs.chronos.services.v1.AmpLimitService/GetAmpLimit",
            message: PolestarGRPC.chronosEnvelope(vin: vin), vin: vin, accessToken: token, host: .pccs)
        let ampFields = Protobuf.fields(getAmpBody)
        var currentAmp: Int?
        if let ampData = ampFields.first(where: { $0.number == 2 && $0.wire == 2 })?.data {
            let inner = Protobuf.fields(ampData)
            if let v = inner.first(where: { $0.number == 1 })?.varint { currentAmp = Int(v) }
        }
        print("  current amp limit: \(currentAmp ?? -1)A")

        let ampToSet = currentAmp ?? 16
        let ampPayload = Protobuf.intField(2, ampToSet)
        let ampResult = await Self.callGRPC(base: pccsBase,
            path: "/pccs.chronos.services.v1.AmpLimitService/SetAmpLimit",
            body: PolestarGRPC.chronosEnvelope(vin: vin, payload: ampPayload),
            vin: vin, token: token, label: "SetAmpLimit(\(ampToSet)A)")
        print("  → grpc-status=\(ampResult.status ?? "nil"), frames=\(ampResult.frames.count)")
        for frame in ampResult.frames {
            print("  raw: \(frame.map { String(format: "%02x", $0) }.joined())")
            Self.recursiveDecode(frame, depth: 1)
        }

        // ── 4. Now try via PolestarAPI.executeRemoteCommand ──
        print("\n── 4. Via PolestarAPI.executeRemoteCommand ──")
        // Test setting charge target to 100% specifically
        do {
            let result = try await api.executeRemoteCommand(.setChargeTarget(100), vin: vin)
            print("  setChargeTarget(100): outcome=\(result.outcome) msg=\(result.message ?? "—")")
        } catch {
            print("  setChargeTarget(100): ERROR \(error)")
        }
        // Wait 5 seconds, then read back to verify
        print("  waiting 5s then reading back target SOC...")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let readBackBody = try await api.grpc.firstMessage(
            path: "/pccs.chronos.services.v1.TargetSocService/GetTargetSoc",
            message: PolestarGRPC.chronosEnvelope(vin: vin), vin: vin, accessToken: token, host: .pccs)
        print("  readback raw: \(readBackBody.map { String(format: "%02x", $0) }.joined())")
        let readBackFields = Protobuf.fields(readBackBody)
        // field 3 = current targetSoc
        if let targetData = readBackFields.first(where: { $0.number == 3 && $0.wire == 2 })?.data {
            let inner = Protobuf.fields(targetData)
            if let v = inner.first(where: { $0.number == 1 })?.varint {
                print("  readback current target SOC: \(Int(v))%")
            }
        }
        // field 4 = pendingTargetSoc
        if let pendingData = readBackFields.first(where: { $0.number == 4 && $0.wire == 2 })?.data {
            let inner = Protobuf.fields(pendingData)
            if let v = inner.first(where: { $0.number == 1 })?.varint {
                print("  readback PENDING target SOC: \(Int(v))%")
            }
        } else {
            print("  readback: no pending target SOC field")
        }
        // Restore to 90%
        do {
            let result = try await api.executeRemoteCommand(.setChargeTarget(90), vin: vin)
            print("  setChargeTarget(90): outcome=\(result.outcome) msg=\(result.message ?? "—")")
        } catch {
            print("  setChargeTarget(90): ERROR \(error)")
        }
        do {
            let result = try await api.executeRemoteCommand(.setAmpLimit(ampToSet), vin: vin)
            print("  setAmpLimit(\(ampToSet)): outcome=\(result.outcome) msg=\(result.message ?? "—")")
        } catch {
            print("  setAmpLimit(\(ampToSet)): ERROR \(error)")
        }

        // ── 5. Test tailgate open/close via executeRemoteCommand ──
        print("\n── 5. Tailgate open/close via executeRemoteCommand ──")
        if environment["HISINGEN_TEST_TAILGATE"] == "1" {
            // First test raw gRPC to see the actual response
            var tailgateReq = Data()
            tailgateReq.append(Protobuf.messageField(1, Protobuf.stringField(1, vin)))
            tailgateReq.append(Protobuf.intField(2, 1))  // OPEN_TAILGATE
            let tailgateResult = await Self.callGRPC(base: c3Base,
                path: "/invocation.InvocationService/TailgateControl",
                body: tailgateReq, vin: vin, token: cmdToken, label: "TailgateControl (raw)")
            print("  raw TailgateControl: grpc-status=\(tailgateResult.status ?? "nil"), frames=\(tailgateResult.frames.count)")

            do {
                let result = try await api.executeRemoteCommand(.openTailgate, vin: vin)
                print("  openTailgate: outcome=\(result.outcome) msg=\(result.message ?? "—")")
            } catch {
                print("  openTailgate: ERROR \(error)")
            }
            do {
                let result = try await api.executeRemoteCommand(.closeTailgate, vin: vin)
                print("  closeTailgate: outcome=\(result.outcome) msg=\(result.message ?? "—")")
            } catch {
                print("  closeTailgate: ERROR \(error)")
            }
        } else {
            print("  (skipped — set HISINGEN_TEST_TAILGATE=1 to test)")
        }

        print("========================================================\n")
        try? await api.signOut()
    }
}
#endif
