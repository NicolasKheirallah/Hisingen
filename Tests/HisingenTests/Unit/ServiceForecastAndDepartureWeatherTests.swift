import Foundation
import Testing
@testable import Hisingen

/// Service-date forecast, departure weather advice and the hourly Open-Meteo request. Every
/// clock and calendar is fixed here so the fixtures never depend on the wall clock or the
/// machine's time zone.
struct ServiceForecastAndDepartureWeatherTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Service forecast

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func sample(_ id: Int64, daysAgo: Double, odometerKm: Double) -> HistoryInsights.OdometerPoint {
        HistoryInsights.OdometerPoint(id: id, timestamp: now.addingTimeInterval(-daysAgo * 86_400),
                                      odometerKm: odometerKm)
    }

    @Test("Service forecast needs a remaining distance")
    func serviceForecastNeedsDistance() {
        let samples = [sample(1, daysAgo: 14, odometerKm: 10_000), sample(2, daysAgo: 0, odometerKm: 11_400)]
        #expect(ServiceForecast.estimate(distanceToServiceKm: nil, daysToService: 30,
                                         odometerSamples: samples, now: now) == nil)
        #expect(ServiceForecast.estimate(distanceToServiceKm: 0, daysToService: 30,
                                         odometerSamples: samples, now: now) == nil)
    }

    @Test("Service forecast needs at least seven days of samples")
    func serviceForecastNeedsSevenDays() {
        let samples = [sample(1, daysAgo: 5, odometerKm: 10_000), sample(2, daysAgo: 0, odometerKm: 10_500)]
        #expect(ServiceForecast.estimate(distanceToServiceKm: 1_500, daysToService: nil,
                                         odometerSamples: samples, now: now) == nil)
    }

    @Test("Service forecast needs kilometres driven, not just a span")
    func serviceForecastNeedsMovement() {
        let samples = [sample(1, daysAgo: 14, odometerKm: 10_000), sample(2, daysAgo: 0, odometerKm: 10_000)]
        #expect(ServiceForecast.estimate(distanceToServiceKm: 1_500, daysToService: nil,
                                         odometerSamples: samples, now: now) == nil)
    }

    @Test("Service forecast projects remaining distance at the observed rate")
    func serviceForecastProjectsDistance() throws {
        let samples = [sample(1, daysAgo: 14, odometerKm: 10_000), sample(2, daysAgo: 0, odometerKm: 11_400)]
        let forecast = try #require(ServiceForecast.estimate(distanceToServiceKm: 1_500, daysToService: nil,
                                                             odometerSamples: samples, now: now))
        #expect(abs(forecast.kmPerDay - 100) < 0.001)
        #expect(abs(forecast.dueDate.timeIntervalSince(now) - 15 * 86_400) < 1)
    }

    @Test("The time-based countdown caps the distance estimate when it is sooner")
    func serviceForecastTakesEarlierDate() throws {
        let samples = [sample(1, daysAgo: 14, odometerKm: 10_000), sample(2, daysAgo: 0, odometerKm: 11_400)]
        let forecast = try #require(ServiceForecast.estimate(distanceToServiceKm: 1_500, daysToService: 5,
                                                             odometerSamples: samples, now: now))
        #expect(abs(forecast.dueDate.timeIntervalSince(now) - 5 * 86_400) < 1)
    }

    @Test("Samples older than thirty days do not change the rate")
    func serviceForecastIgnoresOldSamples() throws {
        let samples = [
            sample(1, daysAgo: 40, odometerKm: 1_000),
            sample(2, daysAgo: 20, odometerKm: 10_000),
            sample(3, daysAgo: 0, odometerKm: 11_000),
        ]
        let forecast = try #require(ServiceForecast.estimate(distanceToServiceKm: 500, daysToService: nil,
                                                             odometerSamples: samples, now: now))
        #expect(abs(forecast.kmPerDay - 50) < 0.001)
        #expect(abs(forecast.dueDate.timeIntervalSince(now) - 10 * 86_400) < 1)
    }

    // MARK: - Departure weather advice

    private func departure(weekdays: [VehicleWeekday] = [.monday], hour: Int = 7, minute: Int = 30,
                           active: Bool = true, oneShot: Date? = nil) -> VehicleSchedule {
        VehicleSchedule(kind: .departure, startHour: hour, startMinute: minute, endHour: nil, endMinute: nil,
                        weekdays: weekdays, isActive: active, oneShotDate: oneShot)
    }

    private func climateTimer(weekdays: [VehicleWeekday] = [.monday], hour: Int, minute: Int = 0) -> VehicleSchedule {
        VehicleSchedule(kind: .climate, startHour: hour, startMinute: minute, endHour: nil, endMinute: nil,
                        weekdays: weekdays, isActive: true)
    }

    /// Sunday evening, so the Monday 07:30 departure is the next one.
    private var sundayEvening: Date { utcDate(2026, 11, 1, 20) }

    private func forecast(at date: Date, celsius: Double) -> [HourlyTemperature] {
        [HourlyTemperature(time: date, temperatureCelsius: celsius)]
    }

    private func advice(schedules: [VehicleSchedule], climate: [VehicleSchedule] = [],
                        forecast: [HourlyTemperature], now: Date? = nil) -> DepartureWeatherAdvice? {
        DepartureWeatherAdvice.advice(schedules: schedules, climateTimers: climate, forecast: forecast,
                                      now: now ?? sundayEvening, calendar: Self.utc)
    }

    @Test("Frost at an uncovered departure asks for a climate timer")
    func frostWithoutClimateTimerAsksForOne() throws {
        let departureTime = utcDate(2026, 11, 2, 7, 30)
        let result = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2)))
        #expect(result.departure == departureTime)
        #expect(result.needsClimateTimer)
        #expect(!result.coldBattery)
    }

    @Test("A climate timer that starts shortly before departure covers the frost")
    func climateTimerCoversFrost() {
        let result = advice(schedules: [departure()],
                            climate: [climateTimer(hour: 6, minute: 0)],
                            forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2))
        #expect(result == nil)
    }

    @Test("A climate timer too early before departure does not cover it")
    func earlyClimateTimerDoesNotCover() throws {
        let result = try #require(advice(schedules: [departure()],
                                         climate: [climateTimer(hour: 2, minute: 0)],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2)))
        #expect(result.needsClimateTimer)
    }

    @Test("Cold enough for the battery is reported even when a timer covers the glass")
    func coldBatteryReportedWhenCovered() throws {
        let result = try #require(advice(schedules: [departure()],
                                         climate: [climateTimer(hour: 6, minute: 0)],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -6)))
        #expect(!result.needsClimateTimer)
        #expect(result.coldBattery)
    }

    @Test("Above freezing gives no advice")
    func aboveFreezingIsSilent() {
        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 3)) == nil)
    }

    @Test("A forecast hour more than an hour from departure is not used")
    func distantForecastIsIgnored() {
        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 4), celsius: -8)) == nil)
    }

    @Test("Inactive departures and departures with no known day are ignored")
    func unusableDeparturesAreIgnored() {
        let frost = forecast(at: utcDate(2026, 11, 2, 7), celsius: -4)
        #expect(advice(schedules: [departure(active: false)], forecast: frost) == nil)
        #expect(advice(schedules: [departure(weekdays: [])], forecast: frost) == nil)
    }

    @Test("A one-shot departure is used on its date")
    func oneShotDepartureIsUsed() throws {
        let oneShot = utcDate(2026, 11, 2)
        let result = try #require(advice(schedules: [departure(weekdays: [], oneShot: oneShot)],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -1)))
        #expect(result.departure == utcDate(2026, 11, 2, 7, 30))
    }

    @Test("The next departure is the earliest upcoming occurrence")
    func nextDepartureIsEarliest() throws {
        // From Sunday evening, Monday 07:30 is sooner than Wednesday 06:00.
        let schedules = [departure(weekdays: [.wednesday], hour: 6, minute: 0), departure(weekdays: [.monday])]
        let result = try #require(advice(schedules: schedules,
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -1)))
        #expect(result.departure == utcDate(2026, 11, 2, 7, 30))
    }

    @Test("Occurrence skips weekdays the timer does not list")
    func occurrenceRespectsWeekdays() {
        // Sunday maps to VehicleWeekday.sunday (7), not to Monday's 1.
        let sundayOnly = departure(weekdays: [.sunday], hour: 9, minute: 0)
        let next = ScheduleOccurrence.next(of: sundayOnly, after: utcDate(2026, 11, 1, 8), calendar: Self.utc)
        #expect(next == utcDate(2026, 11, 1, 9, 0))
        let afterThat = ScheduleOccurrence.next(of: sundayOnly, after: utcDate(2026, 11, 1, 10), calendar: Self.utc)
        #expect(afterThat == utcDate(2026, 11, 8, 9, 0))
    }

    // MARK: - Hourly Open-Meteo request

    @Test("Current conditions URL does not request the hourly forecast")
    func currentURLIsUnchanged() throws {
        let url = try #require(OpenMeteoWeatherClient.openMeteoURL(latitude: 57.7089, longitude: 11.9746))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "current",
                                            value: "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature")))
        #expect(!query.contains { $0.name == "hourly" })
    }

    @Test("Forecast URL requests current conditions and two days of hourly temperature in local time")
    func hourlyURLShape() throws {
        let url = try #require(OpenMeteoWeatherClient.hourlyForecastURL(latitude: 57.7089, longitude: 11.9746))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "api.open-meteo.com")
        #expect(components.path == "/v1/forecast")
        let query = try #require(components.queryItems)
        #expect(query.contains(URLQueryItem(name: "hourly", value: "temperature_2m")))
        #expect(query.contains(URLQueryItem(name: "forecast_days", value: "2")))
        #expect(query.contains(URLQueryItem(name: "timezone", value: "auto")))
        #expect(query.contains(URLQueryItem(name: "latitude", value: "57.7089")))
        #expect(query.contains { $0.name == "current" })
    }

    @Test("Hourly response is read in the vehicle's zone and skips null readings")
    func hourlyResponseParsesWithOffset() throws {
        let json: [String: Any] = [
            "utc_offset_seconds": 3_600,
            "hourly": [
                "time": ["2026-11-02T07:00", "2026-11-02T08:00", "2026-11-02T09:00"],
                "temperature_2m": [-1.5, NSNull(), 2.0],
            ],
        ]
        let hours = try #require(OpenMeteoWeatherClient.hourlyTemperatures(from: json))
        #expect(hours.count == 2)
        #expect(hours[0].time == utcDate(2026, 11, 2, 6, 0))
        #expect(hours[0].temperatureCelsius == -1.5)
        #expect(hours[1].time == utcDate(2026, 11, 2, 8, 0))
    }

    @Test("Hourly response without an hourly block is rejected")
    func hourlyResponseNeedsHourlyBlock() {
        #expect(OpenMeteoWeatherClient.hourlyTemperatures(from: ["current": [:]]) == nil)
    }
}
