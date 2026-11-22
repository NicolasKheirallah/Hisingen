import Foundation

/// Open-Meteo's hourly global shortwave radiation, used only as a visible forecast line beside
/// the charging plan. It is radiation at the car's coordinates, not a production forecast:
/// Hisingen knows neither the panel array nor the inverter, and it will not invent either.
struct SolarForecastClient: Sendable {
    let http: ThirdPartyHTTP
    let cache: SolarForecastCache

    init(session: URLSession = .shared,
         diagnosticLog: APIDiagnosticLogStore = .shared,
         cache: SolarForecastCache = .shared) {
        http = ThirdPartyHTTP(session: session, diagnosticLog: diagnosticLog)
        self.cache = cache
    }

    func forecast(latitude: Double, longitude: Double) async -> SolarForecast? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              let url = Self.url(latitude: latitude, longitude: longitude)
        else { return nil }
        let key = url.absoluteString
        if let cached = await cache.entry(for: key, now: Date()) { return cached.forecast }
        let json = await http.json(url, operation: "Open-Meteo solar forecast")
        let result = json.flatMap(Self.forecast(from:))
        await cache.store(result, for: key, now: Date())
        return result
    }

    /// The request's coordinates are rounded to two decimals, about a kilometre.
    static func roundedCoordinate(_ value: Double) -> String {
        OpenMeteoCoordinate.rounded(value)
    }

    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: roundedCoordinate(latitude)),
            URLQueryItem(name: "longitude", value: roundedCoordinate(longitude)),
            URLQueryItem(name: "hourly", value: "shortwave_radiation"),
            URLQueryItem(name: "forecast_days", value: "2"),
            // Local wall-clock hours, so the line's peak time reads like the clock on the wall.
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components.url
    }

    /// Parses the `hourly` block. Times arrive as local wall-clock strings plus the zone's offset;
    /// the offset is subtracted to get an absolute instant. A missing or null radiation entry is
    /// skipped, never read as zero, and an answer with no usable hour is a failure (nil) so the
    /// caller draws nothing.
    static func forecast(from json: [String: Any]) -> SolarForecast? {
        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let values = hourly["shortwave_radiation"] as? [Any] else { return nil }
        let offsetSeconds = (json["utc_offset_seconds"] as? NSNumber)?.doubleValue ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        var points: [SolarForecastPoint] = []
        for (index, time) in times.enumerated() {
            guard index < values.count,
                  let watts = (values[index] as? NSNumber)?.doubleValue,
                  watts.isFinite, watts >= 0,
                  let wallClock = OpenMeteoWeatherClient.wallClockDate(time, calendar: calendar)
            else { continue }
            points.append(SolarForecastPoint(
                time: wallClock.addingTimeInterval(-offsetSeconds),
                wattsPerSquareMeter: watts
            ))
        }
        return points.isEmpty ? nil : SolarForecast(points: points)
    }
}

/// Remembers the last forecast per rounded location, so the planner card does not ask Open-Meteo
/// again on every vehicle refresh. A failed answer is remembered for a shorter time, so an outage
/// is not retried every minute either.
actor SolarForecastCache {
    static let shared = SolarForecastCache()

    struct Entry: Sendable {
        let forecast: SolarForecast?
        let storedAt: Date
    }

    static let successLifetime: TimeInterval = 30 * 60
    static let failureLifetime: TimeInterval = 5 * 60

    private var entries: [String: Entry] = [:]

    func entry(for key: String, now: Date) -> Entry? {
        guard let entry = entries[key] else { return nil }
        let lifetime = entry.forecast == nil ? Self.failureLifetime : Self.successLifetime
        let age = now.timeIntervalSince(entry.storedAt)
        guard age >= 0, age < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    func store(_ forecast: SolarForecast?, for key: String, now: Date) {
        entries[key] = Entry(forecast: forecast, storedAt: now)
    }
}
