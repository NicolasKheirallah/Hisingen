import Foundation
import Testing
@testable import Hisingen

/// Regression cover for the failure mode where a single upstream authentication error parked the
/// app on its on-disk snapshot indefinitely: the refresh loop stopped rescheduling, and because
/// `cacheableCopy` keeps only a handful of fields, every card backed by live telemetry silently
/// vanished — indistinguishable from a vehicle that does not support those features.
@MainActor
struct DegradedStateResilienceTests {

    // MARK: - The refresh loop must not give up on recoverable errors

    @Test
    func testExpiredSessionStillRetriesAutomatically() {
        let expired = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        let noSession = VehicleServiceError.authenticationRequired(provider: .volvo, reason: .noStoredSession)
        #expect(expired.allowsAutomaticRetry)
        #expect(noSession.allowsAutomaticRetry)
        // These are not "transient" — the point is that retry eligibility is a separate question.
        #expect(!(expired.isTransient))
    }

    @Test
    func testErrorsNeedingOwnerActionStopTheLoop() {
        let badPassword = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .invalidCredentials)
        let extraStep = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .callbackRejected)
        #expect(!(badPassword.allowsAutomaticRetry))
        #expect(!(extraStep.allowsAutomaticRetry))
        #expect(!(VehicleServiceError.notConfigured.allowsAutomaticRetry))
        #expect(!(VehicleServiceError.secureStorage.allowsAutomaticRetry))
    }

    @Test
    func testTransientErrorsStillRetry() {
        #expect(VehicleServiceError.network(URLError(.timedOut)).allowsAutomaticRetry)
        #expect(VehicleServiceError.server(statusCode: 503).allowsAutomaticRetry)
        #expect(VehicleServiceError.rateLimited(retryAfter: nil).allowsAutomaticRetry)
    }

    @Test
    func testSessionRecoveryBacksOffHarderThanAPlainRefetch() {
        let refetch = RefreshPolicy.retryDelay(failureCount: 1, retryAfter: nil, requiresNewSession: false)
        let session = RefreshPolicy.retryDelay(failureCount: 1, retryAfter: nil, requiresNewSession: true)
        #expect(session > refetch)
        // An explicit Retry-After still wins over the session backoff.
        #expect(RefreshPolicy.retryDelay(failureCount: 4, retryAfter: 90, requiresNewSession: true) == 90)
        // And the ceiling stays bounded no matter how many times we have failed.
        #expect(RefreshPolicy.retryDelay(failureCount: 99, retryAfter: nil, requiresNewSession: true) <= 1_800)
    }

    // MARK: - A field-level denial is not a dead session

    @Test
    func testFieldScopedAuthorizationErrorIsNotSessionDeath() {
        let fieldDenied = graphQLError(
            message: "Not authorized to access field", path: ["carTelematicsV2", "health"]
        )
        #expect(!(PolestarAPI.containsAuthenticationError([fieldDenied])))
    }

    @Test
    func testFieldScopedUnauthenticatedCodeIsNotSessionDeath() {
        let fieldDenied = graphQLError(
            message: "denied", path: ["carTelematicsV2", "battery"], code: "UNAUTHENTICATED"
        )
        #expect(!(PolestarAPI.containsAuthenticationError([fieldDenied])))
    }

    @Test
    func testTopLevelAuthenticationErrorIsStillSessionDeath() {
        #expect(PolestarAPI.containsAuthenticationError([
            graphQLError(message: "token has expired", path: [])
        ]))
        #expect(PolestarAPI.containsAuthenticationError([
            graphQLError(message: "nope", path: [], code: "UNAUTHENTICATED")
        ]))
    }

    // MARK: - The cache contract, made explicit

    @Test
    func testCacheableCopyDropsLiveTelemetryButKeepsIdentityAndCharge() {
        let full = stateWithFullTelemetry()
        let cached = full.cacheableCopy

        // Kept: identity, build specs, odometer, battery, options
        #expect(cached.identity.vin == full.identity.vin)
        #expect(cached.energy.batteryPercentage == full.energy.batteryPercentage)
        #expect(cached.energy.rangeKm == full.energy.rangeKm)
        #expect(cached.identity.modelName == full.identity.modelName)
        // Dropped for privacy: live GPS location coordinates, owner greeting, and registration plate
        #expect(cached.location == nil)
        #expect(cached.identity.ownerFirstName == nil)
        #expect(cached.identity.registrationNo == nil)
    }

    @Test
    func testSnapshotReadFromDiskIsFlaggedAsCached() async throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())

        let live = stateWithFullTelemetry()
        #expect(!(live.freshness.isCached))
        store.save(live)
        // Persistence hands off to a detached storage pass; wait for it to land.
        let stored = await awaitStored(timeout: 5) { store.snapshot(for: live.identity.vin) != nil }
        #expect(stored, "snapshot never reached the database after save")

        let restored = try #require(store.snapshot(for: live.identity.vin))
        #expect(restored.freshness.isCached)
        // Cached snapshots must not retain precise location data.
        #expect(restored.location == nil)
    }

    @Test
    func testLegacyUserDefaultsSnapshotMigratesAndRedactsSensitiveFields() throws {
        let suiteName = "HisingenTests.legacy-cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let database = VehicleDatabase.inMemory()
        let live = stateWithFullTelemetry()
        let encoded = try JSONEncoder().encode(live)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // Recreate the pre-clustered persisted layout: older releases wrote these flat
        // keys, whereas current snapshots group them under fuel/service/trip objects.
        legacy.removeValue(forKey: "fuelSystem")
        legacy.removeValue(forKey: "serviceInfo")
        legacy.removeValue(forKey: "tripComputer")
        legacy["fuelLevelPercent"] = 55.0
        legacy["fuelRangeKm"] = 320
        legacy["daysToService"] = 200
        legacy["distanceToServiceKm"] = 8_000
        legacy["serviceWarning"] = false
        legacy["fluidWarnings"] = []
        legacy["tripMeterManualKm"] = 12.5
        legacy["tripMeterAutomaticKm"] = 48.0
        let cached = try JSONSerialization.data(withJSONObject: [live.identity.vin: legacy])
        defaults.set(cached, forKey: "cached_vehicle_snapshots_v1")

        let store = VehicleStateStore(defaults: defaults, database: database)
        let migrated = try #require(store.snapshot(for: live.identity.vin))
        #expect(migrated.freshness.isCached)
        #expect(migrated.fuelSystem.levelPercent == 55.0)
        #expect(migrated.maintenance.service.daysToService == 200)
        #expect(migrated.tripComputer.manualTripKm == 12.5)
        #expect(migrated.location == nil)
        #expect(migrated.identity.ownerFirstName == nil)
        #expect(migrated.identity.registrationNo == nil)

        let remainingData = try #require(defaults.data(forKey: "cached_vehicle_snapshots_v1"))
        let remaining = try JSONDecoder().decode([String: VehicleState].self, from: remainingData)
        #expect(remaining[live.identity.vin] == nil)
        #expect(database.loadSnapshot(for: live.identity.vin)?.location == nil)
    }

    // MARK: - Helpers

    private func graphQLError(message: String, path: [String], code: String? = nil) -> GraphQLErrorDTO {
        var payload: [String: Any] = ["message": message, "path": path]
        if let code { payload["extensions"] = ["code": code] }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(GraphQLErrorDTO.self, from: data)
    }

    fileprivate func stateWithFullTelemetry() -> VehicleState {
        VehicleState(
            batteryPercentage: 77, rangeKm: 400, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 90,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "XC40", modelYear: "2024", registrationNo: "ABC123",
            vin: "YV1TESTVIN0000001", ownerFirstName: "Nico", odometerKm: 12_345,
            daysToService: 200, distanceToServiceKm: 8_000, serviceWarning: false,
            fluidWarnings: [],
            exteriorStatus: ExteriorSnapshot(
                openings: [OpeningReading(opening: .frontLeftDoor, state: .closed)],
                isLocked: true, alarmTriggered: nil
            ),
            healthDetails: VehicleHealthDetails(
                tyres: [TyrePressure(position: .frontLeft, kilopascals: nil, warning: .none)],
                warnings: []
            ),
            softwareInfo: VehicleSoftwareInfo(
                version: "5.1.17", title: "5.1.17", state: .completed, scheduledAt: nil,
                updatedAt: nil, installedVersion: "5.1.17", latestAvailableVersion: "5.1.17"
            ),
            climateStatus: VehicleClimateStatus(
                activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                interiorTemperatureCelsius: 21, requestedTemperatureCelsius: 22
            ),
            location: VehicleLocation(latitude: 57.7, longitude: 11.9, heading: nil,
                                      speed: nil, timestamp: nil),
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
        )
    }
}

/// The end-to-end version of the bug: an authentication failure on the telemetry call must not
/// leave the coordinator with no scheduled work. Before this, `handle` invalidated the timer and
/// returned, so the app only ever recovered when a human opened the popover.
@MainActor
struct AuthFailureReschedulingTests {

    @Test
    func testAuthenticationFailureSchedulesAnotherSessionAttempt() async throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMTEST"

        let coordinator = RefreshCoordinator(
            api: AuthFailingProvider(),
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readToken: { _ in "test-session" },
                                           readPassword: { nil }, clearPassword: {})
        )
        defer { coordinator.stop() }

        var resumed = false
        await withCheckedContinuation { continuation in
            coordinator.onEvent = { event in
                guard case .failed = event else { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            coordinator.start(preferredVIN: "YSMTEST")
        }

        #expect(coordinator.lastError != nil)
        #expect(coordinator.nextRefresh != nil, "an expired session must keep the retry loop alive")
    }
}

private actor AuthFailingProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? cars.first?.vin }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        throw PolestarError.authenticationRequired(.expiredSession)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
