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
    @Test(.disabled(if: !livePolestarCredentialsConfigured || ProcessInfo.processInfo.environment["HISINGEN_RAW_CAPTURE_DIR"] == nil,
                    "Raw response capture requires an explicit local output directory"))
    func testRawReadResponseInventory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["HISINGEN_RAW_CAPTURE_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-raw.\(UUID())")
        let api = PolestarAPI(keychain: keychain)
        let startedAt = Date()
        do {
            try await api.authenticate(email: try #require(environment["HISINGEN_TEST_EMAIL"]),
                                       password: try #require(environment["HISINGEN_TEST_PASSWORD"]),
                                       preferredVIN: environment["HISINGEN_TEST_VIN"], features: .default)
            let vin = try #require(await api.resolvedVIN(preferred: environment["HISINGEN_TEST_VIN"]))
            try await api.captureReadResponses(vin: vin, directory: directory)
            let logs = await APIDiagnosticLogStore.shared.snapshot().filter {
                $0.provider == .polestar && $0.timestamp >= startedAt && $0.responsePayloadJSON != nil
            }
            try JSONEncoder().encode(logs).write(to: directory.appendingPathComponent("redacted-http.json"))
            try await api.signOut()
        } catch {
            try? await api.signOut()
            throw error
        }
    }

    @Test(.disabled(if: !livePolestarCredentialsConfigured,
                    "Live Polestar credentials are not configured"))
    func testAuthenticationDiscoveryFetchRestoreAndSignOut() async throws {
        let startedAt = Date()
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
            XCTAssertEqual(state.identity.vin, vin)
            XCTAssertTrue(state.energy.batteryPercentage != nil || state.energy.rangeKm != nil)
            let connectivitySupport = state.probedCapabilities?.support(for: .connectivity)
            if connectivitySupport == .unavailable {
                XCTAssertFalse(state.freshness.unavailableFeatures.contains(.connectivityDiagnostics))
            } else if state.connectivity != nil {
                XCTAssertEqual(connectivitySupport, .supported)
            }
            if let installed = state.otaCapabilities?.installedSoftwareVersion, !installed.isEmpty {
                #expect(state.softwareInfo?.installedVersion == installed)
            }
            if let capabilities = state.otaCapabilities {
                // Older `GetMyCars` schemas advertise charge-amperage / target-level support
                // as a bare boolean with no numeric bounds — the limit fields are then 0
                // ("unknown"), and `VehicleChargeBounds` supplies the fallback range. Only
                // assert the advertised bounds are self-consistent when the vehicle sends them.
                if capabilities.chargeAmperageMinLimit > 0 {
                    XCTAssertTrue(capabilities.supportsGlobalChargeAmperageLimit)
                    XCTAssertTrue(capabilities.chargeAmperageMaxLimit >= capabilities.chargeAmperageMinLimit)
                }
                if capabilities.chargeAmperageMaxLimit > 0 {
                    XCTAssertTrue(capabilities.chargeAmperageMaxLimit <= 64)
                }
                if capabilities.targetChargeLevelPercentageMinLimit > 0 {
                    XCTAssertTrue(capabilities.supportsTargetChargeLevel)
                    XCTAssertTrue(capabilities.targetChargeLevelPercentageMinLimit <= 100)
                }
                // Whatever the vehicle advertised (or didn't), the resolved control bounds
                // must always be usable.
                let bounds = VehicleChargeBounds(capabilities: capabilities)
                XCTAssertTrue(bounds.targetRange.lowerBound >= 1 && bounds.targetRange.upperBound == 100)
                XCTAssertTrue(bounds.amperageRange.lowerBound >= 1)
                XCTAssertTrue(bounds.amperageRange.upperBound >= bounds.amperageRange.lowerBound)
            }

            await api.resetSession()
            let token = try XCTUnwrap(try keychain.readSessionToken())
            try await api.restoreSession(token: token, preferredVIN: vin, features: features)
            let restored = try await api.fetchVehicleState(vin: vin, features: features)
            XCTAssertEqual(restored.identity.vin, vin)
            let tokenRequests = await APIDiagnosticLogStore.shared.snapshot().filter {
                $0.provider == .polestar && $0.operation == "Polestar token request"
                    && $0.timestamp >= startedAt
            }
            XCTAssertEqual(
                tokenRequests.count, 2,
                "Authentication and one explicit restore should be the only token grants"
            )
            try await api.signOut()
        } catch {
            try? await api.signOut()
            throw error
        }
    }
}
private extension PolestarAPI {
    func captureReadResponses(vin: String, directory: URL) async throws {
        let token = try #require(accessToken)
        let vehicle = Protobuf.stringField(1, UUID().uuidString) + Protobuf.stringField(2, vin)
        let reads: [(String, String, Data)] = [
            ("mycars", "/car_information.CarInformation/GetMyCars", vehicle),
            ("battery", "/services.vehiclestates.battery.BatteryService/GetLatestBattery", vehicle),
            ("health", "/services.vehiclestates.health.HealthService/GetHealth", Protobuf.stringField(2, vin)),
            ("odometer", "/services.vehiclestates.odometer.OdometerService/GetOdometer", Protobuf.stringField(2, vin)),
            ("exterior", "/services.vehiclestates.exterior.ExteriorService/GetLatestExterior", vehicle),
            ("software", "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo", Protobuf.stringField(1, vin) + Protobuf.stringField(2, "en"))
        ]
        for (name, path, request) in reads {
            do {
                let body = try await grpc.firstMessage(path: path, message: request, vin: vin, accessToken: token)
                let file = directory.appendingPathComponent(name + ".protobuf")
                try body.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                if Self.isGlobalFailure(error) { throw error }
                let message = DiagnosticRedaction.redact(String(describing: error))
                try Data(message.utf8).write(to: directory.appendingPathComponent(name + ".error.txt"))
            }
        }
    }
}

#endif
