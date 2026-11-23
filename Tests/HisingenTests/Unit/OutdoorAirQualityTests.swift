import Foundation
import Testing
@testable import Hisingen

struct OutdoorAirQualityTests {
    @Test("Index bands end at 20, 40, 60, 80 and 100, and anything above 100 is extremely poor")
    func bandEdges() {
        let cases: [(Int, OutdoorAirQuality.Band)] = [
            (0, .good), (20, .good), (21, .fair), (40, .fair), (41, .moderate), (60, .moderate),
            (61, .poor), (80, .poor), (81, .veryPoor), (100, .veryPoor), (101, .extremelyPoor), (250, .extremelyPoor),
        ]
        for (index, band) in cases {
            #expect(OutdoorAirQuality.Band(index: index) == band, "index \(index)")
        }
    }

    @Test("No index means no band")
    func missingIndexHasNoBand() {
        #expect(OutdoorAirQuality(europeanAQI: nil, particulateMatter25: 4).band == nil)
        #expect(OutdoorAirQuality(europeanAQI: 32, particulateMatter25: nil).band == .fair)
    }

    @Test("The request goes to the air-quality host with the position rounded to two decimals")
    func requestShape() throws {
        let url = try #require(OutdoorAirQualityClient.url(latitude: 57.708870123, longitude: 11.974559876))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "air-quality-api.open-meteo.com")
        #expect(components.path == "/v1/air-quality")
        let query = try #require(components.queryItems)
        #expect(query.contains(URLQueryItem(name: "latitude", value: "57.71")))
        #expect(query.contains(URLQueryItem(name: "longitude", value: "11.97")))
        #expect(query.contains(URLQueryItem(name: "current", value: "european_aqi,pm2_5")))
        #expect(!url.absoluteString.contains("708870"))
    }

    @Test("The current block gives the index and fine particles")
    func parsesCurrentBlock() throws {
        let reading = try #require(OutdoorAirQualityClient.reading(from: [
            "current": ["european_aqi": 21, "pm2_5": 1.7],
        ]))
        #expect(reading.europeanAQI == 21)
        #expect(reading.particulateMatter25 == 1.7)
        #expect(reading.band == .fair)
    }

    @Test("A null or negative figure is dropped, not read as clean air")
    func dropsNullAndNegative() throws {
        let onlyParticles = try #require(OutdoorAirQualityClient.reading(from: [
            "current": ["european_aqi": NSNull(), "pm2_5": 6.0],
        ]))
        #expect(onlyParticles.europeanAQI == nil)
        #expect(onlyParticles.band == nil)

        let negative = try #require(OutdoorAirQualityClient.reading(from: [
            "current": ["european_aqi": -3, "pm2_5": 2.5],
        ]))
        #expect(negative.europeanAQI == nil)
    }

    @Test("An answer with neither figure, or no current block, is a failure")
    func failsWithoutFigures() {
        #expect(OutdoorAirQualityClient.reading(from: ["current": ["european_aqi": NSNull(), "pm2_5": NSNull()]]) == nil)
        #expect(OutdoorAirQualityClient.reading(from: ["hourly": [:]]) == nil)
    }

    @Test("Out-of-range coordinates make no request")
    func rejectsBadCoordinates() async {
        let client = OutdoorAirQualityClient(cache: OutdoorAirQualityCache())
        #expect(await client.current(latitude: 95, longitude: 10) == nil)
        #expect(await client.current(latitude: .nan, longitude: 10) == nil)
    }

    @Test("The cache answers a repeat from memory and shares one fetch between concurrent callers")
    func cacheServesRepeatsAndSharesFetches() async {
        let cache = OutdoorAirQualityCache()
        let counter = Counter()
        let reading = OutdoorAirQuality(europeanAQI: 30, particulateMatter25: 3)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetch: @Sendable () async -> OutdoorAirQuality? = {
            await counter.increment()
            return reading
        }
        async let first = cache.reading(for: "k", now: now, fetch: fetch)
        async let second = cache.reading(for: "k", now: now, fetch: fetch)
        _ = await (first, second)
        let third = await cache.reading(for: "k", now: now.addingTimeInterval(60), fetch: fetch)
        #expect(third == reading)
        #expect(await counter.value == 1)
    }

    @Test("A failure is remembered for five minutes and a success for half an hour")
    func cacheLifetimes() async {
        let cache = OutdoorAirQualityCache()
        let counter = Counter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failing: @Sendable () async -> OutdoorAirQuality? = { await counter.increment(); return nil }
        _ = await cache.reading(for: "k", now: now, fetch: failing)
        _ = await cache.reading(for: "k", now: now.addingTimeInterval(299), fetch: failing)
        #expect(await counter.value == 1)
        _ = await cache.reading(for: "k", now: now.addingTimeInterval(301), fetch: failing)
        #expect(await counter.value == 2)

        let good: @Sendable () async -> OutdoorAirQuality? = {
            await counter.increment()
            return OutdoorAirQuality(europeanAQI: 10, particulateMatter25: 1)
        }
        let later = now.addingTimeInterval(1_000)
        _ = await cache.reading(for: "g", now: later, fetch: good)
        _ = await cache.reading(for: "g", now: later.addingTimeInterval(1_799), fetch: good)
        #expect(await counter.value == 3)
        _ = await cache.reading(for: "g", now: later.addingTimeInterval(1_801), fetch: good)
        #expect(await counter.value == 4)
    }

    @Test("Old places are dropped when a new one is stored")
    func cacheDropsExpiredPlaces() async {
        let cache = OutdoorAirQualityCache()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = OutdoorAirQuality(europeanAQI: 10, particulateMatter25: 1)
        _ = await cache.reading(for: "home", now: now) { reading }
        _ = await cache.reading(for: "away", now: now.addingTimeInterval(3_600)) { reading }
        #expect(await cache.entryCount == 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
