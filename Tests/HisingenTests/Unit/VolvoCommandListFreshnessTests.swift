import Foundation
import Testing
@testable import Hisingen

private let commandListVIN = "YV1CMDLIST0000001"

/// C20. The car's `/commands` list is what dims or offers lock, climate, engine and honk/flash,
/// so it is refreshed once it is older than the freshness window, and a refresh that fails keeps
/// the last known list and says it may be out of date instead of answering "no list".
@Suite("Volvo command list freshness", .serialized)
@MainActor
struct VolvoCommandListFreshnessTests {
    private let features = FeatureSelection(enabled: [.remoteLocks])

    @Test
    func weatherOptInUsesRoundedCoordinatesWithoutStoringTheLocation() async throws {
        let api = try await makeAPI()
        let withoutWeather = try await api.fetchVehicleState(
            vin: commandListVIN, features: FeatureSelection(enabled: []))
        #expect(withoutWeather.weather == nil)

        let withWeather = try await api.fetchVehicleState(
            vin: commandListVIN, features: FeatureSelection(enabled: [.vehicleWeather]))
        #expect(withWeather.weather?.temperatureCelsius == 7)
        #expect(withWeather.weather?.hourlyTemperatures?.first?.snowfallCm == 0.4)
        #expect(withWeather.weather?.upcomingPrecipitation?.first?.millimetres == 0.2)
        #expect(withWeather.location == nil)
        #expect(CommandListTransport.script.weatherFetchCount == 1)

        _ = try await api.fetchVehicleState(vin: commandListVIN, features: FeatureSelection(enabled: [.vehicleWeather]))
        #expect(CommandListTransport.script.weatherFetchCount == 1)
    }

    @Test
    func aFreshListIsReusedWithoutAskingTheProviderAgain() async throws {
        let api = try await makeAPI()
        CommandListTransport.script.serve(["lock", "unlock"])

        let first = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(first.probedCapabilities?.reportedCommandNames == ["lock", "unlock"])
        #expect(first.probedCapabilities?.support(for: .locks) == .supported)
        #expect(first.probedCapabilities?.commandListIsStale == false)
        #expect(CommandListTransport.script.commandFetchCount == 1)

        // Inside the window the list answers from the cache: the command budget stays untouched.
        let second = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(second.probedCapabilities?.support(for: .locks) == .supported)
        #expect(CommandListTransport.script.commandFetchCount == 1)
    }

    @Test
    func anAgedListIsRefreshedBeforeItGatesACommand() async throws {
        let api = try await makeAPI()
        CommandListTransport.script.serve(["lock", "unlock"])
        let first = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(first.probedCapabilities?.support(for: .locks) == .supported)

        // Past the window, and the car now reports a list without lock or unlock.
        await api.ageCommandList(vin: commandListVIN,
                                 by: VolvoAPI.commandListFreshnessWindow + 60)
        CommandListTransport.script.serve(["honk-flash"])

        let second = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(CommandListTransport.script.commandFetchCount == 2,
                "an aged list must be refreshed before it answers")
        // The refreshed list is the one that gates the control, not the cached one.
        #expect(second.probedCapabilities?.reportedCommandNames == ["honk-flash"])
        #expect(second.probedCapabilities?.support(for: .locks) == .unavailable)
        #expect(second.probedCapabilities?.commandListIsStale == false)
    }

    @Test
    func aFailedRefreshKeepsTheLastListAndMarksItStale() async throws {
        let api = try await makeAPI()
        CommandListTransport.script.serve(["lock", "unlock"])
        _ = try await api.fetchVehicleState(vin: commandListVIN, features: features)

        await api.ageCommandList(vin: commandListVIN,
                                 by: VolvoAPI.commandListFreshnessWindow + 60)
        CommandListTransport.script.fail(withStatus: 500)

        let degraded = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(CommandListTransport.script.commandFetchCount == 2, "the refresh was attempted")
        let probes = try #require(degraded.probedCapabilities)
        // The last known list still answers, and says why it might be out of date.
        #expect(probes.reportedCommandNames == ["lock", "unlock"])
        #expect(probes.commandListIsStale == true)
        #expect(probes.support(for: .locks) == .supported)
        #expect(degraded.capabilityProfile.support(for: .locks) == .supported)
        let availability = CapabilityGate.availability(
            for: .lock, state: degraded, brand: .volvo,
            polestarConnectionMode: .polestarID,
            enabledFeatures: [.remoteLocks], commandInProgress: false)
        #expect(availability == .available,
                "a failed refresh must not turn a supported command into an unsupported one")

