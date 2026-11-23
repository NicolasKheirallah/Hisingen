import Foundation

/// Open-Meteo's air-quality forecast for one place, used for a single line in the weather readout.
/// It asks only for the index and fine particles, rounds the coordinates like every other
/// Open-Meteo request, and returns nil for every failure so a missing answer is never a guessed one.
struct OutdoorAirQualityClient: Sendable {
    let http: ThirdPartyHTTP
    let cache: OutdoorAirQualityCache

    init(session: URLSession = .shared,
         diagnosticLog: APIDiagnosticLogStore = .shared,
         cache: OutdoorAirQualityCache = .shared) {
        http = ThirdPartyHTTP(session: session, diagnosticLog: diagnosticLog)
        self.cache = cache
    }

    func current(latitude: Double, longitude: Double) async -> OutdoorAirQuality? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              let url = Self.url(latitude: latitude, longitude: longitude) else { return nil }
        let http = self.http
        return await cache.reading(for: url.absoluteString, now: Date()) {
            let json = await http.json(url, operation: "Open-Meteo air quality")
            return json.flatMap(Self.reading(from:))
        }
    }

    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "air-quality-api.open-meteo.com"
        components.path = "/v1/air-quality"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: OpenMeteoCoordinate.rounded(latitude)),
            URLQueryItem(name: "longitude", value: OpenMeteoCoordinate.rounded(longitude)),
            URLQueryItem(name: "current", value: "european_aqi,pm2_5")
        ]
        return components.url
    }

    /// Reads the `current` block. A null or negative figure is dropped rather than read as clean
    /// air, and an answer with neither figure is a failure.
    static func reading(from json: [String: Any]) -> OutdoorAirQuality? {
        guard let current = json["current"] as? [String: Any] else { return nil }
        let index = (current["european_aqi"] as? NSNumber).map(\.doubleValue)
            .flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
        let particles = (current["pm2_5"] as? NSNumber).map(\.doubleValue)
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard index != nil || particles != nil else { return nil }
        return OutdoorAirQuality(europeanAQI: index, particulateMatter25: particles)
    }
}

/// Remembers the last answer per rounded place for half an hour, and an outage for five minutes, so
/// opening the weather popover does not ask again each time. In memory only: where the car is
/// never reaches disk.
actor OutdoorAirQualityCache {
    static let shared = OutdoorAirQualityCache()

    struct Entry: Sendable {
        let reading: OutdoorAirQuality?
        let storedAt: Date
    }

    static let successLifetime: TimeInterval = 30 * 60
    static let failureLifetime: TimeInterval = 5 * 60

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<OutdoorAirQuality?, Never>] = [:]

    var entryCount: Int { entries.count }

    private static func isFresh(_ entry: Entry, at now: Date) -> Bool {
        let lifetime = entry.reading == nil ? failureLifetime : successLifetime
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < lifetime
    }

    /// The cached answer for `key`, or the answer of one fetch that every concurrent caller of the
    /// same key shares. Expired entries are dropped on every store, so a car that moves between
    /// places leaves no trail of old locations in memory.
    func reading(for key: String, now: Date,
                 fetch: @escaping @Sendable () async -> OutdoorAirQuality?) async -> OutdoorAirQuality? {
        if let entry = entries[key], Self.isFresh(entry, at: now) { return entry.reading }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await fetch() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        entries = entries.filter { Self.isFresh($0.value, at: now) }
        entries[key] = Entry(reading: result, storedAt: now)
        return result
    }
}
