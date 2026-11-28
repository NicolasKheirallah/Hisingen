import Foundation

/// Third-party weather behind `.vehicleWeather`: Open-Meteo's free forecast API, keyed by
/// vehicle coordinates. Neither vehicle provider exposes a weather resource, so this client
/// is a deliberate, visible dependency rather than an HTTP call buried in gRPC capability
/// plumbing. Polestar's own weather reports reuse the same WMO code table.
struct OpenMeteoWeatherClient: Sendable {
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore
    var provider: VehicleBrand = .polestar

    func weather(latitude: Double, longitude: Double,
                 scope: VehicleLogScope) async -> VehicleWeather? {
        guard let url = Self.openMeteoURL(latitude: latitude, longitude: longitude),
              let json = await fetch(url, operation: "Open-Meteo vehicle weather", scope: scope)
        else { return nil }
        return Self.currentWeather(from: json)
    }

    /// Current conditions with the hourly forecast attached, from one request so the coordinates
    /// leave the Mac once per refresh. A response without a usable `hourly` block still returns
    /// the current reading, so the forecast can only add to what `weather` returns.
    func weatherWithForecast(latitude: Double, longitude: Double,
                             scope: VehicleLogScope) async -> VehicleWeather? {
        guard let url = Self.hourlyForecastURL(latitude: latitude, longitude: longitude),
              let json = await fetch(url, operation: "Open-Meteo vehicle weather", scope: scope),
              var current = Self.currentWeather(from: json) else { return nil }
        current.hourlyTemperatures = Self.hourlyTemperatures(from: json)
        current.upcomingPrecipitation = Self.minutelyPrecipitation(from: json)
        return current
    }

    private func fetch(_ url: URL, operation: String,
                       scope: VehicleLogScope) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await HTTPExchange.data(
            for: request, using: session, limit: 256_000,
            operation: operation, provider: provider,
            scope: scope, diagnosticLog: diagnosticLog
        ), response.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func currentWeather(from json: [String: Any]) -> VehicleWeather? {
        guard let current = json["current"] as? [String: Any] else { return nil }
        return VehicleWeather(
            temperatureCelsius: current["temperature_2m"] as? Double,
            condition: (current["weather_code"] as? Int).map(Self.wmoDescription),
            apparentTemperatureCelsius: current["apparent_temperature"] as? Double,
            relativeHumidity: current["relative_humidity_2m"] as? Int,
            windSpeedKmh: current["wind_speed_10m"] as? Double,
            windGustsKmh: current["wind_gusts_10m"] as? Double,
            precipitationMm: current["precipitation"] as? Double,
            timestamp: Date()
        )
    }

    static func hourlyForecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: OpenMeteoCoordinate.rounded(latitude)),
            URLQueryItem(name: "longitude", value: OpenMeteoCoordinate.rounded(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            URLQueryItem(name: "hourly", value: hourlyFields),
            // The next hour and a half of rain in quarter-hour steps, for the rain-ahead alert.
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: "6"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components.url
    }

    /// Parses epoch seconds so the two occurrences of a repeated local hour stay distinct.
    /// Missing or null readings are skipped rather than read as zero. Wind and precipitation
    /// arrive as further arrays aligned to `time`; an array the response omits leaves those
    /// fields nil rather than dropping the hour.
    static func hourlyTemperatures(from json: [String: Any]) -> [HourlyTemperature]? {
        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Any],
              let values = hourly["temperature_2m"] as? [Any] else { return nil }
        let windSpeeds = hourly["wind_speed_10m"] as? [Any]
        let windGusts = hourly["wind_gusts_10m"] as? [Any]
        let precipitation = hourly["precipitation"] as? [Any]
        let snowfall = hourly["snowfall"] as? [Any]
        let weatherCodes = hourly["weather_code"] as? [Any]

        var hours: [HourlyTemperature] = []
        for (index, time) in times.enumerated() {
            guard index < values.count,
                  let celsius = (values[index] as? NSNumber)?.doubleValue,
                  let timestamp = forecastTimestamp(time) else { continue }
            hours.append(HourlyTemperature(
                time: timestamp,
                temperatureCelsius: celsius,
                windSpeedKmh: alignedHourlyValue(at: index, in: windSpeeds),
                windGustsKmh: alignedHourlyValue(at: index, in: windGusts),
                precipitationMm: alignedHourlyValue(at: index, in: precipitation),
                snowfallCm: alignedHourlyValue(at: index, in: snowfall),
                weatherCode: alignedHourlyValue(at: index, in: weatherCodes).map { Int($0) }
            ))
        }
        return hours
    }

    /// Parses the `minutely_15` block. Each amount is the sum of the 15 minutes before its
    /// timestamp, so the stretch it covers starts a quarter hour earlier. A null reading is skipped
    /// rather than read as dry, and a block with no usable step is nil.
    static func minutelyPrecipitation(from json: [String: Any]) -> [PrecipitationInterval]? {
        guard let block = json["minutely_15"] as? [String: Any],
              let times = block["time"] as? [Any],
              let values = block["precipitation"] as? [Any] else { return nil }
        var intervals: [PrecipitationInterval] = []
        for (index, time) in times.enumerated() {
            guard index < values.count,
                  let millimetres = (values[index] as? NSNumber)?.doubleValue,
                  millimetres.isFinite, millimetres >= 0,
                  let timestamp = forecastTimestamp(time) else { continue }
            intervals.append(PrecipitationInterval(
                start: timestamp.addingTimeInterval(-PrecipitationInterval.length),
                millimetres: millimetres))
        }
        return intervals.isEmpty ? nil : intervals
    }

    /// An aligned hourly reading, nil when the response left the array or the entry out.
    private static func alignedHourlyValue(at index: Int, in values: [Any]?) -> Double? {
        guard let values, index < values.count else { return nil }
        return (values[index] as? NSNumber)?.doubleValue
    }

    private static func forecastTimestamp(_ value: Any) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Wind and precipitation ride the same requests as temperature: Open-Meteo's forecast
    /// endpoint accepts them in both the `current` and the `hourly` block, in km/h and mm. The
    /// hourly block also carries snowfall (cm) and the WMO code, which the departure advice reads
    /// for road ice and snow.
    private static let currentFields =
        "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,precipitation"
    private static let hourlyFields =
        "temperature_2m,wind_speed_10m,wind_gusts_10m,precipitation,snowfall,weather_code"

    static func openMeteoURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: OpenMeteoCoordinate.rounded(latitude)),
            URLQueryItem(name: "longitude", value: OpenMeteoCoordinate.rounded(longitude)),
            URLQueryItem(name: "current", value: currentFields)
        ]
        return components.url
    }

    /// WMO weather-interpretation codes, shared with the Polestar weather report parser.
    static func wmoDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow Grains"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Partly Cloudy"
        }
    }
}

/// The one place an Open-Meteo request gets its coordinates. Weather and radiation are modelled on
/// a grid several kilometres wide, so two decimals (about a kilometre) lose nothing, and the car's
/// exact position stays out of the request.
enum OpenMeteoCoordinate {
    static func rounded(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded() / 100)
    }
}