        // While the endpoint stands down, the same last known list answers without another try.
        let stillDegraded = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        #expect(CommandListTransport.script.commandFetchCount == 2)
        #expect(stillDegraded.probedCapabilities?.commandListIsStale == true)
        #expect(stillDegraded.probedCapabilities?.support(for: .locks) == .supported)
    }

    @Test
    func aListThatWasNeverReadLeavesTheCommandAnswersToTheModelTable() async throws {
        let api = try await makeAPI()
        CommandListTransport.script.fail(withStatus: 404)

        let state = try await api.fetchVehicleState(vin: commandListVIN, features: features)
        // Nothing to keep, so nothing is claimed: not an empty command list, and not a stale one.
        #expect(state.probedCapabilities == nil)
        // And the gate still answers from the model table instead of refusing the control.
        let availability = CapabilityGate.availability(
            for: .lock, state: state, brand: .volvo,
            polestarConnectionMode: .polestarID,
            enabledFeatures: [.remoteLocks], commandInProgress: false)
        #expect(availability == .available)
    }

    // MARK: - Harness

    private func makeAPI() async throws -> VolvoAPI {
        let suite = "VolvoCommandListFreshnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let api = VolvoAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"),
            preferences: PreferencesStore(defaults: defaults),
            backoffs: ProviderBackoffStore(database: VehicleDatabase.inMemory())
        )
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        await api.useCommandListTransport()
        await api.seedRefreshToken("fake-stored-refresh-token")
        CommandListTransport.script.reset()
        return api
    }
}

private extension VolvoAPI {
    func useCommandListTransport() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandListTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }

    /// Seeds a stored refresh token so the sweep's first grant runs against the replay transport
    /// instead of the Keychain.
    func seedRefreshToken(_ token: String) {
        refreshToken = token
    }
}

/// Replays the Volvo endpoints the sweep needs and scripts the `/commands` list: which names it
/// reports, whether the read fails, and how often it was asked for.
private final class CommandListTransport: URLProtocol {
    static let script = CommandListScript()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host == "api.open-meteo.com" {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "vcc-api-key") == nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.contains(.init(name: "latitude", value: "57.71")) == true)
            #expect(items?.contains(.init(name: "longitude", value: "11.97")) == true)
        }
        let reply = Self.script.reply(for: url.path)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CommandListScript: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var failureStatus: Int?
    private var fetches = 0
    private var weatherFetches = 0

    var weatherFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return weatherFetches
    }

    var commandFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fetches
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        names = []
        failureStatus = nil
        fetches = 0
        weatherFetches = 0
    }

    func serve(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.names = names
        failureStatus = nil
    }

    func fail(withStatus status: Int) {
        lock.lock()
        defer { lock.unlock() }
        failureStatus = status
    }

    private static let commandsPath = "/connected-vehicle/v2/vehicles/\(commandListVIN)/commands"

    func reply(for path: String) -> (status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        if path.hasSuffix("token.oauth2") {
            return (200, #"{"access_token":"fake-access-token","refresh_token":"fake-refresh-token","expires_in":3600,"token_type":"Bearer"}"#)
        }
        if path == "/v1/forecast" {
            weatherFetches += 1
            return (200, """
            {"current":{"temperature_2m":7},"hourly":{"time":[1795417200],"temperature_2m":[7],"snowfall":[0.4]},
             "minutely_15":{"time":[1795418100],"precipitation":[0.2]}}
            """)
        }
        if path == "/location/v1/vehicles/\(commandListVIN)/location" {
            return (200, #"{"geometry":{"coordinates":[11.9746,57.7089]}}"#)
        }
        if path == Self.commandsPath {
            fetches += 1
            if let failureStatus { return (failureStatus, "{}") }
            let entries = names.map {
                #"{"command":"\#($0.uppercased())","href":"\#(Self.commandsPath)/\#($0)"}"#
            }
            return (200, #"{"data":[\#(entries.joined(separator: ","))]}"#)
        }
        if path == "/connected-vehicle/v2/vehicles/\(commandListVIN)" {
            return (200, #"{"vin":"\#(commandListVIN)","modelYear":2024}"#)
        }
        return (404, "{}")
    }
}
