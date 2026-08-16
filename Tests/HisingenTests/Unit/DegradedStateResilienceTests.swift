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
        XCTAssertTrue(expired.allowsAutomaticRetry)
        XCTAssertTrue(noSession.allowsAutomaticRetry)
        // These are not "transient" — the point is that retry eligibility is a separate question.
        XCTAssertFalse(expired.isTransient)
    }

    @Test
    func testErrorsNeedingOwnerActionStopTheLoop() {
        let badPassword = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .invalidCredentials)
        let extraStep = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .callbackRejected)
        XCTAssertFalse(badPassword.allowsAutomaticRetry)
        XCTAssertFalse(extraStep.allowsAutomaticRetry)
        XCTAssertFalse(VehicleServiceError.notConfigured.allowsAutomaticRetry)
        XCTAssertFalse(VehicleServiceError.secureStorage.allowsAutomaticRetry)
    }

    @Test
    func testTransientErrorsStillRetry() {
        XCTAssertTrue(VehicleServiceError.network(URLError(.timedOut)).allowsAutomaticRetry)
        XCTAssertTrue(VehicleServiceError.server(statusCode: 503).allowsAutomaticRetry)
        XCTAssertTrue(VehicleServiceError.rateLimited(retryAfter: nil).allowsAutomaticRetry)
    }

    @Test
    func testSessionRecoveryBacksOffHarderThanAPlainRefetch() {
        let refetch = RefreshPolicy.retryDelay(failureCount: 1, retryAfter: nil, requiresNewSession: false)
        let session = RefreshPolicy.retryDelay(failureCount: 1, retryAfter: nil, requiresNewSession: true)
        XCTAssertTrue(session > refetch)
        // An explicit Retry-After still wins over the session backoff.
        XCTAssertEqual(
            RefreshPolicy.retryDelay(failureCount: 4, retryAfter: 90, requiresNewSession: true), 90
        )
        // And the ceiling stays bounded no matter how many times we have failed.
        XCTAssertTrue(
            RefreshPolicy.retryDelay(failureCount: 99, retryAfter: nil, requiresNewSession: true) <= 1_800
        )
    }

    // MARK: - A field-level denial is not a dead session

    @Test
    func testFieldScopedAuthorizationErrorIsNotSessionDeath() {
        let fieldDenied = graphQLError(
            message: "Not authorized to access field", path: ["carTelematicsV2", "health"]
        )
        XCTAssertFalse(PolestarAPI.containsAuthenticationError([fieldDenied]))
    }

    @Test
    func testFieldScopedUnauthenticatedCodeIsNotSessionDeath() {
        let fieldDenied = graphQLError(
            message: "denied", path: ["carTelematicsV2", "battery"], code: "UNAUTHENTICATED"
        )
        XCTAssertFalse(PolestarAPI.containsAuthenticationError([fieldDenied]))
    }

    @Test
    func testTopLevelAuthenticationErrorIsStillSessionDeath() {
        XCTAssertTrue(PolestarAPI.containsAuthenticationError([
            graphQLError(message: "token has expired", path: [])
        ]))
        XCTAssertTrue(PolestarAPI.containsAuthenticationError([
            graphQLError(message: "nope", path: [], code: "UNAUTHENTICATED")
        ]))
    }

    // MARK: - The cache contract, made explicit

    @Test
    func testCacheableCopyDropsLiveTelemetryButKeepsIdentityAndCharge() {
        let full = stateWithFullTelemetry()
        let cached = full.cacheableCopy

        // Kept: identity, build specs, odometer, battery, options
        XCTAssertEqual(cached.vin, full.vin)
        XCTAssertEqual(cached.batteryPercentage, full.batteryPercentage)
        XCTAssertEqual(cached.rangeKm, full.rangeKm)
        XCTAssertEqual(cached.modelName, full.modelName)
        // Dropped for privacy: live GPS location coordinates, owner greeting, and registration plate
        XCTAssertNil(cached.location)
        XCTAssertNil(cached.ownerFirstName)
        XCTAssertNil(cached.registrationNo)
    }

    @Test
    func testSnapshotReadFromDiskIsFlaggedAsCached() throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VehicleStateStore(defaults: defaults)

        let live = stateWithFullTelemetry()
        XCTAssertFalse(live.isCachedSnapshot)
        store.save(live)

        let restored = try XCTUnwrap(store.snapshot(for: live.vin))
        XCTAssertTrue(restored.isCachedSnapshot)
        XCTAssertNil(restored.location)
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
        let oldVIN = Preferences.vin
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            Preferences.vin = oldVIN
            defaults.removePersistentDomain(forName: suiteName)
        }
        Preferences.vin = "YSMTEST"

        let coordinator = RefreshCoordinator(
            api: AuthFailingProvider(),
            stateStore: VehicleStateStore(defaults: defaults),
            observesEnvironment: false,
            clearPasswordAfterSession: {}
        )
        defer { coordinator.stop() }

        var resumed = false
        await withCheckedContinuation { continuation in
            coordinator.onError = { _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            coordinator.start(email: "test@example.invalid", password: nil,
                              sessionToken: "test-session", preferredVIN: "YSMTEST")
        }

        XCTAssertNotNil(coordinator.lastError)
        XCTAssertNotNil(coordinator.nextRefresh, "an expired session must keep the retry loop alive")
    }
}

private actor AuthFailingProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? cars.first?.vin }
    func selectCar(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        throw PolestarError.authenticationRequired(.expiredSession)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
