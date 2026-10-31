import Foundation
import Testing
@testable import Hisingen

struct PolestarPortalHardeningTests {
    @Test func rejectsOverflowAndInvalidTimestampComponents() throws {
        #expect(portalRoundedInt(1e100) == nil)
        #expect(portalRoundedInt(.infinity) == nil)
        #expect(portalRoundedInt(101, range: 0...100) == nil)
        #expect(PolestarDataPortalTimestamp(seconds: "nan", nanos: 0).date == nil)
        #expect(PolestarDataPortalTimestamp(seconds: "1", nanos: 1_000_000_000).date == nil)
        #expect(PolestarDataPortalTimestamp(seconds: "1", nanos: 500_000_000).date == Date(timeIntervalSince1970: 1.5))
    }

    @Test func extremeBatteryValuesDoNotBecomeReadings() throws {
        let json = #"{"vin":"VIN","batteryChargeLevelPercentage":1e100,"chargingCurrentAmps":1e100}"#
        let battery = try JSONDecoder().decode(PolestarDataPortalBatteryDTO.self, from: Data(json.utf8))
        let state = battery.toEnergySnapshot()
        #expect(state.batteryPercentage == nil)
        #expect(state.currentAmps == nil)
    }
}

@Suite(.serialized)
struct PolestarPortalRequestHardeningTests {
    @MainActor private func client(diagnosticLog: APIDiagnosticLogStore = .shared) async -> PolestarDataPortalAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalHardeningProtocol.self]
        let api = PolestarDataPortalAPI(preferences: .shared, diagnosticLog: diagnosticLog)
        await api.configure(clientID: "client", clientSecret: "secret")
        await api.setSessionForTesting(URLSession(configuration: configuration))
        await api.setAccessTokenForTesting("token")
        return api
    }

    /// Installs a private quota backing store for the calling test and seeds it. The
    /// process-global store is written by every portal call in every parallel suite, so an
    /// exact count assertion is only hermetic against its own store. Pair with
    /// `defer { releaseQuotaStore() }`.
    private func ownQuotaStore(seed count: Int, date: Date) {
        let box = QuotaBox()
        PolestarDataPortalAPI.quotaStateStore = QuotaStateStore(
            get: { box.value },
            set: { storeCount, storeDate in box.value = (storeCount, storeDate) })
        PolestarDataPortalAPI.setDailyQuotaForTesting(count: count, date: date)
    }

    private func releaseQuotaStore() {
        PolestarDataPortalAPI.quotaStateStore = nil
    }

    @Test @MainActor func rejectsAnotherVehiclesPayload() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        PortalHardeningProtocol.handler = { _ in (200, Data(#"{"vin":"OTHER","batteryChargeLevelPercentage":50}"#.utf8)) }
        do {
            _ = try await api.fetchVehicleState(vin: "EXPECTED", features: FeatureSelection(enabled: [.chargingDetails]))
            Issue.record("A different vehicle's response was accepted")
        } catch PolestarDataPortalError.invalidResponse { }
    }

    @Test @MainActor func lastQuotaSlotIsReservedForOnlyOneAttempt() async throws {
        ownQuotaStore(seed: PolestarDataPortalAPI.dailyCallLimit - 1, date: Date())
        defer { releaseQuotaStore() }
        let api = await client()
        PortalHardeningProtocol.handler = { _ in (200, Data(#"{"vin":"VIN","batteryChargeLevelPercentage":50}"#.utf8)) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try? await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.chargingDetails])) }
            }
        }
        #expect(PolestarDataPortalAPI.dailyCallCount == PolestarDataPortalAPI.dailyCallLimit)
    }

    @Test @MainActor func unrequestedReadingsHaveNoFreshObservation() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        PortalHardeningProtocol.handler = { _ in (200, Data(#"{"vin":"VIN","availabilityStatus":"AVAILABLE"}"#.utf8)) }
        let state = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
        #expect(state.freshness.readingObservations?[.availability]?.source == .polestarPortal)
        #expect(state.freshness.readingObservations?[.charging] == nil)
        #expect(state.freshness.readingObservations?[.battery] == nil)
    }

    @Test @MainActor func chargingCommandObservationsTrackTheirOwnEndpoints() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        PortalHardeningProtocol.handler = { request in
            if request.url?.path.hasSuffix("/target-soc") == true {
                return (200, Data(#"{"vin":"VIN","targetSoc":{"batteryChargeTargetLevel":80}}"#.utf8))
            }
            return (404, Data(#"{"error":{"code":"DATA_NOT_AVAILABLE","message":"not available"}}"#.utf8))
        }
        let state = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.remoteCharging]))
        #expect(state.freshness.commandObservations?[.chargeTarget]?.source == .polestarPortal)
        #expect(state.freshness.commandObservations?[.chargingCurrentLimit] == nil)
        #expect(state.freshness.commandObservations?[.chargingState] == nil)
    }

    @Test @MainActor func currentLimitObservationDoesNotImplyTargetObservation() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        PortalHardeningProtocol.handler = { request in
            if request.url?.path.hasSuffix("/amp-limit") == true {
                return (200, Data(#"{"vin":"VIN","ampLimit":{"ampLimit":16}}"#.utf8))
            }
            return (404, Data(#"{"error":{"code":"DATA_NOT_AVAILABLE","message":"not available"}}"#.utf8))
        }
        let state = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.remoteCharging]))
        #expect(state.freshness.commandObservations?[.chargingCurrentLimit]?.source == .polestarPortal)
        #expect(state.freshness.commandObservations?[.chargeTarget] == nil)
        #expect(state.freshness.commandObservations?[.chargingState] == nil)
    }

    @Test @MainActor func quotaRollsOverAtUTCDayBoundary() async throws {
        ownQuotaStore(seed: PolestarDataPortalAPI.dailyCallLimit, date: Date(timeIntervalSinceNow: -172_800))
        let api = await client()
        PortalHardeningProtocol.handler = { _ in (200, Data(#"{"vin":"VIN","availabilityStatus":"AVAILABLE"}"#.utf8)) }
        _ = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
        #expect(PolestarDataPortalAPI.dailyCallCount == 1)
    }

    @Test @MainActor func vinDenialDoesNotBlockAnotherVehicle() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        PortalHardeningProtocol.handler = { request in
            if request.url?.path.contains("/DENIED/") == true {
                return (403, Data(#"{"error":{"code":"AUTHZ_VIN_UNAUTHORIZED","message":"denied"}}"#.utf8))
            }
            return (200, Data(#"{"vin":"ALLOWED","batteryChargeLevelPercentage":40}"#.utf8))
        }
        do {
            _ = try await api.fetchVehicleState(vin: "DENIED", features: FeatureSelection(enabled: [.chargingDetails]))
            Issue.record("Expected denial")
        } catch PolestarDataPortalError.permissionDenied { }
        let allowed = try await api.fetchVehicleState(vin: "ALLOWED", features: FeatureSelection(enabled: [.chargingDetails]))
        #expect(allowed.energy.batteryPercentage == 40)
    }

    @Test @MainActor func credentialReplacementRejectsLateResponse() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        PortalHardeningProtocol.handler = { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"{"vin":"VIN","availabilityStatus":"AVAILABLE"}"#.utf8))
        }
        let task = Task { try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability])) }
        let didEnter = await Task.detached { waitForPortalSemaphore(entered) }.value
        #expect(didEnter)
        await api.configure(clientID: "replacement", clientSecret: "secret")
        release.signal()
        do {
            _ = try await task.value
            Issue.record("A response from the old configuration was published")
        } catch is CancellationError { }
    }

    @Test @MainActor func resetRejectsDelayedDiscovery() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        PortalHardeningProtocol.handler = { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"["VIN"]"#.utf8))
        }
        let task = Task { try await api.discoverVehicles(preferredVIN: nil) }
        let didEnter = await Task.detached { waitForPortalSemaphore(entered) }.value
        #expect(didEnter)
        await api.resetSession()
        release.signal()
        do {
            try await task.value
            Issue.record("A delayed discovery restored the old garage")
        } catch { }
        #expect(await api.cars.isEmpty)
    }

    @Test @MainActor func signOutRejectsDelayedDiscovery() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let suite = "io.kheirallah.hisingen.portal-signout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.portal-signout.\(UUID().uuidString)")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalHardeningProtocol.self]
        await api.configure(clientID: "client", clientSecret: "secret")
        await api.setSessionForTesting(URLSession(configuration: configuration))
        await api.setAccessTokenForTesting("token")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        PortalHardeningProtocol.handler = { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"["VIN"]"#.utf8))
        }
        let task = Task { try await api.discoverVehicles(preferredVIN: nil) }
        let didEnter = await Task.detached { waitForPortalSemaphore(entered) }.value
        #expect(didEnter)
        try await api.signOut()
        release.signal()
        do {
            try await task.value
            Issue.record("A delayed discovery restored a signed-out garage")
        } catch { }
        #expect(await api.cars.isEmpty)
        #expect(await api.isConfigured == false)
    }

    @Test @MainActor func invalidSuccessfulGrantsAreRejected() async throws {
        for body in [
            #"{"accessToken":"","expiresIn":3600,"tokenType":"Bearer"}"#,
            #"{"accessToken":"token","expiresIn":0,"tokenType":"Bearer"}"#,
            #"{"accessToken":"token","expiresIn":3600,"tokenType":"Basic"}"#
        ] {
            ownQuotaStore(seed: 0, date: Date())
            let api = await client()
            await api.configure(clientID: "new-client", clientSecret: "secret")
            PortalHardeningProtocol.handler = { _ in (200, Data(body.utf8)) }
            do {
                _ = try await api.ensureAccessToken()
                Issue.record("Malformed grant was adopted")
            } catch PolestarDataPortalError.decoding { }
        }
    }

    @Test @MainActor func lateUnauthorizedResponseReusesReplacementGrant() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let log = APIDiagnosticLogStore()
        let api = await client(diagnosticLog: log)
        let counter = PortalAttemptCounter()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        PortalHardeningProtocol.handler = { request in
            if request.url?.path.hasSuffix("/token") == true {
                counter.recordGrant()
                return (200, Data(#"{"accessToken":"replacement","expiresIn":3600,"tokenType":"Bearer"}"#.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token" {
                if counter.nextOldRequest() == 1 {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
                return (401, Data())
            }
            return (200, Data(#"{"vin":"VIN","availabilityStatus":"AVAILABLE"}"#.utf8))
        }
        let selection = FeatureSelection(enabled: [.vehicleAvailability])
        let first = Task { try await api.fetchVehicleState(vin: "VIN", features: selection) }
        let didEnter = await Task.detached { waitForPortalSemaphore(entered) }.value
        #expect(didEnter)
        _ = try await api.fetchVehicleState(vin: "VIN", features: selection)
        release.signal()
        _ = try await first.value
        #expect(counter.grants == 1)
        #expect(PolestarDataPortalAPI.dailyCallCount == 5)
        let entries = await log.snapshot()
        let reads = entries.filter { $0.operation.hasPrefix("Data Portal:") }
        let grouped = Dictionary(grouping: reads, by: { $0.logicalOperationID })
        #expect(grouped.count == 2)
        for (id, attempts) in grouped {
            #expect(id.flatMap(UUID.init(uuidString:)) != nil)
            #expect(Set(attempts.compactMap(\.attempt)) == Set([1, 2]))
        }
        let grant = try #require(entries.first { $0.operation == "Polestar Data Portal token grant" })
        #expect(grant.attempt == 1)
        #expect(grant.logicalOperationID.flatMap(UUID.init(uuidString:)) != nil)
        #expect(!grouped.keys.contains(grant.logicalOperationID))
    }

    @Test @MainActor func incompleteCustomCredentialsAreRejected() async throws {
        let suite = "io.kheirallah.hisingen.portal-hardening.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.portal-hardening.\(UUID().uuidString)")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.polestarDataPortalClientID = "custom-id"
        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences)
        do {
            try await api.prepareSession()
            Issue.record("An incomplete custom pair was accepted")
        } catch PolestarDataPortalError.appNotConfigured { }
    }

    @Test @MainActor func transportFailuresKeepPortalErrorPolicy() async throws {
        ownQuotaStore(seed: 0, date: Date())
        let api = await client()
        defer { PortalHardeningProtocol.failure = nil }
        PortalHardeningProtocol.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
            Issue.record("Expected offline failure")
        } catch PolestarDataPortalError.network(let error) {
            #expect(error.code == .notConnectedToInternet)
        }
        PortalHardeningProtocol.failure = URLError(.cancelled)
        do {
            _ = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
        PortalHardeningProtocol.failure = nil
        PortalHardeningProtocol.handler = { _ in (200, Data(repeating: 65, count: 1_000_001)) }
        do {
            _ = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
            Issue.record("Expected oversized response failure")
        } catch PolestarDataPortalError.responseTooLarge { }
    }

    @Test @MainActor func injectedClockControlsQuotaDayAndSnapshot() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        ownQuotaStore(seed: 0, date: fixed)
        defer { releaseQuotaStore() }
        let suite = "io.kheirallah.hisingen.portal-clock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.portal-clock.\(UUID().uuidString)")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences, now: { fixed }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalHardeningProtocol.self]
        await api.configure(clientID: "client", clientSecret: "secret")
        await api.setSessionForTesting(URLSession(configuration: configuration))
        await api.setAccessTokenForTesting("token", expiry: fixed.addingTimeInterval(3600))
        PortalHardeningProtocol.handler = { _ in (200, Data(#"{"vin":"VIN","availabilityStatus":"AVAILABLE"}"#.utf8)) }
        let state = try await api.fetchVehicleState(vin: "VIN", features: FeatureSelection(enabled: [.vehicleAvailability]))
        #expect(state.freshness.fetchedAt == fixed)
        #expect(api.dailyCallCount == 1)
    }

    @Test @MainActor func lockedCredentialsDoNotFallBack() async throws {
        let suite = "io.kheirallah.hisingen.portal-locked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.portal-locked.\(UUID().uuidString)")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let api = PolestarDataPortalAPI(keychain: keychain, preferences: preferences, credentialReader: { throw KeychainError.interactionRequired })
        do {
            try await api.prepareSession()
            Issue.record("Locked credentials were treated as missing")
        } catch PolestarDataPortalError.secureStorage { }
        #expect(await api.isConfigured == false)
    }

    @Test func assemblerUsesInjectedClockAndPreservesUnknownAvailability() throws {
        let dto = try JSONDecoder().decode(PolestarDataPortalAvailabilityDTO.self, from: Data(#"{"vin":"VIN","availabilityStatus":"FUTURE_AVAILABLE"}"#.utf8))
        let bundle = PolestarPortalTelemetryBundle(battery: nil, exterior: nil, health: nil, availability: dto, odometer: nil, location: nil, parkingClimatization: nil, preCleaning: nil, targetSoc: nil, ampLimit: nil, chargeLocations: nil, globalChargeTimer: nil, parkingClimateTimer: nil, chargeNow: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = PolestarPortalSnapshotAssembler.assembleVehicleState(vin: "VIN", bundle: bundle, weather: nil, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(result.identity.availability == .unknown)
        #expect(result.freshness.fetchedAt == now)
    }

    @Test func planHonorsBudgetAndSelection() {
        let location = PolestarPortalFetchPlan(features: FeatureSelection(enabled: [.vehicleLocation]), budget: 5)
        #expect(location.needsLocation)
        #expect(!location.needsBattery)
        #expect(location.estimatedCost == 1)
        let empty = PolestarPortalFetchPlan(features: FeatureSelection(enabled: Set(AppFeature.allCases)), budget: 0)
        #expect(empty.estimatedCost == 0)
        #expect(!empty.needsBattery)
        let features = FeatureSelection(enabled: [.chargingDetails, .vehicleLocation])
        let early = PolestarPortalFetchPlan(features: features, budget: 1, rotation: 0)
        let later = PolestarPortalFetchPlan(features: features, budget: 1, rotation: 1)
        #expect(early.needsBattery)
        #expect(!early.needsLocation)
        #expect(later.needsBattery)
        #expect(!later.needsLocation)
        let optionalEarly = PolestarPortalFetchPlan(features: features, budget: 2, rotation: 0)
        let optionalLater = PolestarPortalFetchPlan(features: features, budget: 2, rotation: 1)
        #expect(optionalEarly.needsLocation)
        #expect(!optionalLater.needsLocation)
        #expect(optionalLater.needsBattery)
    }
}

private final class PortalHardeningProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        guard let (status, data) = Self.handler?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PortalAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var oldRequests = 0
    private var grantCount = 0
    func nextOldRequest() -> Int { lock.withLock { oldRequests += 1; return oldRequests } }
    func recordGrant() { lock.withLock { grantCount += 1 } }
    var grants: Int { lock.withLock { grantCount } }
}

private func waitForPortalSemaphore(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 3) == .success
}
