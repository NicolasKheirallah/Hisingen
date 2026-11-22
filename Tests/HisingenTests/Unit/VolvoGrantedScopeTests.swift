import Foundation
import Testing
@testable import Hisingen

/// Per-scope Volvo grants: the token response's `scope` echo is parsed and recorded per
/// session, the `invalid_scope` cascade gets one drop-location retry, and the gates answer
/// per scope instead of from the whole opt-in flag. Every test here is fixture-driven –
/// no network, no live grants.
struct VolvoGrantedScopeTests {

    // MARK: - Token echo parsing

    @Test func parsesSpaceSeparatedScopeEcho() {
        let granted = VolvoAPI.parseGrantedScopes("conve:lock conve:unlock")
        #expect(granted == ["conve:lock", "conve:unlock"])
    }

    @Test func parsingToleratesRepeatedWhitespaceAndAbsence() {
        #expect(VolvoAPI.parseGrantedScopes("conve:lock  conve:unlock\nconve:honk_flash").count == 3)
        #expect(VolvoAPI.parseGrantedScopes("").isEmpty)
        #expect(VolvoAPI.parseGrantedScopes(nil).isEmpty)
    }

    @Test func tokenResponseDecodesGrantedScopeEcho() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":600,"token_type":"Bearer","scope":"conve:lock conve:unlock"}"#
        let dto = try JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: Data(json.utf8))
        #expect(dto.scope == "conve:lock conve:unlock")
    }

    @Test func tokenResponseWithoutScopeEchoStaysOptional() throws {
        // Some refresh grants omit the field; the record must survive it, so decoding has
        // to succeed with a nil echo rather than treat the key as required.
        let json = #"{"access_token":"at","expires_in":600}"#
        let dto = try JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: Data(json.utf8))
        #expect(dto.scope == nil)
    }

    // MARK: - hasGranted fallback rules

    @Test func hasGrantedFallsBackToNilWhenNothingRecorded() {
        // An empty set means a pre-per-scope session: callers must fall back to the opt-in
        // flag, so the answer is nil rather than false.
        #expect(VolvoAPI.hasGranted("conve:lock", in: []) == nil)
    }

    @Test func hasGrantedAnswersPerScopeFromTheRecordedSet() {
        let granted: Set<String> = ["conve:lock", "conve:honk_flash"]
        #expect(VolvoAPI.hasGranted("conve:lock", in: granted) == true)
        #expect(VolvoAPI.hasGranted("conve:honk_flash", in: granted) == true)
        #expect(VolvoAPI.hasGranted("conve:unlock", in: granted) == false)
        #expect(VolvoAPI.hasGranted("location:read", in: granted) == false)
    }

    // MARK: - Drop-location cascade scope lists

    @Test func restrictedScopeListKeepsAllFiveWhenWanted() {
        let full = VolvoAPI.restrictedScopeList(wanted: true, dropsLocation: false)
        #expect(full == VolvoAPI.restrictedScopes)
        #expect(full.contains("location:read"))
    }

    @Test func restrictedScopeListDropsOnlyLocationForTheRetry() {
        let dropped = VolvoAPI.restrictedScopeList(wanted: true, dropsLocation: true)
        #expect(dropped.count == VolvoAPI.restrictedScopes.count - 1)
        #expect(!dropped.contains("location:read"))
        #expect(dropped.contains("conve:lock"))
        #expect(dropped.contains("conve:unlock"))
        #expect(dropped.contains("conve:engine_start_stop"))
        #expect(dropped.contains("conve:honk_flash"))
    }

    @Test func restrictedScopeListIsEmptyWhenNotWanted() {
        #expect(VolvoAPI.restrictedScopeList(wanted: false, dropsLocation: false).isEmpty)
        #expect(VolvoAPI.restrictedScopeList(wanted: false, dropsLocation: true).isEmpty)
    }

    // MARK: - Command → scope mapping

    @Test func requiredScopeMapsEachRestrictedCommand() {
        #expect(VolvoAPI.requiredScope(for: .lock) == "conve:lock")
        #expect(VolvoAPI.requiredScope(for: .lockReducedGuard) == "conve:lock")
        #expect(VolvoAPI.requiredScope(for: .unlock) == "conve:unlock")
        #expect(VolvoAPI.requiredScope(for: .honkAndFlash) == "conve:honk_flash")
        #expect(VolvoAPI.requiredScope(for: .flashLights) == "conve:honk_flash")
        #expect(VolvoAPI.requiredScope(for: .honkHorn) == "conve:honk_flash")
        #expect(VolvoAPI.requiredScope(for: .startEngine(runtimeMinutes: 5)) == "conve:engine_start_stop")
        #expect(VolvoAPI.requiredScope(for: .stopEngine) == "conve:engine_start_stop")
        // Cabin climate is not approval-gated, so it must stay outside the mapping.
        #expect(VolvoAPI.requiredScope(for: .startClimate(
            temperatureCelsius: 20, frontLeftSeat: .off, frontRightSeat: .off,
            rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off)) == nil)
        #expect(VolvoAPI.requiredScope(for: .stopClimate) == nil)
    }

    // MARK: - CapabilityGate per-scope answers

    @MainActor
    private func makeState(vin: String) -> VehicleState {
        VehicleState(
            batteryPercentage: 80, rangeKm: nil, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: nil,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .none, chargerConnection: .disconnected,
            availability: .available, modelName: "Volvo XC40", modelYear: "2024",
            registrationNo: nil, vin: vin,
            ownerFirstName: nil, odometerKm: nil, imageData: nil,
            fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: [])
    }

    @MainActor
    private func gate(
        _ command: RemoteCommand, state: VehicleState,
        restrictedScopesEnabled: Bool, grantedScopes: Set<String>
    ) -> CommandAvailability {
        CapabilityGate.availability(
            for: command, state: state, brand: .volvo,
            polestarConnectionMode: .polestarID,
            enabledFeatures: [.remoteLocks, .remoteHonkFlash, .remoteClimate],
            commandInProgress: false,
            volvoRestrictedScopesEnabled: restrictedScopesEnabled,
            volvoGrantedScopes: grantedScopes)
    }

    /// The design's headline case: the account lacks `location:read` approval, but the
    /// other four restricted scopes were granted. Lock/unlock must stay available even
    /// though the whole opt-in flag reads false.
    @MainActor
    @Test func gateRefusesOnlyTheCommandsWhoseScopeIsMissing() {
        let state = makeState(vin: "YV1TESTVNN0000001")
        let granted: Set<String> = ["conve:lock", "conve:unlock", "conve:honk_flash", "conve:engine_start_stop"]
        #expect(gate(.lock, state: state, restrictedScopesEnabled: false, grantedScopes: granted) == .available)
        #expect(gate(.unlock, state: state, restrictedScopesEnabled: false, grantedScopes: granted) == .available)
        #expect(gate(.honkAndFlash, state: state, restrictedScopesEnabled: false, grantedScopes: granted) == .available)
        #expect(gate(.startEngine(runtimeMinutes: 5), state: state,
                     restrictedScopesEnabled: false, grantedScopes: granted) == .available)
    }

    @MainActor
    @Test func gateAnswersIndividuallyInsideOneGrantSet() {
        let state = makeState(vin: "YV1TESTVNN0000001")
        // Lock granted, unlock missing: the two rows of one card disagree, per scope.
        let granted: Set<String> = ["conve:lock"]
        #expect(gate(.lock, state: state, restrictedScopesEnabled: false, grantedScopes: granted) == .available)
        #expect(gate(.unlock, state: state, restrictedScopesEnabled: false, grantedScopes: granted) == .requiresAccountApproval)
    }

    @MainActor
    @Test func gateWithoutRecordedGrantsFallsBackToTheOptInFlag() {
        let state = makeState(vin: "YV1TESTVNN0000001")
        // Pre-per-scope session: the recorded set is empty and the flag decides, exactly
        // as before this feature.
        #expect(gate(.lock, state: state, restrictedScopesEnabled: false, grantedScopes: []) == .requiresAccountApproval)
        #expect(gate(.lock, state: state, restrictedScopesEnabled: true, grantedScopes: []) == .available)
    }

    @MainActor
    @Test func polestarGateIgnoresTheVolvoGrantInputs() {
        let state = makeState(vin: "PolestarTestVIN001")
        #expect(CapabilityGate.availability(
            for: .lock, state: state, brand: .polestar,
            polestarConnectionMode: .polestarID,
            enabledFeatures: [.remoteLocks],
            commandInProgress: false,
            volvoRestrictedScopesEnabled: false,
            volvoGrantedScopes: []) == .available)
    }

    // MARK: - Session recording and clearing

    @MainActor
    private func makeAPI(_ label: String) throws -> (VolvoAPI, PreferencesStore, String) {
        let suite = "VolvoGrantedScopeTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = PreferencesStore(defaults: defaults)
        let api = VolvoAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"),
            preferences: preferences)
        return (api, preferences, suite)
    }

    @MainActor
    @Test func actorHasGrantedReadsTheRecordedSet() async throws {
        let (api, preferences, suite) = try makeAPI("actor")
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        preferences.volvoGrantedScopes = ["conve:lock"]
        #expect(await api.hasGranted("conve:lock") == true)
        #expect(await api.hasGranted("conve:unlock") == false)
        preferences.volvoGrantedScopes = []
        #expect(await api.hasGranted("conve:lock") == nil)
    }

    @MainActor
    @Test func sessionResetClearsTheRecordedGrantSet() async throws {
        let (api, preferences, suite) = try makeAPI("reset")
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        preferences.volvoGrantedScopes = ["conve:lock", "location:read"]
        await api.resetSession()
        #expect(preferences.volvoGrantedScopes.isEmpty)
    }

    @MainActor
    @Test func beginSignInDropsLocationFromTheFullTierForTheRetry() async throws {
        let (api, preferences, suite) = try makeAPI("cascade")
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        preferences.volvoRestrictedScopesEnabled = true
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")

        func requestedScopes(dropsLocation: Bool) async throws -> Set<String> {
            let url = try await api.beginSignIn(tier: .full, dropsLocation: dropsLocation)
            let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value)
            return Set(raw.split(separator: " ").map(String.init))
        }

        let withLocation = try await requestedScopes(dropsLocation: false)
        #expect(withLocation.contains("location:read"))
        let withoutLocation = try await requestedScopes(dropsLocation: true)
        #expect(!withoutLocation.contains("location:read"))
        #expect(withoutLocation.contains("conve:lock"))
        #expect(withoutLocation.contains("conve:engine_start_stop"))
        // The retry narrows the request by exactly the location scope – nothing else.
        #expect(withLocation.subtracting(withoutLocation) == ["location:read"])
    }
}
