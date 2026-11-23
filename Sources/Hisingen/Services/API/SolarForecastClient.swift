import Foundation

/// What the solar line needs from a forecast source, so the loader can be tested without a network.
protocol SolarForecastProviding: Sendable {
    /// `array` adds the radiation on the reader's own panel plane to every hour; nil asks for flat
    /// radiation only.
    func forecast(latitude: Double, longitude: Double, array: SolarArray?) async -> SolarForecast?
}

extension SolarForecastProviding {
    func forecast(latitude: Double, longitude: Double) async -> SolarForecast? {
        await forecast(latitude: latitude, longitude: longitude, array: nil)
    }
}

/// Open-Meteo's hourly global shortwave radiation, used only as a visible forecast line beside
/// the charging plan. It is radiation at one place, not a production forecast: Hisingen knows
/// neither the panel array nor the inverter, and it will not invent either.
struct SolarForecastClient: SolarForecastProviding {
    let http: ThirdPartyHTTP
    let cache: SolarForecastCache

    init(session: URLSession = .shared,
         diagnosticLog: APIDiagnosticLogStore = .shared,
         cache: SolarForecastCache = .shared) {
        http = ThirdPartyHTTP(session: session, diagnosticLog: diagnosticLog)
        self.cache = cache
    }

    func forecast(latitude: Double, longitude: Double, array: SolarArray?) async -> SolarForecast? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              let url = Self.url(latitude: latitude, longitude: longitude, array: array)
        else { return nil }
        let http = self.http
        return await cache.forecast(for: url.absoluteString, now: Date()) {
            let json = await http.json(url, operation: "Open-Meteo solar forecast")
            return json.flatMap(Self.forecast(from:))
        }
    }

    /// The request's coordinates are rounded to two decimals, about a kilometre.
    static func roundedCoordinate(_ value: Double) -> String {
        OpenMeteoCoordinate.rounded(value)
    }

    /// With an array the request also asks for the radiation on a plane at the panels' tilt and
    /// direction. Only those two angles leave the Mac: the array's size never does.
    static func url(latitude: Double, longitude: Double, array: SolarArray? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        var hourly = "shortwave_radiation"
        var orientation: [URLQueryItem] = []
        if let array {
            hourly += ",global_tilted_irradiance"
            orientation = [
                URLQueryItem(name: "tilt", value: String(Int(array.tiltDegrees.rounded()))),
                URLQueryItem(name: "azimuth", value: String(Int(array.azimuthDegrees.rounded())))
            ]
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: roundedCoordinate(latitude)),
            URLQueryItem(name: "longitude", value: roundedCoordinate(longitude)),
            URLQueryItem(name: "hourly", value: hourly),
            URLQueryItem(name: "forecast_days", value: "2"),
            // Epoch seconds, so an hour is an exact instant even when the outlook crosses a
            // daylight-saving change; one UTC offset would be wrong for the hours after it.
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // Only names the place's zone, so the hours can be read on that place's clock.
            URLQueryItem(name: "timezone", value: "auto")
        ] + orientation
        return components.url
    }

    /// Parses the `hourly` block. Times arrive as epoch seconds and stamp the end of the hour each
    /// mean covers. A missing, null or non-numeric entry is skipped, never read as zero, and an
    /// answer with no usable hour is a failure (nil) so the caller draws nothing. A time that
    /// arrives as text means the answer is not in the format the request asked for, so it is
    /// skipped rather than guessed at.
    static func forecast(from json: [String: Any]) -> SolarForecast? {
        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Any],
              let values = hourly["shortwave_radiation"] as? [Any] else { return nil }
        let zone = (json["timezone"] as? String).flatMap { TimeZone(identifier: $0) } ?? .current
        let tilted = hourly["global_tilted_irradiance"] as? [Any]

        var points: [SolarForecastPoint] = []
        for (index, time) in times.enumerated() {
            guard index < values.count,
                  let stamp = (time as? NSNumber)?.doubleValue, stamp.isFinite,
                  let watts = (values[index] as? NSNumber)?.doubleValue,
                  watts.isFinite, watts >= 0
            else { continue }
            // A tilted-plane hour that is missing or null stays nil; it is never taken from the flat figure.
            let tiltedWatts = tilted.flatMap { index < $0.count ? ($0[index] as? NSNumber)?.doubleValue : nil }
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            points.append(SolarForecastPoint(
                start: Date(timeIntervalSince1970: stamp - SolarForecastPoint.interval),
                wattsPerSquareMeter: watts,
                tiltedWattsPerSquareMeter: tiltedWatts
            ))
        }
        return points.isEmpty ? nil : SolarForecast(points: points, timeZone: zone)
    }
}

