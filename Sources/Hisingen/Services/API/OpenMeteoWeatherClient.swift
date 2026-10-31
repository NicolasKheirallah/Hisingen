import Foundation

/// Third-party weather behind `.vehicleWeather`: Open-Meteo's free forecast API, keyed by
/// vehicle coordinates. Neither vehicle provider exposes a weather resource, so this client
/// is a deliberate, visible dependency rather than an HTTP call buried in gRPC capability
/// plumbing. Polestar's own weather reports reuse the same WMO code table.
struct OpenMeteoWeatherClient: Sendable {
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore

    func weather(latitude: Double, longitude: Double) async -> VehicleWeather? {
        guard let url = Self.openMeteoURL(latitude: latitude, longitude: longitude),
              let json = await fetch(url, operation: "Open-Meteo vehicle weather") else { return nil }
        return Self.currentWeather(from: json)
    }

    /// Current conditions with the hourly forecast attached, from one request so the coordinates
    /// leave the Mac once per refresh. A response without a usable `hourly` block still returns
    /// the current reading, so the forecast can only add to what `weather` returns.
    func weatherWithForecast(latitude: Double, longitude: Double) async -> VehicleWeather? {
        guard let url = Self.hourlyForecastURL(latitude: latitude, longitude: longitude),
              let json = await fetch(url, operation: "Open-Meteo vehicle weather"),
              var current = Self.currentWeather(from: json) else { return nil }
        current.hourlyTemperatures = Self.hourlyTemperatures(from: json)
        return current
    }

    private func fetch(_ url: URL, operation: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await HTTPExchange.data(
            for: request, using: session, limit: 256_000,
            operation: operation, provider: .polestar,
            diagnosticLog: diagnosticLog
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
            timestamp: Date()
        )
    }

    static func hourlyForecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields),
            URLQueryItem(name: "hourly", value: "temperature_2m"),
            URLQueryItem(name: "forecast_days", value: "2"),
            // Local wall-clock times, so a 07:30 departure lines up with the forecast hour.
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components.url
    }

    /// Parses the `hourly` block. Open-Meteo gives wall-clock strings in the location's zone and
    /// reports that zone's offset, so the offset is subtracted to get an absolute instant.
    /// Missing or null readings are skipped rather than read as zero.
    static func hourlyTemperatures(from json: [String: Any]) -> [HourlyTemperature]? {
        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let values = hourly["temperature_2m"] as? [Any] else { return nil }
        let offsetSeconds = (json["utc_offset_seconds"] as? NSNumber)?.doubleValue ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        return zip(times, values).compactMap { time, value -> HourlyTemperature? in
            guard let celsius = (value as? NSNumber)?.doubleValue,
                  let wallClock = wallClockDate(time, calendar: calendar) else { return nil }
            return HourlyTemperature(time: wallClock.addingTimeInterval(-offsetSeconds), temperatureCelsius: celsius)
        }
    }

    /// Reads `yyyy-MM-ddTHH:mm` as if it were UTC. The caller applies the real offset.
    private static func wallClockDate(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "T" || $0 == "-" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 5 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3], minute: parts[4]))
    }

    private static let currentFields = "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature"

    static func openMeteoURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
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
