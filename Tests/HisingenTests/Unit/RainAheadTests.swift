import Foundation
import Testing
@testable import Hisingen

@MainActor
struct RainAheadTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func interval(startingIn minutes: Double, millimetres: Double) -> PrecipitationInterval {
        PrecipitationInterval(start: Self.now.addingTimeInterval(minutes * 60), millimetres: millimetres)
    }

    // MARK: - Domain rule

    @Test("The first wet quarter hour inside the lookahead is the rain ahead")
    func firstWetQuarterHourWins() throws {
        let rain = try #require(RainAhead.next(in: [
            interval(startingIn: 0, millimetres: 0),
            interval(startingIn: 15, millimetres: 0.3),
            interval(startingIn: 30, millimetres: 1.2),
        ], after: Self.now))
        #expect(rain.startsAt == Self.now.addingTimeInterval(15 * 60))
        #expect(rain.millimetres == 0.3)
        #expect(rain.minutes(from: Self.now) == 15)
    }

    @Test("Rain beyond 45 minutes is not announced, and rain starting at 44 is")
    func lookaheadEdge() {
        #expect(RainAhead.next(in: [interval(startingIn: 45, millimetres: 1)], after: Self.now) == nil)
        #expect(RainAhead.next(in: [interval(startingIn: 44, millimetres: 1)], after: Self.now) != nil)
    }

    @Test("Under a tenth of a millimetre a quarter hour counts as dry")
    func drizzleBelowThresholdIsDry() {
        #expect(RainAhead.next(in: [interval(startingIn: 10, millimetres: 0.09)], after: Self.now) == nil)
        #expect(RainAhead.next(in: [interval(startingIn: 10, millimetres: 0.1)], after: Self.now) != nil)
    }

    @Test("A quarter hour that has already ended is ignored, one under way starts now")
    func pastAndCurrentQuarterHours() throws {
        #expect(RainAhead.next(in: [interval(startingIn: -15, millimetres: 2)], after: Self.now) == nil)
        let underWay = try #require(RainAhead.next(in: [interval(startingIn: -5, millimetres: 2)],
                                                   after: Self.now))
        #expect(underWay.startsAt == Self.now)
        #expect(underWay.minutes(from: Self.now) == 1)
    }

    @Test("Minutes round up so the notice is never early by a rounding")
    func minutesRoundUp() throws {
        let rain = try #require(RainAhead.next(in: [PrecipitationInterval(
            start: Self.now.addingTimeInterval(10 * 60 + 1), millimetres: 1)], after: Self.now))
        #expect(rain.minutes(from: Self.now) == 11)
    }

    @Test("No forecast gives no rain ahead")
    func emptyForecast() {
        #expect(RainAhead.next(in: [], after: Self.now) == nil)
    }

    // MARK: - Request and parsing

    @Test("The forecast request asks for the next quarter hours of precipitation")
    func requestAsksForMinutelyPrecipitation() throws {
        let url = try #require(OpenMeteoWeatherClient.hourlyForecastURL(latitude: 57.7089, longitude: 11.9746))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "minutely_15", value: "precipitation")))
        #expect(query.contains(URLQueryItem(name: "forecast_minutely_15", value: "6")))

        let current = try #require(OpenMeteoWeatherClient.openMeteoURL(latitude: 57.7089, longitude: 11.9746))
        let currentQuery = try #require(URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!currentQuery.contains { $0.name == "minutely_15" })
    }

    @Test("Each amount covers the quarter hour before its timestamp, read in the vehicle's zone")
    func minutelyResponseParses() throws {
        let json: [String: Any] = [
            "utc_offset_seconds": 3_600,
            "minutely_15": [
                "time": ["2026-11-23T08:15", "2026-11-23T08:30", "2026-11-23T08:45"],
                "precipitation": [0.0, NSNull(), 0.4],
            ],
        ]
        let intervals = try #require(OpenMeteoWeatherClient.minutelyPrecipitation(from: json))
        #expect(intervals.count == 2)
        // 08:15 local at UTC+1 is 07:15 UTC, and the amount covers 07:00 to 07:15.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let sevenUTC = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 7)))
        #expect(intervals[0].start == sevenUTC)
        #expect(intervals[0].end == sevenUTC.addingTimeInterval(15 * 60))
        #expect(intervals[1].start == sevenUTC.addingTimeInterval(30 * 60))
        #expect(intervals[1].millimetres == 0.4)
    }

    @Test("A response without a minutely block, or with nothing usable in it, is nil")
    func minutelyResponseWithoutUsableBlock() {
        #expect(OpenMeteoWeatherClient.minutelyPrecipitation(from: ["hourly": [:]]) == nil)
        #expect(OpenMeteoWeatherClient.minutelyPrecipitation(from: [
            "minutely_15": ["time": ["2026-11-23T08:15"], "precipitation": [NSNull()]],
        ]) == nil)
    }

    // MARK: - Notifier condition

    private func state(windowOpen: Bool, condition: String? = "Overcast",
                       upcoming: [PrecipitationInterval]?) -> VehicleState {
        let exterior = ExteriorSnapshot(
            openings: windowOpen ? [OpeningReading(opening: .frontLeftWindow, state: .open)] : [],
            isLocked: true, alarmTriggered: false)
        return vehicle(
            vin: "YS2P2000000000001", battery: 60, rangeKm: 300, chargingType: .none,
            modelYear: "2024", registrationNo: "TEST123", ownerFirstName: "Nico",
            odometerKm: 10_000, daysToService: 100, distanceToServiceKm: 5_000,
            exteriorStatus: exterior,
            weather: VehicleWeather(temperatureCelsius: 8, condition: condition, upcomingPrecipitation: upcoming),
            fetchedAt: Self.now, reportedAt: Self.now)
    }

    @Test("Rain ahead with a window open raises the condition")
    func conditionNeedsRainAndAnOpenWindow() {
        let rainy = [interval(startingIn: 15, millimetres: 0.5)]
        #expect(Notifier.rainAheadWithWindowsOpenCondition(state(windowOpen: true, upcoming: rainy), now: Self.now))
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(state(windowOpen: false, upcoming: rainy), now: Self.now))
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(
            state(windowOpen: true, upcoming: [interval(startingIn: 15, millimetres: 0)]), now: Self.now))
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(state(windowOpen: true, upcoming: nil), now: Self.now))
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(nil, now: Self.now))
    }

    @Test("Rain already falling is left to the existing alert")
    func currentRainIsNotRainAhead() {
        let state = state(windowOpen: true, condition: "Rain",
                          upcoming: [interval(startingIn: 15, millimetres: 0.5)])
        #expect(Notifier.rainWithWindowsOpenCondition(state))
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(state, now: Self.now))
    }

    @Test("A forecast that has run out by the time it is read stops raising the condition")
    func staleForecastExpires() {
        let rainy = [interval(startingIn: 15, millimetres: 0.5)]
        let later = Self.now.addingTimeInterval(60 * 60)
        #expect(!Notifier.rainAheadWithWindowsOpenCondition(state(windowOpen: true, upcoming: rainy), now: later))
    }
}