/// Remembers the last forecast per rounded location, so the planner card does not ask Open-Meteo
/// again on every vehicle refresh. A failed answer is remembered for a shorter time, so an outage
/// is not retried every minute either, and while the provider fails the last good forecast keeps
/// being served for a few hours, so one bad refresh does not blank a line the reader was using.
/// The cache lives in memory only: nothing about where the car or the home is reaches disk.
actor SolarForecastCache {
    static let shared = SolarForecastCache()

    struct Entry: Sendable {
        let forecast: SolarForecast?
        let storedAt: Date
        /// True when `forecast` is an older good answer served because the refresh failed.
        var isStale = false
    }

    static let successLifetime: TimeInterval = 30 * 60
    static let failureLifetime: TimeInterval = 5 * 60
    /// How long a good forecast stays usable after its lifetime while refreshes fail. Every hour
    /// it covers has an end time, so the line only ever shows hours that have not passed.
    static let staleLifetime: TimeInterval = 6 * 3_600

    private var entries: [String: Entry] = [:]
    private var lastGood: [String: Entry] = [:]
    private var inFlight: [String: Task<SolarForecast?, Never>] = [:]

    var entryCount: Int { entries.count }

    private static func isFresh(_ entry: Entry, at now: Date) -> Bool {
        let lifetime = (entry.forecast == nil || entry.isStale) ? failureLifetime : successLifetime
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < lifetime
    }

    private static func isUsableStale(_ entry: Entry, at now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < staleLifetime
    }

    func entry(for key: String, now: Date) -> Entry? {
        guard let entry = entries[key] else { return nil }
        guard Self.isFresh(entry, at: now) else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    /// Drops every entry past its lifetime, so a car that moves between places does not leave a
    /// trail of old locations in memory.
    func store(_ forecast: SolarForecast?, for key: String, now: Date) {
        entries = entries.filter { Self.isFresh($0.value, at: now) }
        lastGood = lastGood.filter { Self.isUsableStale($0.value, at: now) }
        let entry = Entry(forecast: forecast, storedAt: now)
        entries[key] = entry
        if forecast != nil { lastGood[key] = entry }
    }

    /// The last good forecast for `key`, when one is still inside the stale window.
    func staleForecast(for key: String, now: Date) -> SolarForecast? {
        guard let entry = lastGood[key], Self.isUsableStale(entry, at: now) else { return nil }
        return entry.forecast
    }

    /// The cached answer for `key`, or the answer of one fetch that every concurrent caller of
    /// the same key shares. A planner card and a menu that both ask while the first request is
    /// still out send one request, not two. When the fetch fails and an earlier good forecast is
    /// still inside the stale window, that forecast is the answer, retried after the short
    /// failure lifetime.
    func forecast(for key: String, now: Date,
                  fetch: @escaping @Sendable () async -> SolarForecast?) async -> SolarForecast? {
        if let cached = entry(for: key, now: now) { return cached.forecast }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await fetch() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            store(result, for: key, now: now)
            return result
        }
        if let stale = staleForecast(for: key, now: now) {
            entries[key] = Entry(forecast: stale, storedAt: now, isStale: true)
            return stale
        }
        store(nil, for: key, now: now)
        return nil
    }
}

/// Where the radiation is forecast: the car's reported position, or one of the saved charge
/// locations the reader picked, so a car parked away from home still gets the sun over the place
/// it will charge.
enum SolarForecastPlace: Equatable, Sendable {
    case vehicle(latitude: Double, longitude: Double)
    case saved(id: String, alias: String, latitude: Double, longitude: Double)

    var latitude: Double {
        switch self {
        case .vehicle(let latitude, _), .saved(_, _, let latitude, _): return latitude
        }
    }

    var longitude: Double {
        switch self {
        case .vehicle(_, let longitude), .saved(_, _, _, let longitude): return longitude
        }
    }
}

/// What the planner card draws for the solar line. Every case but `forecast` leaves the chart out
/// and says why, so a missing line is never a silent gap.
enum SolarForecastOutcome: Equatable, Sendable {
    case forecast(SolarForecast, SolarForecastPlace)
    case needsVehicleWeather
    case needsLocation
    case unavailable
}

enum SolarForecastLoader {
    /// The chosen saved location when it still exists and has coordinates, otherwise the car's
    /// reported position. Nil when neither is known.
    static func place(vehicleLocation: VehicleLocation?,
                      savedLocations: [ChargeLocationSnapshot],
                      chosenID: String?) -> SolarForecastPlace? {
        if let chosenID,
           let spot = savedLocations.first(where: { $0.id == chosenID }),
           let latitude = spot.latitude, let longitude = spot.longitude {
            return .saved(id: spot.id, alias: spot.alias, latitude: latitude, longitude: longitude)
        }
        if let latitude = vehicleLocation?.latitude, let longitude = vehicleLocation?.longitude {
            return .vehicle(latitude: latitude, longitude: longitude)
        }
        return nil
    }

    /// The request sends a position to Open-Meteo, so it only happens with Vehicle Weather on.
    /// With it off nothing is asked and the outcome says which setting would bring the line back.
    static func load(vehicleWeatherEnabled: Bool,
                     place: SolarForecastPlace?,
                     array: SolarArray? = nil,
                     provider: some SolarForecastProviding) async -> SolarForecastOutcome {
        guard vehicleWeatherEnabled else { return .needsVehicleWeather }
        guard let place else { return .needsLocation }
        guard let forecast = await provider.forecast(latitude: place.latitude, longitude: place.longitude, array: array),
              !forecast.isEmpty else { return .unavailable }
        return .forecast(forecast, place)
    }
}
