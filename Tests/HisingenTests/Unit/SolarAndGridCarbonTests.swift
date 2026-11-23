import Foundation
import Testing
@testable import Hisingen

/// S16 — live grid carbon from Electricity Maps. The solar forecast half of this feature is
/// covered in SolarForecastTests. The parser is pinned against fixture payloads; every malformed
/// or missing answer must produce nil, never a substituted number.
@Suite("Grid carbon")
struct SolarAndGridCarbonTests {
    // MARK: - Grid carbon

    @Test
    func liveCarbonCoversOnlyTheSwedishMarket() {
        #expect(ElectricityMapsClient.covers(.sweden))
        #expect(!ElectricityMapsClient.covers(.other))
    }

    private let carbonJSON = """
    {
      "zone": "SE-SE3",
      "carbonIntensity": 42,
      "datetime": "2026-11-21T22:00:00Z",
      "updatedAt": "2026-11-21T22:05:00Z",
      "createdAt": "2026-11-21T22:05:00Z",
      "emissionFactorType": "lifecycle"
    }
    """

    @Test
    func parsesAReadingAndCarriesItsSource() throws {
        let reading = try #require(ElectricityMapsClient.reading(from: Data(carbonJSON.utf8), zone: .se3))

        #expect(reading.zone == "SE-SE3")
        #expect(reading.gramsCO2PerKwh == 42)
        #expect(reading.source == GridCarbonReading.electricityMapsSource)
        #expect(reading.source == "Electricity Maps")
        #expect(reading.observedAt == Date(timeIntervalSince1970: 1_795_298_700))
    }

    @Test
    func anErrorBodyOrMissingIntensityIsNothing() {
        let error = Data(#"{"error":"unauthorized"}"#.utf8)
        #expect(ElectricityMapsClient.reading(from: error, zone: .se3) == nil)
        let noIntensity = Data(#"{"zone":"SE-SE3","updatedAt":"2026-11-21T22:05:00Z"}"#.utf8)
        #expect(ElectricityMapsClient.reading(from: noIntensity, zone: .se3) == nil)
        let negative = Data(#"{"carbonIntensity":-4}"#.utf8)
        #expect(ElectricityMapsClient.reading(from: negative, zone: .se3) == nil)
        let notJSON = Data("not json".utf8)
        #expect(ElectricityMapsClient.reading(from: notJSON, zone: .se3) == nil)
    }

    @Test
    func zoneNamesAndURLFollowTheProviderContract() throws {
        #expect(ElectricityMapsClient.zoneID(for: .se3) == "SE-SE3")
        #expect(ElectricityMapsClient.zoneID(for: .se1) == "SE-SE1")
        let url = try #require(ElectricityMapsClient.url(zone: .se4))
        #expect(url.host == "api.electricitymap.org")
        #expect(url.path == "/v3/carbon-intensity/latest")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "zone" && $0.value == "SE-SE4" })
    }

    @Test @MainActor
    func theGridCarbonKeyIsOffByDefaultAndRoundTrips() throws {
        let scoped = ScopedPreferences(label: "GridCarbonKey")
        #expect(!scoped.store.hasElectricityMapsKey)
        #expect(try scoped.keychain.readElectricityMapsKey() == nil)

        try scoped.store.saveElectricityMapsKey("electricity-maps-test-token")
        #expect(scoped.store.hasElectricityMapsKey)
        #expect(try scoped.keychain.readElectricityMapsKey() == "electricity-maps-test-token")

        scoped.store.clearElectricityMapsKey()
        #expect(!scoped.store.hasElectricityMapsKey)
    }
}
