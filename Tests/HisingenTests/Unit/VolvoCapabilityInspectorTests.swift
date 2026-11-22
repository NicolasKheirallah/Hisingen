import Foundation
import Testing
@testable import Hisingen

/// S19: the capability inspector must show what the Volvo authorization actually granted, and
/// must carry the provider's own `status`/`unavailableReason` for a field it could not answer
/// instead of collapsing it into a generic unavailable. The payloads below are shaped like live
/// Connected Vehicle API responses; the values and tokens are fake.
@Suite("Volvo capability inspector", .serialized)
struct VolvoCapabilityInspectorTests {
    private let vin = "YV1INSPECTOR000001"

    // MARK: - Scope evidence

    @Test("A narrowed grant still names the scopes Volvo refused")
    func grantsDistinguishRefusedDomains() throws {
        let requested = VolvoAPI.readScopes + VolvoAPI.restrictedScopes
        let granted = VolvoScopeCatalog.parseGrantedScopes(
            VolvoAPI.readScopes.joined(separator: " "))
        let report = VolvoScopeCatalog.report(
            requestedScopes: requested,
            grantedScopes: granted,
            tier: .full,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            degradedReadings: [])

        #expect(report.hasScopeEvidence)
        #expect(report.grantedScopes == VolvoAPI.readScopes.sorted())
        #expect(report.requestedScopes.contains("conve:lock"))
        #expect(report.requestedScopes.contains("location:read"))

        func state(_ domain: ProviderDomain) -> ProviderScopeGrantState? {
            report.grants.first { $0.domain == domain }?.state
        }
        // Read scopes were requested and granted.
        #expect(state(.telemetry) == .granted)
        #expect(state(.energy) == .granted)
        #expect(state(.commands) == .granted)
        #expect(state(.climate) == .granted)
        // Restricted scopes were requested and refused, which is the fact a single
        // "restricted scopes off" boolean could not express.
        #expect(state(.locks) == .notGranted)
        #expect(state(.engine) == .notGranted)
        #expect(state(.honkFlash) == .notGranted)
        #expect(state(.location) == .notGranted)
    }

    @Test("A core grant does not claim the restricted scopes were refused")
    func coreGrantLabelsUnrequestedDomains() throws {
        let granted = VolvoScopeCatalog.parseGrantedScopes(
            VolvoAPI.coreReadScopes.joined(separator: " "))
        let report = VolvoScopeCatalog.report(
            requestedScopes: VolvoAPI.coreReadScopes,
            grantedScopes: granted,
            tier: .core,
            recordedAt: Date(),
            degradedReadings: [])

        func state(_ domain: ProviderDomain) -> ProviderScopeGrantState? {
            report.grants.first { $0.domain == domain }?.state
        }
        #expect(state(.telemetry) == .granted)
        #expect(state(.locks) == .notRequested)
        #expect(state(.location) == .notRequested)
        #expect(state(.commands) == .notRequested)
    }

    @Test("A token response without a scope member leaves the grant unknown, not denied")
    func missingScopeIsUnknownNotDenied() throws {
        #expect(VolvoScopeCatalog.parseGrantedScopes(nil) == nil)
        #expect(VolvoScopeCatalog.parseGrantedScopes("  ") == nil)
        let report = VolvoScopeCatalog.report(
            requestedScopes: VolvoAPI.readScopes + VolvoAPI.restrictedScopes,
            grantedScopes: nil,
            tier: .standard,
            recordedAt: nil,
            degradedReadings: [])
        #expect(report.hasScopeEvidence == false)
        #expect(report.grants.allSatisfy { $0.state == .unknown || $0.state == .notRequested })
        #expect(report.grants.contains { $0.domain == .telemetry && $0.state == .unknown })
    }

    @Test("A partial grant within one domain says partly granted")
    func partialGrantIsNamed() throws {
        // `conve:lock` granted, `conve:unlock` not: the domain can be partly used, and saying
        // only "granted" or "not granted" would both be wrong.
        let granted = VolvoScopeCatalog.parseGrantedScopes("openid conve:lock")
        let report = VolvoScopeCatalog.report(
            requestedScopes: ["openid", "conve:lock", "conve:unlock"],
            grantedScopes: granted,
            tier: .full,
            recordedAt: Date(),
            degradedReadings: [])
        let locks = try #require(report.grants.first { $0.domain == .locks })
        #expect(locks.state == .partial)
    }

