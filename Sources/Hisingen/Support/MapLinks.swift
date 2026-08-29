import Foundation

/// Single home for Apple Maps deep links. Previously four call sites each interpolated
/// coordinates into URL strings with slightly different parameters and escaping.
enum MapLinks {
    /// Pin at explicit coordinates, optionally titled with `label`.
    static func appleMapsPin(latitude: Double, longitude: Double, label: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        var items: [URLQueryItem] = []
        if let label, !label.isEmpty {
            items.append(URLQueryItem(name: "q", value: label))
        }
        items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        components.queryItems = items
        return components.url
    }

    /// Driving directions between two explicit coordinates — used to replay a detected trip's
    /// start→end on the map rather than just dropping a pin at the finish.
    static func appleMapsDirections(fromLatitude: Double, fromLongitude: Double,
                                    toLatitude: Double, toLongitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "saddr", value: "\(fromLatitude),\(fromLongitude)"),
            URLQueryItem(name: "daddr", value: "\(toLatitude),\(toLongitude)"),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        return components.url
    }

    /// Search around an optional coordinate (vehicle-model lookup on the Info tab).
    static func appleMapsSearch(query: String, latitude: Double?, longitude: Double?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        var items: [URLQueryItem] = [URLQueryItem(name: "q", value: query)]
        if let latitude, let longitude {
            items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        }
        components.queryItems = items
        return components.url
    }
}
