import Foundation
import Testing
@testable import Hisingen

/// S16 — solar forecast from Open-Meteo radiation and live grid carbon from Electricity Maps.
/// The parsers are pinned against fixture payloads; every malformed or missing answer must
/// produce nil, never a substituted number.
@Suite("Solar forecast and grid carbon")
struct SolarAndGridCarbonTests {
    // MARK: - Solar

    private let solarJSON = """
    {
      "latitude": 57.7,
      "longitude": 11.9,
      "utc_offset_seconds": 3600,
      "timezone": "Europe/Stockholm",
      "hourly": {
        "time": ["2026-11-22T00:00", "2026-11-22T01:00", "2026-11-22T02:00", "2026-11-22T03:00"],
        "shortwave_radiation": [0.0, null, 120.5, 80.0]
      }
    }
    """

    @Test
    func parsesRadiationWithTheLocationsOffset() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(solarJSON.utf8)) as? [String: Any])
        let forecast = try #require(SolarForecastClient.forecast(from: json))

        // 00:00 local at +01:00 is 23:00Z the day before; the null hour is skipped, not zeroed.
        #expect(forecast.points.count == 3)
        #expect(forecast.points[0].time == Date(timeIntervalSince1970: 1_795_302_000))
        #expect(forecast.points[0].wattsPerSquareMeter == 0)
        #expect(forecast.points[1].wattsPerSquareMeter == 120.5)
        #expect(forecast.points[1].time == Date(timeIntervalSince1970: 1_795_309_200))
    }

    @Test
    func upcomingWindowCutsOldHoursAndPeakIsTheStrongest() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(solarJSON.utf8)) as? [String: Any])
        let forecast = try #require(SolarForecastClient.forecast(from: json))
        let now = Date(timeIntervalSince1970: 1_795_303_800) // 00:30 local

        let upcoming = forecast.upcoming(after: now)
        #expect(upcoming.count == 2)
        #expect(upcoming.allSatisfy { $0.time >= now })
        #expect(forecast.peak(after: now)?.wattsPerSquareMeter == 120.5)
    }

    @Test
    func aSolarAnswerWithoutUsableHoursIsNothing() {
        #expect(SolarForecastClient.forecast(from: [:]) == nil)
        #expect(SolarForecastClient.forecast(from: [
            "hourly": ["time": ["2026-11-22T00:00"], "shortwave_radiation": [NSNull()]]
        ]) == nil)
        #expect(SolarForecastClient.forecast(from: [
            "hourly": ["time": ["not-a-time"], "shortwave_radiation": [12.0]]
        ]) == nil)
    }

    @Test
    func solarURLAsksForTwoDaysOfHourlyRadiation() throws {
        let url = try #require(SolarForecastClient.url(latitude: 57.7, longitude: 11.9))
        #expect(url.host == "api.open-meteo.com")
        #expect(url.path == "/v1/forecast")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "hourly" && $0.value == "shortwave_radiation" })
        #expect(items.contains { $0.name == "forecast_days" && $0.value == "2" })
    }

    @Test
    func solarURLCarriesCoordinatesRoundedToTwoDecimals() throws {
        let url = try #require(SolarForecastClient.url(latitude: 57.708870123, longitude: 11.974559876))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "latitude" }?.value == "57.71")
        #expect(items.first { $0.name == "longitude" }?.value == "11.97")
        #expect(!url.absoluteString.contains("708870"))
        #expect(!url.absoluteString.contains("974559"))
    }

    @Test
    func roundingKeepsTheSignAndPadsToTwoDecimals() {
        #expect(SolarForecastClient.roundedCoordinate(-33.8688) == "-33.87")
        #expect(SolarForecastClient.roundedCoordinate(11.9) == "11.90")
        #expect(SolarForecastClient.roundedCoordinate(0) == "0.00")
    }

    @Test
    func theSolarCacheServesAnAnswerUntilItsLifetimeEnds() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = SolarForecast(points: [SolarForecastPoint(time: start, wattsPerSquareMeter: 120)])

        await cache.store(forecast, for: "gothenburg", now: start)

        let fresh = await cache.entry(for: "gothenburg", now: start.addingTimeInterval(29 * 60))
        #expect(fresh?.forecast == forecast)
        let stale = await cache.entry(for: "gothenburg", now: start.addingTimeInterval(31 * 60))
        #expect(stale == nil)
    }

    @Test
    func concurrentCallersForOneLocationShareASingleFetch() async {
        let cache = SolarForecastCache()
        let counter = FetchCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = SolarForecast(points: [SolarForecastPoint(time: start, wattsPerSquareMeter: 90)])

        async let first = cache.forecast(for: "gothenburg", now: start) {
            await counter.fetchOnce(returning: forecast)
        }
        async let second = cache.forecast(for: "gothenburg", now: start) {
            await counter.fetchOnce(returning: forecast)
        }
        let answers = await [first, second]

        #expect(answers == [forecast, forecast])
        #expect(await counter.count == 1)
    }

    @Test
    func expiredEntriesAreDroppedWhenAnotherLocationIsStored() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await cache.store(nil, for: "old-place", now: start)
        await cache.store(nil, for: "new-place", now: start.addingTimeInterval(10 * 60))

        #expect(await cache.entryCount == 1)
    }

    @Test
    func aFailedSolarAnswerIsRememberedBrieflyAndNotAsAForecast() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await cache.store(nil, for: "gothenburg", now: start)

        let held = await cache.entry(for: "gothenburg", now: start.addingTimeInterval(4 * 60))
        #expect(held != nil)
        #expect(held?.forecast == nil)
        let expired = await cache.entry(for: "gothenburg", now: start.addingTimeInterval(6 * 60))
        #expect(expired == nil)
    }

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

/// Counts the fetches a test's closure makes, and answers after a short pause so a second caller
/// has time to arrive while the first is still out.
private actor FetchCounter {
    private(set) var count = 0

    func fetchOnce(returning forecast: SolarForecast) async -> SolarForecast {
        count += 1
        try? await Task.sleep(for: .milliseconds(50))
        return forecast
    }
}
