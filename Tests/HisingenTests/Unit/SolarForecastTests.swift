import Foundation
import Testing
@testable import Hisingen

/// The solar forecast: Open-Meteo radiation parsed into the hours it describes, windowed and
/// totalled without a clock, cached with a stale fallback, and loaded only where the Vehicle
/// Weather setting allows. Every malformed or missing answer must produce nil, never a
/// substituted number.
@Suite("Solar forecast", .serialized)
struct SolarForecastTests {
    private static func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static func epoch(_ text: String) -> Int {
        Int(instant(text).timeIntervalSince1970)
    }

    private static func json(_ object: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any])
    }

    /// Four hourly stamps on a Stockholm winter day. Each stamp is the END of the hour its mean
    /// covers, so the first one describes 23:00-00:00 of the day before.
    private var winterAnswer: [String: Any] {
        get throws {
            try Self.json("""
            {
              "latitude": 57.7,
              "longitude": 11.9,
              "utc_offset_seconds": 3600,
              "timezone": "Europe/Stockholm",
              "hourly": {
                "time": [\(Self.epoch("2026-11-22T00:00:00+01:00")), \(Self.epoch("2026-11-22T01:00:00+01:00")),
                         \(Self.epoch("2026-11-22T02:00:00+01:00")), \(Self.epoch("2026-11-22T03:00:00+01:00"))],
                "shortwave_radiation": [0.0, null, 120.5, 80.0]
              }
            }
            """)
        }
    }

    // MARK: - Parsing

    @Test
    func parsesEachStampAsTheHourItEnds() throws {
        let forecast = try #require(SolarForecastClient.forecast(from: try winterAnswer))

        // The null hour is skipped, not zeroed.
        #expect(forecast.points.count == 3)
        #expect(forecast.points[0].start == Self.instant("2026-11-21T23:00:00+01:00"))
        #expect(forecast.points[0].end == Self.instant("2026-11-22T00:00:00+01:00"))
        #expect(forecast.points[0].wattsPerSquareMeter == 0)
        #expect(forecast.points[1].start == Self.instant("2026-11-22T01:00:00+01:00"))
        #expect(forecast.points[1].wattsPerSquareMeter == 120.5)
        #expect(forecast.timeZone.identifier == "Europe/Stockholm")
    }

    @Test
    func hoursStayExactAcrossASpringForwardChange() throws {
        // Stockholm skips 02:00-03:00 at 01:00Z on 2027-03-28. One UTC offset for the whole
        // answer would put every hour after that instant an hour off.
        let first = Self.epoch("2027-03-28T00:00:00Z")
        let stamps = (0..<4).map { first + $0 * 3_600 }
        let values = stamps.map { _ in "50.0" }.joined(separator: ",")
        let answer = try Self.json("""
        {"utc_offset_seconds": 3600, "timezone": "Europe/Stockholm",
         "hourly": {"time": \(stamps), "shortwave_radiation": [\(values)]}}
        """)
        let forecast = try #require(SolarForecastClient.forecast(from: answer))

        for (point, stamp) in zip(forecast.points, stamps) {
            #expect(point.end == Date(timeIntervalSince1970: TimeInterval(stamp)))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        // The hour that ended at 01:00Z began at 00:00Z (01:00 local); the next began at 01:00Z,
        // which is 03:00 local once the clocks have moved. 02:00 never happens that night.
        #expect(calendar.component(.hour, from: forecast.points[0].start) == 0)
        #expect(calendar.component(.hour, from: forecast.points[1].start) == 1)
        #expect(calendar.component(.hour, from: forecast.points[2].start) == 3)
    }

    @Test
    func timesThatArriveAsTextAreNotGuessedAt() throws {
        let answer = try Self.json("""
        {"timezone": "Europe/Stockholm",
         "hourly": {"time": ["2026-11-22T00:00"], "shortwave_radiation": [12.0]}}
        """)
        #expect(SolarForecastClient.forecast(from: answer) == nil)
    }

    @Test
    func aSolarAnswerWithoutUsableHoursIsNothing() {
        #expect(SolarForecastClient.forecast(from: [:]) == nil)
        #expect(SolarForecastClient.forecast(from: [
            "hourly": ["time": [1_800_000_000], "shortwave_radiation": [NSNull()]]
        ]) == nil)
        #expect(SolarForecastClient.forecast(from: [
            "hourly": ["time": [1_800_000_000], "shortwave_radiation": [-5.0]]
        ]) == nil)
        // More times than values: the unmatched hours are skipped.
        let short = SolarForecastClient.forecast(from: [
            "hourly": ["time": [1_800_000_000, 1_800_003_600], "shortwave_radiation": [10.0]]
        ])
        #expect(short?.points.count == 1)
    }

    @Test
    func aMissingZoneNameFallsBackToThisMacsZoneWithoutMovingAnyHour() throws {
        let answer = try Self.json("""
        {"hourly": {"time": [\(Self.epoch("2026-11-22T12:00:00Z"))], "shortwave_radiation": [90.0]}}
        """)
        let forecast = try #require(SolarForecastClient.forecast(from: answer))

        #expect(forecast.timeZone == .current)
        #expect(forecast.points[0].end == Self.instant("2026-11-22T12:00:00Z"))
    }

    // MARK: - Window, peak and day totals

    private func hours(from startText: String, watts: [Double]) -> [SolarForecastPoint] {
        let start = Self.instant(startText)
        return watts.enumerated().map { index, value in
            SolarForecastPoint(start: start.addingTimeInterval(TimeInterval(index) * 3_600), wattsPerSquareMeter: value)
        }
    }

    @Test
    func upcomingKeepsTheRunningHourAndDropsEndedOnes() {
        let forecast = SolarForecast(points: hours(from: "2026-11-22T10:00:00Z", watts: [10, 20, 30, 40]))
        let now = Self.instant("2026-11-22T11:30:00Z")

        let upcoming = forecast.upcoming(after: now)

        #expect(upcoming.map(\.wattsPerSquareMeter) == [20, 30, 40])
        #expect(upcoming.first?.start == Self.instant("2026-11-22T11:00:00Z"))
    }

    @Test
    func upcomingStopsAtTheHorizonAndReturnsOldestFirst() {
        let points = hours(from: "2026-11-22T10:00:00Z", watts: [10, 20, 30, 40]).reversed()
        let forecast = SolarForecast(points: Array(points))
        let now = Self.instant("2026-11-22T10:00:00Z")

        // An hour that starts exactly at the horizon is outside it.
        let upcoming = forecast.upcoming(after: now, horizon: 2 * 3_600)

        #expect(upcoming.map(\.wattsPerSquareMeter) == [10, 20])
    }

    @Test
    func peakIsTheStrongestHourAndItKeepsItsRange() {
        let forecast = SolarForecast(points: hours(from: "2026-11-22T09:00:00Z", watts: [10, 340, 120]))
        let now = Self.instant("2026-11-22T08:00:00Z")

        let peak = forecast.peak(after: now)

        #expect(peak?.wattsPerSquareMeter == 340)
        #expect(peak?.start == Self.instant("2026-11-22T10:00:00Z"))
        #expect(peak?.end == Self.instant("2026-11-22T11:00:00Z"))
        #expect(forecast.peak(after: Self.instant("2026-11-23T00:00:00Z")) == nil)
    }

    @Test
    func aDayTotalIsTheSumOfItsHoursInKilowattHoursPerSquareMetre() {
        let utc = TimeZone(identifier: "UTC")!
        let day = SolarForecast(points: hours(from: "2026-11-22T00:00:00Z", watts: Array(repeating: 100, count: 24)),
                                timeZone: utc)

        #expect(day.dailyTotalKwhPerSquareMeter(containing: Self.instant("2026-11-22T15:00:00Z")) == 2.4)
        #expect(day.dailyTotalKwhPerSquareMeter(containing: Self.instant("2026-11-23T15:00:00Z")) == nil)
    }

    @Test
    func aDayWithAGapInItsHoursHasNoTotalRatherThanASmallerOne() {
        let utc = TimeZone(identifier: "UTC")!
        var points = hours(from: "2026-11-22T00:00:00Z", watts: Array(repeating: 100, count: 24))
        points.remove(at: 12)
        let forecast = SolarForecast(points: points, timeZone: utc)

        #expect(forecast.dailyTotalKwhPerSquareMeter(containing: Self.instant("2026-11-22T12:00:00Z")) == nil)
    }

    @Test
    func theLastDayOfAnOutlookMayLackItsFinalHour() {
        let utc = TimeZone(identifier: "UTC")!
        let points = hours(from: "2026-11-23T00:00:00Z", watts: Array(repeating: 100, count: 23))
        let forecast = SolarForecast(points: points, timeZone: utc)

        let totals = forecast.dayTotals(at: Self.instant("2026-11-22T20:00:00Z"))

        #expect(totals.today == nil)
        #expect(totals.tomorrow == 2.3)
    }

    @Test
    func dayTotalsFollowThePlacesCalendarNotThisMacs() {
        // 23:30 UTC on the 22nd is already the 23rd in Auckland (UTC+13 in November).
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = auckland
        let midnight = calendar.startOfDay(for: Self.instant("2026-11-23T00:00:00Z"))
        let points = (0..<24).map {
            SolarForecastPoint(start: midnight.addingTimeInterval(TimeInterval($0) * 3_600), wattsPerSquareMeter: 50)
        }
        let forecast = SolarForecast(points: points, timeZone: auckland)

        #expect(forecast.dayTotals(at: Self.instant("2026-11-22T23:30:00Z")).today == 1.2)
    }

    // MARK: - Request

    @Test
    func solarURLAsksForTwoDaysOfHourlyRadiationInEpochSeconds() throws {
        let url = try #require(SolarForecastClient.url(latitude: 57.7, longitude: 11.9))
        #expect(url.host == "api.open-meteo.com")
        #expect(url.path == "/v1/forecast")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "hourly" && $0.value == "shortwave_radiation" })
        #expect(items.contains { $0.name == "forecast_days" && $0.value == "2" })
        #expect(items.contains { $0.name == "timeformat" && $0.value == "unixtime" })
        #expect(items.contains { $0.name == "timezone" && $0.value == "auto" })
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
    func theClientAsksOnceAndParsesTheAnswerEndToEnd() async throws {
        SolarStubTransport.reset(status: 200, body: """
        {"timezone": "Europe/Stockholm", "hourly": {"time": [1800000000, 1800003600], "shortwave_radiation": [10.0, 20.0]}}
        """)
        let client = Self.stubbedClient()

        let first = await client.forecast(latitude: 57.7089, longitude: 11.9746)
        let second = await client.forecast(latitude: 57.7089, longitude: 11.9746)

        #expect(first?.points.count == 2)
        #expect(second == first)
        #expect(SolarStubTransport.requests.count == 1)
        #expect(SolarStubTransport.requests.first?.contains("latitude=57.71") == true)
    }

    @Test
    func theClientSendsNothingForCoordinatesOutsideTheGlobe() async {
        SolarStubTransport.reset(status: 200, body: "{}")
        let client = Self.stubbedClient()

        #expect(await client.forecast(latitude: 91, longitude: 0) == nil)
        #expect(await client.forecast(latitude: 0, longitude: .nan) == nil)
        #expect(SolarStubTransport.requests.isEmpty)
    }

    @Test
    func anHTTPErrorIsNoForecast() async {
        SolarStubTransport.reset(status: 500, body: "{}")
        let client = Self.stubbedClient()

        #expect(await client.forecast(latitude: 57.7, longitude: 11.9) == nil)
    }

    private static func stubbedClient() -> SolarForecastClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SolarStubTransport.self]
        return SolarForecastClient(
            session: URLSession(configuration: configuration),
            diagnosticLog: APIDiagnosticLogStore(),
            cache: SolarForecastCache()
        )
    }

    // MARK: - Cache

    private func oneHourForecast(watts: Double, at start: Date) -> SolarForecast {
        SolarForecast(points: [SolarForecastPoint(start: start, wattsPerSquareMeter: watts)])
    }

    @Test
    func theSolarCacheServesAnAnswerUntilItsLifetimeEnds() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = oneHourForecast(watts: 120, at: start)

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
        let forecast = oneHourForecast(watts: 90, at: start)

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

    @Test
    func aFailedRefreshServesTheLastGoodForecastInsteadOfBlankingTheLine() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let good = oneHourForecast(watts: 200, at: start)
        await cache.store(good, for: "gothenburg", now: start)

        // The entry has expired, the provider fails, and the old forecast is still answered.
        let later = start.addingTimeInterval(40 * 60)
        let answer = await cache.forecast(for: "gothenburg", now: later) { nil }

        #expect(answer == good)
        let held = await cache.entry(for: "gothenburg", now: later.addingTimeInterval(60))
        #expect(held?.isStale == true)
        #expect(held?.forecast == good)
    }

    @Test
    func aStaleForecastIsRetriedAfterTheShortFailureLifetime() async {
        let cache = SolarForecastCache()
        let counter = FetchCounter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let good = oneHourForecast(watts: 200, at: start)
        let fresh = oneHourForecast(watts: 300, at: start.addingTimeInterval(3_600))
        await cache.store(good, for: "gothenburg", now: start)

        let failedAt = start.addingTimeInterval(40 * 60)
        _ = await cache.forecast(for: "gothenburg", now: failedAt) { nil }
        let retried = await cache.forecast(for: "gothenburg", now: failedAt.addingTimeInterval(6 * 60)) {
            await counter.fetchOnce(returning: fresh)
        }

        #expect(retried == fresh)
        #expect(await counter.count == 1)
    }

    @Test
    func aForecastOlderThanTheStaleWindowIsNotServedAfterAFailure() async {
        let cache = SolarForecastCache()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.store(oneHourForecast(watts: 200, at: start), for: "gothenburg", now: start)

        let answer = await cache.forecast(for: "gothenburg", now: start.addingTimeInterval(7 * 3_600)) { nil }

        #expect(answer == nil)
    }

    // MARK: - Panel array

    private func array(kwp: Double = 5, tilt: Double = 35, azimuth: Double = 0) -> SolarArray {
        SolarArray(kwp: kwp, tiltDegrees: tilt, azimuthDegrees: azimuth)!
    }

    @Test
    func anArrayNeedsAPositiveFiniteSizeAndIsClampedToTheProvidersRanges() {
        #expect(SolarArray(kwp: 0, tiltDegrees: 35, azimuthDegrees: 0) == nil)
        #expect(SolarArray(kwp: -3, tiltDegrees: 35, azimuthDegrees: 0) == nil)
        #expect(SolarArray(kwp: .nan, tiltDegrees: 35, azimuthDegrees: 0) == nil)
        #expect(SolarArray(kwp: 5, tiltDegrees: .infinity, azimuthDegrees: 0) == nil)

        let clamped = SolarArray(kwp: 500, tiltDegrees: 120, azimuthDegrees: -300)
        #expect(clamped?.kwp == 100)
        #expect(clamped?.tiltDegrees == 90)
        #expect(clamped?.azimuthDegrees == -180)
    }

    @Test
    func estimatedOutputIsSizeTimesTiltedRadiationTimesTheDisclosedEfficiency() {
        // 5 kWp at 400 W/m² on the panel plane, 80% system efficiency: 5 x 0.4 x 0.8.
        #expect(array(kwp: 5).estimatedKw(tiltedWattsPerSquareMeter: 400) == 1.6)
        #expect(array(kwp: 5).estimatedKw(tiltedWattsPerSquareMeter: 0) == 0)
        #expect(SolarArray.systemEfficiency == 0.8)
    }

    @Test
    func theRequestAsksForTiltedRadiationOnlyWhenThereIsAnArray() throws {
        let flat = try #require(SolarForecastClient.url(latitude: 57.7, longitude: 11.9))
        let flatItems = try #require(URLComponents(url: flat, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(flatItems.first { $0.name == "hourly" }?.value == "shortwave_radiation")
        #expect(!flatItems.contains { $0.name == "tilt" || $0.name == "azimuth" })

        let tilted = try #require(SolarForecastClient.url(
            latitude: 57.7, longitude: 11.9, array: array(kwp: 7.5, tilt: 40, azimuth: -15)))
        let items = try #require(URLComponents(url: tilted, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "hourly" }?.value == "shortwave_radiation,global_tilted_irradiance")
        #expect(items.first { $0.name == "tilt" }?.value == "40")
        #expect(items.first { $0.name == "azimuth" }?.value == "-15")
        // Only the two angles leave the Mac: the size of the array stays in Settings.
        #expect(!tilted.absoluteString.contains("7.5"))
        #expect(!tilted.absoluteString.lowercased().contains("kwp"))
    }

    @Test
    func tiltedHoursAreReadPerHourAndNeverTakenFromTheFlatFigure() throws {
        let first = Self.epoch("2026-11-22T10:00:00Z")
        let answer = try Self.json("""
        {"timezone": "UTC", "hourly": {
          "time": [\(first), \(first + 3600), \(first + 7200)],
          "shortwave_radiation": [100.0, 200.0, 300.0],
          "global_tilted_irradiance": [150.0, null, -4.0]
        }}
        """)
        let forecast = try #require(SolarForecastClient.forecast(from: answer))

        #expect(forecast.points.map(\.tiltedWattsPerSquareMeter) == [150, nil, nil])
        #expect(forecast.points.map(\.wattsPerSquareMeter) == [100, 200, 300])
    }

    @Test
    func anAnswerWithoutATiltedSeriesLeavesEveryTiltedHourNil() throws {
        let forecast = try #require(SolarForecastClient.forecast(from: try winterAnswer))

        #expect(forecast.points.allSatisfy { $0.tiltedWattsPerSquareMeter == nil })
    }

    @Test
    func aDayEstimateSumsTheTiltedHoursAndNeedsEveryOne() throws {
        let utc = TimeZone(identifier: "UTC")!
        let start = Self.instant("2026-11-22T00:00:00Z")
        func day(missing: Int?) -> SolarForecast {
            SolarForecast(points: (0..<24).map { hour in
                SolarForecastPoint(start: start.addingTimeInterval(TimeInterval(hour) * 3_600),
                                   wattsPerSquareMeter: 300,
                                   tiltedWattsPerSquareMeter: hour == missing ? nil : 500)
            }, timeZone: utc)
        }
        let panels = array(kwp: 4)
        let now = Self.instant("2026-11-22T12:00:00Z")

        // 4 kWp x 0.5 x 0.8 = 1.6 kW for 24 hours.
        let total = try #require(day(missing: nil).dayEstimates(at: now, array: panels).today)
        #expect(abs(total - 38.4) < 1e-9)
        #expect(day(missing: 11).dayEstimates(at: now, array: panels).today == nil)
        #expect(day(missing: nil).dayEstimates(at: now, array: panels).tomorrow == nil)
    }

    @Test
    func theLoaderPassesTheArrayToTheProvider() async {
        let provider = StubSolarProvider(answer: oneHourForecast(watts: 5, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let panels = array(kwp: 6, tilt: 30, azimuth: 20)

        _ = await SolarForecastLoader.load(
            vehicleWeatherEnabled: true, place: .vehicle(latitude: 57.7, longitude: 11.9),
            array: panels, provider: provider)

        #expect(provider.lastArray == panels)
    }

    @Test @MainActor
    func theArrayIsOffByDefaultKeepsItsSettingsInRangeAndStaysOutOfArchives() throws {
        let scoped = ScopedPreferences(label: "SolarArray")
        #expect(scoped.store.solarArray == nil)
        #expect(scoped.store.solarArrayTiltDegrees == 35)
        #expect(scoped.store.solarArrayAzimuthDegrees == 0)

        scoped.store.solarArrayKwp = 6.4
        scoped.store.solarArrayTiltDegrees = 27
        scoped.store.solarArrayAzimuthDegrees = -45
        #expect(scoped.store.solarArray == SolarArray(kwp: 6.4, tiltDegrees: 27, azimuthDegrees: -45))

        scoped.store.solarArrayKwp = 900
        scoped.store.solarArrayTiltDegrees = 200
        scoped.store.solarArrayAzimuthDegrees = 999
        #expect(scoped.store.solarArrayKwp == 100)
        #expect(scoped.store.solarArrayTiltDegrees == 90)
        #expect(scoped.store.solarArrayAzimuthDegrees == 180)

        scoped.store.solarArrayKwp = 0
        #expect(scoped.store.solarArray == nil)

        // The array describes one roof, so it is not part of a settings archive.
        scoped.store.solarArrayKwp = 6.4
        let archive = try scoped.store.exportSettingsPropertyList()
        let values = try #require(PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any])
        #expect(!values.keys.contains { $0.hasPrefix("solar_array") })
    }

    // MARK: - Axis and wording

    @Test
    func theAxisStartsAtZeroAndNeverShrinksBelowAFloorOfOneHundred() {
        let strong = SolarForecastChart.axis(peak: 340)
        #expect(strong.domain.lowerBound == 0)
        #expect(strong.ticks == [0, 100, 200, 300])
        #expect(strong.domain.upperBound > 340)

        let dull = SolarForecastChart.axis(peak: 20)
        #expect(dull.domain == 0...100)
        #expect(dull.ticks == [0, 50, 100])

        let bright = SolarForecastChart.axis(peak: 900)
        #expect(bright.ticks == [0, 250, 500, 750])
    }

    @Test @MainActor
    func anHourRangeNamesTheZoneOnlyWhenItDiffersFromThisMacs() {
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        let london = TimeZone(identifier: "Europe/London")!
        let point = SolarForecastPoint(start: Self.instant("2026-11-22T11:00:00Z"), wattsPerSquareMeter: 100)

        let same = SolarForecastChart.hourRange(point, zone: stockholm, deviceZone: stockholm)
        let other = SolarForecastChart.hourRange(point, zone: stockholm, deviceZone: london)

        #expect(same.contains("–"))
        #expect(other.hasPrefix(same))
        #expect(other.count > same.count)
    }

    // MARK: - Place and gate

    private func saved(_ id: String, alias: String, latitude: Double? = 57.7, longitude: Double? = 11.9) -> ChargeLocationSnapshot {
        ChargeLocationSnapshot(id: id, alias: alias, latitude: latitude, longitude: longitude, ampLimit: 0,
                               minimumSoc: 0, optimisedChargingEnabled: false, optimisedChargingMode: 0, kind: 2)
    }

    @Test
    func theChosenSavedLocationBeatsTheCarsPosition() {
        let place = SolarForecastLoader.place(
            vehicleLocation: VehicleLocation(latitude: 59.3, longitude: 18.0),
            savedLocations: [saved("home", alias: "Home", latitude: 57.7, longitude: 11.9)],
            chosenID: "home"
        )

        #expect(place == .saved(id: "home", alias: "Home", latitude: 57.7, longitude: 11.9))
    }

    @Test
    func aRemovedOrCoordinatelessChoiceFallsBackToTheCar() {
        let car = VehicleLocation(latitude: 59.3, longitude: 18.0)
        let removed = SolarForecastLoader.place(vehicleLocation: car, savedLocations: [], chosenID: "gone")
        let blank = SolarForecastLoader.place(
            vehicleLocation: car,
            savedLocations: [saved("home", alias: "Home", latitude: nil, longitude: nil)],
            chosenID: "home"
        )

        #expect(removed == .vehicle(latitude: 59.3, longitude: 18.0))
        #expect(blank == .vehicle(latitude: 59.3, longitude: 18.0))
    }

    @Test
    func noChoiceAndNoPositionIsNoPlace() {
        #expect(SolarForecastLoader.place(vehicleLocation: nil, savedLocations: [], chosenID: nil) == nil)
        #expect(SolarForecastLoader.place(vehicleLocation: VehicleLocation(latitude: nil, longitude: 5),
                                          savedLocations: [], chosenID: nil) == nil)
    }

    @Test
    func withVehicleWeatherOffNothingIsRequested() async {
        let provider = StubSolarProvider(answer: oneHourForecast(watts: 1, at: Date()))

        let outcome = await SolarForecastLoader.load(
            vehicleWeatherEnabled: false, place: .vehicle(latitude: 57.7, longitude: 11.9), provider: provider
        )

        #expect(outcome == .needsVehicleWeather)
        #expect(provider.calls == 0)
    }

    @Test
    func withoutAPlaceNothingIsRequested() async {
        let provider = StubSolarProvider(answer: oneHourForecast(watts: 1, at: Date()))

        let outcome = await SolarForecastLoader.load(vehicleWeatherEnabled: true, place: nil, provider: provider)

        #expect(outcome == .needsLocation)
        #expect(provider.calls == 0)
    }

    @Test
    func aFailedRequestIsUnavailableAndASuccessCarriesItsPlace() async {
        let place = SolarForecastPlace.vehicle(latitude: 57.7, longitude: 11.9)
        let failing = StubSolarProvider(answer: nil)
        let empty = StubSolarProvider(answer: SolarForecast(points: []))
        let forecast = oneHourForecast(watts: 5, at: Date(timeIntervalSince1970: 1_800_000_000))
        let working = StubSolarProvider(answer: forecast)

        #expect(await SolarForecastLoader.load(vehicleWeatherEnabled: true, place: place, provider: failing) == .unavailable)
        #expect(await SolarForecastLoader.load(vehicleWeatherEnabled: true, place: place, provider: empty) == .unavailable)
        #expect(await SolarForecastLoader.load(vehicleWeatherEnabled: true, place: place, provider: working)
                == .forecast(forecast, place))
        #expect(working.calls == 1)
        #expect(working.lastCoordinates?.latitude == 57.7)
    }

    @Test @MainActor
    func theForecastPlaceIsOffByDefaultRoundTripsAndStaysOutOfSettingsArchives() throws {
        let scoped = ScopedPreferences(label: "SolarForecastPlace")
        #expect(scoped.store.solarForecastLocationID == nil)

        scoped.store.solarForecastLocationID = "home"
        #expect(scoped.store.solarForecastLocationID == "home")

        // The identifier belongs to one account's backend, so it never travels in an archive.
        let archive = try scoped.store.exportSettingsPropertyList()
        let values = try #require(PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any])
        #expect(values["solar_forecast_location_id"] == nil)

        scoped.store.solarForecastLocationID = ""
        #expect(scoped.store.solarForecastLocationID == nil)
        scoped.store.solarForecastLocationID = "home"
        scoped.store.solarForecastLocationID = nil
        #expect(scoped.store.solarForecastLocationID == nil)
    }
}

private final class StubSolarProvider: SolarForecastProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: SolarForecast?
    private var callCount = 0
    private var coordinates: (latitude: Double, longitude: Double)?
    private var askedArray: SolarArray?

    init(answer: SolarForecast?) { self.answer = answer }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    var lastCoordinates: (latitude: Double, longitude: Double)? { lock.lock(); defer { lock.unlock() }; return coordinates }

    var lastArray: SolarArray? { lock.lock(); defer { lock.unlock() }; return askedArray }

    func forecast(latitude: Double, longitude: Double, array: SolarArray?) async -> SolarForecast? {
        record(latitude: latitude, longitude: longitude, array: array)
    }

    /// Synchronous, because a lock cannot be held across an async function's suspension points.
    private func record(latitude: Double, longitude: Double, array: SolarArray?) -> SolarForecast? {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        coordinates = (latitude, longitude)
        askedArray = array
        return answer
    }
}

/// Answers every request with one scripted status and body, and records each URL it was asked for.
private final class SolarStubTransport: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = "{}"
    nonisolated(unsafe) private static var asked: [String] = []

    static func reset(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.body = body; asked = []
    }

    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return asked }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.asked.append(request.url?.absoluteString ?? "")
        let status = Self.status, body = Self.body
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
