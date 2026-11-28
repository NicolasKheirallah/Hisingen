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

    private func forecast(at date: Date, celsius: Double,
                          windKmh: Double? = nil, gustsKmh: Double? = nil, precipitationMm: Double? = nil,
                          snowfallCm: Double? = nil, weatherCode: Int? = nil) -> [HourlyTemperature] {
        [HourlyTemperature(time: date, temperatureCelsius: celsius,
                           windSpeedKmh: windKmh, windGustsKmh: gustsKmh, precipitationMm: precipitationMm,
                           snowfallCm: snowfallCm, weatherCode: weatherCode)]
    }

    private func advice(schedules: [VehicleSchedule], climate: [VehicleSchedule] = [],
                         calendarDeparture: Date? = nil,
                         forecast: [HourlyTemperature], now: Date? = nil) -> DepartureWeatherAdvice? {
        DepartureWeatherAdvice.advice(schedules: schedules, climateTimers: climate,
                                      calendarDeparture: calendarDeparture, forecast: forecast,
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

    @Test("Rain at an uncovered departure advises climate")
    func rainWithoutClimateTimerAdvises() throws {
        let result = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                                            precipitationMm: 0.6)))
        #expect(result.departure == utcDate(2026, 11, 2, 7, 30))
        #expect(!result.needsClimateTimer)
        #expect(result.wet)
        #expect(!result.windy)
        #expect(!result.coldBattery)
        #expect(result.precipitationMm == 0.6)
    }

    @Test("A climate timer before a rainy departure covers it")
    func climateTimerCoversRain() {
        let result = advice(schedules: [departure()],
                            climate: [climateTimer(hour: 6, minute: 0)],
                            forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9, precipitationMm: 0.6))
        #expect(result == nil)
    }

    // The numbers below are the ones the readout's information button states, so a change to a
    // threshold has to change its explanation too.

    @Test("The coverage window ends exactly two hours before departure")
    func coverageWindowEndsTwoHoursBeforeDeparture() {
        // 07:30 departure: a 05:30 timer starts exactly two hours before it and covers the
        // frost; a 05:29 timer is a minute too early and does not.
        let covered = advice(schedules: [departure()],
                             climate: [climateTimer(hour: 5, minute: 30)],
                             forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2))
        #expect(covered == nil)

        let tooEarly = advice(schedules: [departure()],
                              climate: [climateTimer(hour: 5, minute: 29)],
                              forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2))
        #expect(tooEarly?.needsClimateTimer == true)
    }

    @Test("Freezing starts at exactly 0 °C and the wind line at exactly 40 km/h")
    func thresholdEdgesAreInclusive() throws {
        let atZero = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 0)))
        #expect(atZero.needsClimateTimer)

        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 0.1)) == nil)

        let atForty = try #require(advice(schedules: [departure()],
                                          forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                                             gustsKmh: 40)))
        #expect(atForty.windy)

        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                          gustsKmh: 39.9)) == nil)
    }

    @Test("A climate timer that covers the departure quiets the rain advice too")
    func coveredTimerQuietsFrostAndRainTogether() throws {
        // The timer starts inside the coverage lead before the 7:30 departure, so it covers
        // the glass; advising another timer for the rain would contradict the advice's own
        // wording ("a climate timer would warm the cabin") when one is already scheduled. The
        // wet road at -2 °C is a separate warning a timer cannot answer, so only that stays.
        let result = try #require(advice(schedules: [departure()],
                                         climate: [climateTimer(hour: 6, minute: 0)],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -2,
                                                            precipitationMm: 0.4)))
        #expect(!result.needsClimateTimer)
        #expect(!result.wet)
        #expect(result.icyRoad)
    }

    @Test("Wet roads at or below 1 °C are icy, and a climate timer does not quiet that")
    func wetNearFreezingIsIcy() throws {
        let atOne = try #require(advice(schedules: [departure()],
                                        climate: [climateTimer(hour: 6, minute: 0)],
                                        forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 1,
                                                           precipitationMm: 0.2)))
        #expect(atOne.icyRoad)

        // 1.1 °C and wet is only rain, which the covering timer quiets.
        #expect(advice(schedules: [departure()],
                       climate: [climateTimer(hour: 6, minute: 0)],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 1.1,
                                          precipitationMm: 0.2)) == nil)
    }

    @Test("Dry roads near freezing are not icy")
    func dryNearFreezingIsNotIcy() throws {
        let result = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -3,
                                                            precipitationMm: 0)))
        #expect(!result.icyRoad)
        #expect(result.needsClimateTimer)
    }

    @Test("Freezing rain and drizzle codes make the roads icy even without a rain amount")
    func freezingPrecipitationCodesAreIcy() throws {
        for code in [56, 57, 66, 67] {
            let result = try #require(advice(schedules: [departure()],
                                             forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 0.5,
                                                                weatherCode: code)))
            #expect(result.icyRoad)
        }
        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 3, weatherCode: 66)) == nil)
    }

    @Test("Snowfall in the departure hour is reported, and only when it falls")
    func snowfallIsReported() throws {
        let snowing = try #require(advice(schedules: [departure()],
                                          forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -4,
                                                             precipitationMm: 0.6, snowfallCm: 0.8)))
        #expect(snowing.snowfallCm == 0.8)
        let dry = try #require(advice(schedules: [departure()],
                                      forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: -4,
                                                         precipitationMm: 0.6, snowfallCm: 0)))
        #expect(dry.snowfallCm == nil)
    }

    @Test("Heat starts at exactly 28 °C and a covering climate timer quiets it")
    func hotDepartureAdvisesCooling() throws {
        let atLimit = try #require(advice(schedules: [departure()],
                                          forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 28)))
        #expect(atLimit.hot)
        #expect(!atLimit.needsClimateTimer)

        #expect(advice(schedules: [departure()],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 27.9)) == nil)
        #expect(advice(schedules: [departure()],
                       climate: [climateTimer(hour: 6, minute: 0)],
                       forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 31)) == nil)
    }

    @Test("Gusts at the strong-breeze line make the departure windy")
    func gustyDepartureIsWindy() throws {
        let result = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                                            windKmh: 20, gustsKmh: 45)))
        #expect(result.windy)
        #expect(!result.wet)
        #expect(result.windGustsKmh == 45)
    }

    @Test("Mean wind alone can make the departure windy")
    func steadyWindIsWindyWithoutGusts() throws {
        let result = try #require(advice(schedules: [departure()],
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9, windKmh: 42)))
        #expect(result.windy)
        #expect(result.windSpeedKmh == 42)
        #expect(result.windGustsKmh == nil)
    }

    @Test("Calm dry weather gives no advice even at a known departure")
    func calmDepartureIsSilent() {
        #expect(advice(schedules: [departure()],
                      forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                         windKmh: 30, gustsKmh: 35)) == nil)
    }

    @Test("The calendar preconditioning event is the departure when it comes first")
    func calendarDepartureIsUsedWhenEarlier() throws {
        let result = try #require(advice(schedules: [departure()],
                                         calendarDeparture: utcDate(2026, 11, 2, 7),
                                         forecast: forecast(at: utcDate(2026, 11, 2, 7), celsius: 9,
                                                            precipitationMm: 0.2)))
        #expect(result.departure == utcDate(2026, 11, 2, 7))
    }

    @Test("A vehicle departure earlier than the calendar event wins")
    func vehicleDepartureIsUsedWhenEarlier() throws {
        let result = try #require(advice(schedules: [departure(hour: 6, minute: 0)],
                                         calendarDeparture: utcDate(2026, 11, 2, 7),
                                         forecast: forecast(at: utcDate(2026, 11, 2, 6), celsius: -1)))
        #expect(result.departure == utcDate(2026, 11, 2, 6))
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

    @Test("Weather requests carry the position rounded to two decimals")
    func weatherURLsRoundTheCoordinates() throws {
        let precise = (latitude: 57.708870123, longitude: 11.974559876)
        for url in [
            OpenMeteoWeatherClient.openMeteoURL(latitude: precise.latitude, longitude: precise.longitude),
            OpenMeteoWeatherClient.hourlyForecastURL(latitude: precise.latitude, longitude: precise.longitude)
        ] {
            let query = try #require(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
            #expect(query.contains(URLQueryItem(name: "latitude", value: "57.71")))
            #expect(query.contains(URLQueryItem(name: "longitude", value: "11.97")))
            #expect(!(url?.absoluteString.contains("708870") ?? true))
        }
    }

    @Test("Current conditions URL does not request the hourly forecast")
    func currentURLIsUnchanged() throws {
        let url = try #require(OpenMeteoWeatherClient.openMeteoURL(latitude: 57.7089, longitude: 11.9746))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(
            name: "current",
            value: "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,precipitation"
        )))
        #expect(!query.contains { $0.name == "hourly" })
    }

    @Test("Forecast URL requests current conditions and two days of hourly Unix timestamps")
    func hourlyURLShape() throws {
        let url = try #require(OpenMeteoWeatherClient.hourlyForecastURL(latitude: 57.7089, longitude: 11.9746))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "api.open-meteo.com")
        #expect(components.path == "/v1/forecast")
        let query = try #require(components.queryItems)
        #expect(query.contains(URLQueryItem(name: "hourly",
                                            value: "temperature_2m,wind_speed_10m,wind_gusts_10m,precipitation,snowfall,weather_code")))
        #expect(query.contains(URLQueryItem(name: "forecast_days", value: "2")))
        #expect(query.contains(URLQueryItem(name: "timezone", value: "auto")))
        #expect(query.contains(URLQueryItem(name: "timeformat", value: "unixtime")))
        #expect(query.contains(URLQueryItem(name: "latitude", value: "57.71")))
        #expect(query.contains { $0.name == "current" })
    }

    @Test("Hourly timestamps stay aligned across the autumn clock change and null values")
    func hourlyResponseParsesAcrossAutumnClockChange() throws {
        let json: [String: Any] = [
            "utc_offset_seconds": 7_200,
            "hourly": [
                "time": [
                    utcDate(2026, 10, 25, 0, 0).timeIntervalSince1970,
                    utcDate(2026, 10, 25, 1, 0).timeIntervalSince1970,
                    utcDate(2026, 10, 25, 2, 0).timeIntervalSince1970,
                ],
                "temperature_2m": [-1.5, 2.0, NSNull()],
                "wind_speed_10m": [12.4, 8.1, 6.0],
                "wind_gusts_10m": [27.1, NSNull(), 9.4],
                "precipitation": [0.4, 0.0, NSNull()],
            ],
        ]
        let hours = try #require(OpenMeteoWeatherClient.hourlyTemperatures(from: json))
        #expect(hours.count == 2)
        #expect(hours[0].time == utcDate(2026, 10, 25, 0, 0))
        #expect(hours[0].temperatureCelsius == -1.5)
        #expect(hours[0].windSpeedKmh == 12.4)
        #expect(hours[0].windGustsKmh == 27.1)
        #expect(hours[0].precipitationMm == 0.4)
        #expect(hours[1].time == utcDate(2026, 10, 25, 1, 0))
        #expect(hours[1].windSpeedKmh == 8.1)
        #expect(hours[1].windGustsKmh == nil)
        #expect(hours[1].precipitationMm == 0)
    }

    @Test("Hourly response carries snowfall and the weather code per hour")
    func hourlyResponseParsesSnowAndCode() throws {
        let json: [String: Any] = [
            "utc_offset_seconds": 0,
            "hourly": [
                "time": [utcDate(2026, 11, 2, 7, 0).timeIntervalSince1970, utcDate(2026, 11, 2, 8, 0).timeIntervalSince1970],
                "temperature_2m": [-2.0, -1.0],
                "snowfall": [0.4, NSNull()],
                "weather_code": [71, 66],
            ],
        ]
        let hours = try #require(OpenMeteoWeatherClient.hourlyTemperatures(from: json))
        #expect(hours[0].snowfallCm == 0.4)
        #expect(hours[0].weatherCode == 71)
        #expect(hours[1].snowfallCm == nil)
        #expect(hours[1].weatherCode == 66)
    }

    @Test("Hourly response without wind or precipitation arrays keeps the hours")
    func hourlyResponseWithoutWindArrays() throws {
        let json: [String: Any] = [
            "utc_offset_seconds": 0,
            "hourly": [
                "time": [utcDate(2026, 11, 2, 7, 0).timeIntervalSince1970],
                "temperature_2m": [3.0],
            ],
        ]
        let hours = try #require(OpenMeteoWeatherClient.hourlyTemperatures(from: json))
        #expect(hours.count == 1)
        #expect(hours[0].windSpeedKmh == nil)
        #expect(hours[0].windGustsKmh == nil)
        #expect(hours[0].precipitationMm == nil)
        #expect(hours[0].snowfallCm == nil)
        #expect(hours[0].weatherCode == nil)
    }

    @Test("Hourly response without an hourly block is rejected")
    func hourlyResponseNeedsHourlyBlock() {
        #expect(OpenMeteoWeatherClient.hourlyTemperatures(from: ["current": [:]]) == nil)
    }
}
