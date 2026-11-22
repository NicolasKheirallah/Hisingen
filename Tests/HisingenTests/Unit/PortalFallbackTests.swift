import Foundation
import Testing
@testable import Hisingen

/// S20: `.dataPortal` had no fallback at all. These tests exercise the composition with the
/// saved portal telemetry fixtures: a portal refresh that succeeds still gets the consumer-only
/// domains, and one that cannot serve (entitlement or transport) is answered by the consumer
/// session with the fallback provenance recorded. The entitlement probe is exercised against the
/// saved vehicle-list fixture through an injected transport.
@Suite("Portal fallback", .serialized)
struct PortalFallbackTests {
    private let vin = "YSMVSEDE6PL147228"

    // MARK: - Domain support map

    @Test("The support map says what the portal cannot serve")
    func domainSupportMapSeparatesChannels() {
        #expect(ProviderDomainSupportMap.supports(.energy, on: .polestarDataPortal))
        #expect(ProviderDomainSupportMap.supports(.schedules, on: .polestarDataPortal))
        #expect(ProviderDomainSupportMap.supports(.software, on: .polestarDataPortal) == false)
        #expect(ProviderDomainSupportMap.supports(.connectivity, on: .polestarDataPortal) == false)
        #expect(ProviderDomainSupportMap.supports(.commands, on: .polestarDataPortal) == false)
        #expect(ProviderDomainSupportMap.supports(.software, on: .polestarID))
        #expect(ProviderDomainSupportMap.supports(.commands, on: .polestarID))

        let missing = ProviderDomainSupportMap.domainsMissing(
            from: .polestarDataPortal, suppliedBy: .polestarID)
        #expect(missing.contains(.software))
        #expect(missing.contains(.connectivity))
        #expect(missing.contains(.commands))
        #expect(missing.contains(.energy) == false)
    }