    @Test("The token response decodes the granted scope list")
    func tokenResponseCarriesScope() throws {
        let json = #"{"access_token":"fake","refresh_token":"fake-refresh","expires_in":3600,"token_type":"Bearer","scope":"openid conve:doors_status"}"#
        let token = try JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: Data(json.utf8))
        #expect(token.scope == "openid conve:doors_status")
        #expect(VolvoScopeCatalog.parseGrantedScopes(token.scope) == ["conve:doors_status", "openid"])
    }

    // MARK: - Degraded readings

    @Test("An ERROR field keeps the provider's own reason")
    func degradedReadingKeepsProviderReason() throws {
        let energy = try JSONDecoder.volvo.decode(
            VolvoEnergyStateDTO.self,
            from: Data(Self.degradedEnergyJSON.utf8))
        let readings = VolvoScopeCatalog.degradedReadings(
            energy: energy, availability: nil, doors: nil, windows: nil, odometer: nil)

        let power = try #require(readings.first { $0.field == "chargingPower" })
        #expect(power.feature == .chargingDetails)
        #expect(power.status == "ERROR")
        #expect(power.reason == "PROPERTY_NOT_FOUND")
        #expect(power.providerText == "ERROR · PROPERTY_NOT_FOUND")

        let battery = try #require(readings.first { $0.field == "batteryChargeLevel" })
        #expect(battery.reason == "POWER_SAVING_MODE")
        // A healthy field is not a degradation.
        #expect(readings.contains { $0.field == "electricRange" } == false)
        #expect(readings.contains { $0.field == "chargingCurrentLimit" } == false)
    }

    @Test("The unavailable card receives the provider's reason instead of generic wording")
    func reportExposesReasonForFeature() throws {
        let energy = try JSONDecoder.volvo.decode(
            VolvoEnergyStateDTO.self, from: Data(Self.degradedEnergyJSON.utf8))
        let readings = VolvoScopeCatalog.degradedReadings(
            energy: energy, availability: nil, doors: nil, windows: nil, odometer: nil)
        let report = VolvoScopeCatalog.report(
            requestedScopes: VolvoAPI.readScopes,
            grantedScopes: VolvoScopeCatalog.parseGrantedScopes(
                VolvoAPI.readScopes.joined(separator: " ")),
            tier: .standard,
            recordedAt: Date(),
            degradedReadings: readings)
        // The first degraded field for a feature is the battery; the power field's own reason
        // is still carried, and the card gets a provider line rather than generic wording.
        #expect(report.reason(for: .chargingDetails)?.contains("POWER_SAVING_MODE") == true)
        #expect(report.statuses(for: .chargingDetails).contains { $0.reason == "PROPERTY_NOT_FOUND" })
        #expect(report.statuses(for: .chargingDetails).count >= 2)
        #expect(report.reason(for: .vehicleLocation) == nil)
    }

    @Test("The report travels with a snapshot and older snapshots still decode")
    func reportPersistsWithSnapshot() throws {
        let report = VolvoScopeCatalog.report(
            requestedScopes: VolvoAPI.readScopes,
            grantedScopes: ["openid"],
            tier: .standard,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            degradedReadings: [])
        var state = VehicleState(
            energy: EnergyAndChargingSnapshot(batteryPercentage: 50),
            identity: VehicleIdentitySnapshot(availability: .unknown, vin: vin),
            freshness: SnapshotFreshness(fetchedAt: Date()))
        state.providerReport = report
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: data)
        #expect(decoded.providerReport == report)
        #expect(decoded.providerReport?.channel == .volvo)
        #expect(decoded.providerReport?.supportedDomains.contains(.location) == true)
    }

    // MARK: - Wiring: a refresh attaches the live grant and the degraded field

    @Test("A refresh records the granted scopes and attaches them to the state")
    @MainActor
    func refreshAttachesScopeEvidenceAndDegradation() async throws {
        let suite = "io.kheirallah.hisingen.volvo-inspector.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.volvo-inspector.\(UUID().uuidString)")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.volvoRestrictedScopesEnabled = true

        let api = VolvoAPI(keychain: keychain, preferences: preferences)
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        await api.installInspectorTransport()
        await api.seedRefreshTokenForInspector()

        // Requesting the full tier records the ask; the mock token response grants only the
        // read scopes, so the inspector can show the restricted domains as refused.
        _ = try await api.beginSignIn(tier: .full)
        try await api.refreshAccessToken(force: true)

        let state = try await api.fetchVehicleState(
            vin: vin,
            features: FeatureSelection(enabled: [.chargingDetails, .vehicleAvailability, .exteriorStatus]))

        let report = try #require(state.providerReport)
        #expect(report.channel == .volvo)
        #expect(report.grantedScopes == VolvoAPI.readScopes.sorted())
        #expect(report.requestedScopes.contains("conve:lock"))
        #expect(report.grants.first { $0.domain == .locks }?.state == .notGranted)
        #expect(report.grants.first { $0.domain == .telemetry }?.state == .granted)
        let degraded = try #require(report.degradedReadings.first { $0.field == "chargingPower" })
        #expect(degraded.reason == "PROPERTY_NOT_FOUND")
        #expect(state.freshness.unavailableFeatures.contains(.chargingDetails) == false)

        // The inspection state is durable: a relaunch can show it before the next refresh.
        #expect(preferences.volvoGrantedScopes == VolvoAPI.readScopes.sorted())
        #expect(preferences.volvoRequestedScopes.contains("conve:lock"))
        #expect(preferences.volvoGrantTier == VolvoAPI.ScopeTier.full.rawValue)
    }

    // MARK: - Payloads

    /// Sanitized shape of a live energy-state response: two fields answer with a status and a
    /// reason, one names its reason explicitly, and the rest are healthy or absent.
    /// The unwrapped payload the adapter's `get` produces, so a direct decode of the DTO reads
    /// the same fields the provider saw.
    static let degradedEnergyJSON = #"""
    {
      "batteryChargeLevel":{"status":"ERROR","code":"POWER_SAVING_MODE","message":"Vehicle is in power saving mode"},
      "electricRange":{"status":"OK","value":210,"unit":"km","updatedAt":"2026-08-15T09:30:00Z"},
      "chargingPower":{"status":"ERROR","code":"PROPERTY_NOT_FOUND","message":"No valid value could be found for the requested property"},
      "chargingSystemStatus":{"status":"ERROR","unavailableReason":"POWER_SAVING_MODE"},
      "chargingCurrentLimit":{"status":"OK","value":16,"unit":"ampere","updatedAt":"2026-08-15T09:30:00Z"}
    }
    """#
}

// MARK: - Transport

private final class InspectorTransportHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }

    func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func get() -> @Sendable (URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class InspectorTransport: URLProtocol {
    static let handler = InspectorTransportHandler()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, data) = Self.handler.get()(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension VolvoAPI {
    func installInspectorTransport() {
        let vin = "YV1INSPECTOR000001"
        let granted = VolvoAPI.readScopes.joined(separator: " ")
        let token = #"{"access_token":"inspector-access","refresh_token":"inspector-refresh","expires_in":3600,"token_type":"Bearer","scope":"\#(granted)"}"#
        let details = #"{"vin":"\#(vin)","modelYear":2025,"descriptions":{"model":"EX40"},"fuelType":"ELECTRIC","specifications":{"driveType":"RWD"}}"#
        let capabilities = #"{"data":{"getEnergyState":{"batteryChargeLevel":{"isSupported":true},"electricRange":{"isSupported":true},"chargingPower":{"isSupported":true},"chargingCurrentLimit":{"isSupported":true}}}}"#
        let accessibility = #"{"data":{"availabilityStatus":{"value":"AVAILABLE","status":"OK","updatedAt":"2026-08-15T09:30:00Z"}}}"#
        let energy = #"{"data":\#(VolvoCapabilityInspectorTests.degradedEnergyJSON)}"#

        InspectorTransport.handler.set { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/connected-vehicle/v2/vehicles/\(vin)": return (200, Data(details.utf8))
            case "/energy/v2/vehicles/\(vin)/state": return (200, Data(energy.utf8))
            case "/energy/v2/vehicles/\(vin)/capabilities": return (200, Data(capabilities.utf8))
            case "/connected-vehicle/v2/vehicles/\(vin)/command-accessibility":
                return (200, Data(accessibility.utf8))
            default:
                if ["/connected-vehicle/", "/energy/", "/location/"].contains(where: { path.hasPrefix($0) }) {
                    return (404, Data("{}".utf8))
                }
                return (200, Data(token.utf8))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InspectorTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }

    func seedRefreshTokenForInspector() {
        refreshToken = "stored-refresh"
    }
}
