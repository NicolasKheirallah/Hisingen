import Foundation

/// Electricity Maps' live carbon intensity for one Swedish price zone. The reader supplies the
/// token: without one nothing is requested and nothing is drawn. The API's zone names are the
/// price areas with an `SE-` prefix (`SE-SE3` for SE3).
struct ElectricityMapsClient: Sendable {
    let http: ThirdPartyHTTP

    init(session: URLSession = .shared, diagnosticLog: APIDiagnosticLogStore = .shared) {
        http = ThirdPartyHTTP(session: session, diagnosticLog: diagnosticLog)
    }

    func carbonIntensity(zone: ElspotZone, apiKey: String) async -> GridCarbonReading? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = Self.url(zone: zone),
              let json = await http.json(
                url, headers: ["auth-token": key],
                operation: "Electricity Maps carbon intensity"
              )
        else { return nil }
        return Self.reading(from: json, zone: zone)
    }

    static func zoneID(for zone: ElspotZone) -> String { "SE-\(zone.rawValue)" }

    static func url(zone: ElspotZone) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.electricitymap.org"
        components.path = "/v3/carbon-intensity/latest"
        components.queryItems = [URLQueryItem(name: "zone", value: zoneID(for: zone))]
        return components.url
    }

    /// A reading needs a finite, non-negative `carbonIntensity`. Anything else — an error body,
    /// a 401, a missing field — is nil, and the caller leaves its line out rather than showing
    /// a number it cannot source.
    static func reading(from data: Data, zone: ElspotZone) -> GridCarbonReading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return reading(from: json, zone: zone)
    }

    static func reading(from json: [String: Any], zone: ElspotZone) -> GridCarbonReading? {
        guard let intensity = (json["carbonIntensity"] as? NSNumber)?.doubleValue,
              intensity.isFinite, intensity >= 0 else { return nil }
        let stamp = (json["updatedAt"] as? String) ?? (json["datetime"] as? String)
        return GridCarbonReading(
            zone: (json["zone"] as? String) ?? zoneID(for: zone),
            gramsCO2PerKwh: intensity,
            observedAt: stamp.flatMap(Format.iso8601.date(from:)),
            source: GridCarbonReading.electricityMapsSource
        )
    }
}