    @Test("The fallback policy skips a portal that cannot be entitled")
    func fallbackPolicyNamesBlockedPortalStates() {
        #expect(PortalFallbackPolicy.decide(entitlement: .entitled, consumerWarm: true) == .portalFirst)
        #expect(PortalFallbackPolicy.decide(entitlement: .credentialsMissing, consumerWarm: true)
                == .fallbackOnly(reason: PortalEntitlement.credentialsMissing.explanation))
        #expect(PortalFallbackPolicy.decide(entitlement: .accessRevoked(retryAfter: nil), consumerWarm: true)
                != .portalFirst)
        // Without a warm consumer session there is nowhere to go: the portal attempt must run
        // so its own error reaches the reader instead of being hidden by a fallback that cannot
        // authenticate.
        #expect(PortalFallbackPolicy.decide(entitlement: .credentialsMissing, consumerWarm: false) == .portalFirst)
        // An expired stated window lets the portal prove itself again.
        #expect(PortalFallbackPolicy.decide(
            entitlement: .rateLimited(retryAfter: Date(timeIntervalSince1970: 100)),
            consumerWarm: true,
            now: Date(timeIntervalSince1970: 200)) == .portalFirst)
    }

    // MARK: - Fixture-driven fallback

    @Test("A portal refresh fills consumer-only domains from the support map")
    func portalRefreshOverlaysConsumerOnlyDomains() async throws {
        let portalState = try portalFixtureState()
        #expect(portalState.energy.batteryPercentage == 78.5)
        #expect(portalState.softwareInfo == nil)
        #expect(portalState.connectivity == nil)

        var consumerState = consumerFixtureState()
        consumerState.softwareInfo = VehicleSoftwareInfo(
            version: "3.1.9", title: "Software", state: .completed, updatedAt: Date())
        consumerState.connectivity = VehicleConnectivity(state: .connected, networkType: "LTE")

        let consumer = FallbackStub(
            outcome: .state(consumerState),
            warm: true,
            identity: VehicleIdentitySnapshot(availability: .unknown,
                                                modelName: "Polestar 2", vin: vin),
            overlay: ConsumerTelemetryOverlay(
                softwareInfo: consumerState.softwareInfo,
                connectivity: consumerState.connectivity))
        let portal = FallbackStub(outcome: .state(portalState), warm: true)
        let provider = PortalFallbackProvider(
            portal: portal, consumer: consumer, entitlementProbe: { _ in .entitled })

        let state = try await provider.fetchVehicleState(
            vin: vin, features: FeatureSelection(enabled: [.chargingDetails, .softwareUpdates, .connectivityDiagnostics]))

        #expect(state.energy.batteryPercentage == 78.5)
        // The portal cannot serve these; the map — not a hard-coded list — said to ask.
        #expect(state.softwareInfo?.version == "3.1.9")
        #expect(state.connectivity?.state == .connected)
        #expect(state.identity.modelName == "Polestar 2")
        #expect(state.providerReport?.channel == .polestarDataPortal)
        #expect(state.providerReport?.servedByFallback == false)
        let portalCalls = await portal.fetchCount
        #expect(portalCalls == 1)
    }

    @Test("A blocked portal is answered from the consumer session, with provenance")
    func blockedPortalUsesConsumerFixture() async throws {
        let consumerState = consumerFixtureState()
        let consumer = FallbackStub(outcome: .state(consumerState), warm: true)
        let portal = FallbackStub(outcome: .state(try portalFixtureState()), warm: true)
        let provider = PortalFallbackProvider(
            portal: portal,
            consumer: consumer,
            entitlementProbe: { _ in
                .rateLimited(retryAfter: Date().addingTimeInterval(3_600))
            })

        let state = try await provider.fetchVehicleState(
            vin: vin, features: FeatureSelection(enabled: [.chargingDetails]))

        #expect(state.energy.batteryPercentage == 41)
        #expect(state.freshness.servedByFallback == true)
        #expect(state.providerReport?.channel == .polestarID)
        #expect(state.providerReport?.servedByFallback == true)
        #expect(state.providerReport?.connectionNote?.isEmpty == false)
        // The policy skipped the portal entirely rather than spending a doomed request.
        let portalCalls = await portal.fetchCount
        #expect(portalCalls == 0)
    }

    @Test("A portal transport failure falls back and keeps the consumer reading")
    func portalFailureFallsBack() async throws {
        let consumerState = consumerFixtureState()
        let consumer = FallbackStub(outcome: .state(consumerState), warm: true)
        let portal = FallbackStub(
            outcome: .portalError(.server(statusCode: 503)), warm: true)
        let provider = PortalFallbackProvider(
            portal: portal, consumer: consumer, entitlementProbe: { _ in .entitled })

        let state = try await provider.fetchVehicleState(
            vin: vin, features: FeatureSelection(enabled: [.chargingDetails]))

        #expect(state.energy.batteryPercentage == 41)
        #expect(state.freshness.servedByFallback == true)
        let portalCalls = await portal.fetchCount
        #expect(portalCalls == 1)
    }

    // MARK: - Entitlement probe against the saved vehicle list

    @Test("The entitlement probe reads the portal vehicle list fixture")
    @MainActor
    func entitlementProbeReadsFixture() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "polestar-portal-vehicles",
                                                     withExtension: "json"))
        let vehiclesData = try Data(contentsOf: fixture)

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.portal-entitlement.\(UUID().uuidString)")
        try keychain.savePolestarDataPortalCredentials(
            accountID: "fixture-account", clientID: "fixture-client", clientSecret: "fixture-secret")
        let suite = "io.kheirallah.hisingen.portal-entitlement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)

        let quotaBox = PortalFallbackQuotaBox()
        PolestarDataPortalAPI.quotaStateStore = QuotaStateStore(
            get: { (count: quotaBox.count, dateString: "") },
            set: { count, _ in quotaBox.count = count })
        defer { PolestarDataPortalAPI.quotaStateStore = nil }

        PortalEntitlementTransport.handler.set { request in
            if (request.url?.path ?? "").hasSuffix("/v1/vehicles") {
                return (200, vehiclesData)
            }
            return (500, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalEntitlementTransport.self]
        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences)
        await api.setSessionForTesting(URLSession(configuration: configuration))
        try await api.prepareSession()
        await api.setAccessTokenForTesting("fixture-token", expiry: Date().addingTimeInterval(3_600))

        let entitlement = await api.probeEntitlement(now: Date())
        #expect(entitlement == .entitled)

        // The same probe names a revoked grant rather than a generic failure.
        PortalEntitlementTransport.handler.set { _ in
            (403, Data(#"{"error":{"code":"AUTHZ_VIN_UNAUTHORIZED","message":"No consent"}}"#.utf8))
        }
        await api.setAccessTokenForTesting("fixture-token", expiry: Date().addingTimeInterval(3_600))
        let revoked = await api.probeEntitlement(now: Date())
        #expect(revoked == .accessRevoked(retryAfter: nil))
    }

    // MARK: - Fixtures

    private func decodeFixture<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// The saved portal telemetry fixtures, assembled by the production assembler. This makes
    /// the fallback test travel through real decoding instead of asserting against hand-built
    /// values.
    private func portalFixtureState() throws -> VehicleState {
        func data<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T? {
            try decodeFixture(PolestarDataPortalEnvelope<T>.self, name).data
        }
        let battery = try data(PolestarBatteryDTO.self, "polestar-portal-battery")
        let exterior = try data(PolestarExteriorDTO.self, "polestar-portal-exterior")
        let health = try data(PolestarHealthDTO.self, "polestar-portal-health")
        let availability = try data(PolestarAvailabilityDTO.self, "polestar-portal-availability")
        let odometer = try data(PolestarOdometerDTO.self, "polestar-portal-odometer")
        let location = try data(PolestarLocationDTO.self, "polestar-portal-location")
        let bundle = PolestarPortalTelemetryBundle(
            battery: battery,
            exterior: exterior,
            health: health,
            availability: availability,
            odometer: odometer,
            location: location,
            parkingClimatization: nil,
            preCleaning: nil,
            targetSoc: nil,
            ampLimit: nil,
            chargeLocations: nil,
            globalChargeTimer: nil,
            parkingClimateTimer: nil,
            chargeNow: nil)
        return PolestarPortalSnapshotAssembler.assembleVehicleState(
            vin: vin,
            bundle: bundle,
            weather: nil,
            now: Date(timeIntervalSince1970: 1_716_300_200),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    private func consumerFixtureState() -> VehicleState {
        var state = VehicleState(
            energy: EnergyAndChargingSnapshot(batteryPercentage: 41, rangeKm: 260),
            identity: VehicleIdentitySnapshot(availability: .unknown, vin: vin),
            freshness: SnapshotFreshness(fetchedAt: Date(timeIntervalSince1970: 1_716_300_000)))
        state.powertrain = .bev
        return state
    }
}

// MARK: - Test doubles

private enum StubOutcome: Sendable {
    case state(VehicleState)
    case portalError(PolestarDataPortalError)
}

private actor FallbackStub: VehicleProviding, VehicleMetadataProviding {
    nonisolated let brand: VehicleBrand = .polestar
    private let outcome: StubOutcome
    private let warm: Bool
    private let identity: VehicleIdentitySnapshot?
    private let overlay: ConsumerTelemetryOverlay?
    private(set) var fetchCount = 0

    init(
        outcome: StubOutcome,
        warm: Bool,
        identity: VehicleIdentitySnapshot? = nil,
        overlay: ConsumerTelemetryOverlay? = nil
    ) {
        self.outcome = outcome
        self.warm = warm
        self.identity = identity
        self.overlay = overlay
    }

    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { warm }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        switch outcome {
        case .state(let state): return state
        case .portalError(let error): throw error
        }
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }

    func identitySnapshot(for vin: String, features: FeatureSelection) async -> VehicleIdentitySnapshot? {
        identity
    }

    func consumerTelemetryOverlay(for vin: String, features: FeatureSelection) async -> ConsumerTelemetryOverlay? {
        overlay
    }
}

private final class PortalFallbackQuotaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

private final class PortalEntitlementHandler: @unchecked Sendable {
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

private final class PortalEntitlementTransport: URLProtocol {
    static let handler = PortalEntitlementHandler()

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
