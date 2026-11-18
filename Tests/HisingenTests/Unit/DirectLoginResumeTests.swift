import Foundation
import Testing
@testable import Hisingen

private let root = "/third_party/openapi"

@MainActor
private final class Harness {
    let scoped = ScopedPreferences(label: "direct-login-resume")
    let transport = MockHomeAssistantTransport()
    let model: HomeChargingModel
    let store: HomeChargingStore

    init() {
        store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        transport.route("POST", root + "/account/refresh_token", .json(
            #"{"access_token":"renewed","expires_in":3600,"token_type":"Bearer"}"#))
        transport.route("GET", root + "/chargers", .json(#"{"data":[{"serial_number":"NX123","role":0}]}"#))
        let transport = transport
        model = HomeChargingModel(
            preferences: scoped.store, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, now: { Date(timeIntervalSince1970: 1_780_000_000) },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) },
                spotPrices: { _ in [] }, observesWake: false))
    }

    func pair(_ source: ChargerSource) {
        model.pair(HomeChargingPairing(
            baseURL: "", chargerID: "NX123", chargerName: "NexBlue NX123", entities: HomeChargerEntityMap(),
            vin: "YSMTEST", locationID: nil, locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm", source: source))
    }
}

@Suite("Resuming a direct charger login", .serialized)
@MainActor
struct DirectLoginResumeTests {
    @Test("A saved NexBlue login lists the chargers from the refresh token, with no password sent")
    func resumesFromTheRefreshToken() async throws {
        let harness = Harness()
        try harness.store.saveNexBlueRefreshToken("saved-refresh")
        #expect(harness.model.hasSavedCredentials(for: .nexBlue))

        let resumed = try await harness.model.resumeDirect(.nexBlue)
        let chargers = try #require(resumed)
        #expect(chargers.map(\.id) == ["NX123"])
        #expect(harness.transport.requests(path: root + "/account/login").isEmpty)
        let refresh = try #require(harness.transport.requests(path: root + "/account/refresh_token").first)
        let body = try #require(refresh.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["refresh_token"] as? String == "saved-refresh")
        #expect(harness.transport.requests(path: root + "/chargers").first?.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
    }

    @Test("With no saved login nothing is asked of the vendor")
    func nothingSavedMeansNoRequest() async throws {
        let harness = Harness()
        #expect(try await harness.model.resumeDirect(.nexBlue) == nil)
        #expect(try await harness.model.resumeDirect(.homeAssistant) == nil)
        #expect(harness.transport.requests(path: root + "/account/refresh_token").isEmpty)
        #expect(harness.transport.requests(path: root + "/chargers").isEmpty)
    }

    @Test("A refused token reports it and keeps the saved login for the reader to replace")
    func refusedTokenKeepsTheLogin() async throws {
        let harness = Harness()
        try harness.store.saveNexBlueRefreshToken("revoked")
        harness.transport.route("POST", root + "/account/refresh_token", .json(#"{"code":1502}"#, status: 400))
        await #expect(throws: DirectChargerError.unauthorized) { _ = try await harness.model.resumeDirect(.nexBlue) }
        #expect(harness.model.hasSavedCredentials(for: .nexBlue))
    }

    @Test("Signing out forgets a login that no charger is paired to")
    func signOutBeforePairing() throws {
        let harness = Harness()
        try harness.store.saveNexBlueRefreshToken("saved-refresh")
        harness.model.forgetDirectLogin(.nexBlue)
        #expect(!harness.model.hasSavedCredentials(for: .nexBlue))
    }

    @Test("A paired vendor keeps its login, because the pairing reads with it")
    func pairedLoginStays() throws {
        let harness = Harness()
        try harness.store.saveNexBlueRefreshToken("saved-refresh")
        harness.pair(.nexBlue)
        harness.model.forgetDirectLogin(.nexBlue)
        #expect(harness.model.hasSavedCredentials(for: .nexBlue))
        harness.model.stop()
    }
}
