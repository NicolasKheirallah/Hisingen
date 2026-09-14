import Foundation

/// Third-party weather behind `.vehicleWeather`: Open-Meteo's free forecast API, keyed by
/// vehicle coordinates. Neither vehicle provider exposes a weather resource, so this client
/// is a deliberate, visible dependency rather than an HTTP call buried in gRPC capability
/// plumbing. Polestar's own weather reports reuse the same WMO code table.
struct OpenMeteoWeatherClient: Sendable {
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore

    func weather(latitude: Double, longitude: Double) async -> VehicleWeather? {
        guard let url = Self.openMeteoURL(latitude: latitude, longitude: longitude) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await HTTPExchange.data(
            for: request, using: session, limit: 256_000,
            operation: "Open-Meteo vehicle weather", provider: .polestar,
            diagnosticLog: diagnosticLog
        ), response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else { return nil }

        return VehicleWeather(
            temperatureCelsius: current["temperature_2m"] as? Double,
            condition: (current["weather_code"] as? Int).map(Self.wmoDescription),
            apparentTemperatureCelsius: current["apparent_temperature"] as? Double,
            relativeHumidity: current["relative_humidity_2m"] as? Int,
            timestamp: Date()
        )
    }

    static func openMeteoURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature")
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
