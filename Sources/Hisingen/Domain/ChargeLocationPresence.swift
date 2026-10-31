import Foundation

/// The saved charge location the vehicle is parked at, worked out from its latest reported
/// position and the coordinates of its saved locations. Only the match and the time the match
/// began are kept; no positions are stored.
struct ChargeLocationPresence: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Matched on this Mac from the vehicle position and the saved coordinates.
        case proximity
    }

    let locationID: String
    let alias: String
    /// When the vehicle's position first matched this location. Carried forward while the match
    /// holds, so a later refresh does not move it. `nil` when the position carried no timestamp.
    let since: Date?
    let source: Source

    /// Parking bays and charger pads sit within tens of metres of the saved point; 150 m leaves
    /// room for GPS drift at a parked car and for a large car park around a charger.
    static let matchRadiusMeters: Double = 150

    /// Nil when the position or every saved coordinate is missing. Saved locations without
    /// coordinates cannot be matched and are skipped, never treated as "not here".
    static func resolve(
        location: VehicleLocation?,
        locations: [ChargeLocationSnapshot],
        previous: ChargeLocationPresence?
    ) -> ChargeLocationPresence? {
        guard let location, let latitude = location.latitude, let longitude = location.longitude else {
            return nil
        }
        let candidates: [(spot: ChargeLocationSnapshot, distance: Double)] = locations.compactMap { spot in
            guard spot.isSavedLocation, let spotLatitude = spot.latitude, let spotLongitude = spot.longitude else {
                return nil
            }
            let distance = distanceMeters(latitude, longitude, spotLatitude, spotLongitude)
            return distance <= matchRadiusMeters ? (spot, distance) : nil
        }
        guard let match = candidates.min(by: { $0.distance < $1.distance })?.spot else { return nil }
        let since: Date?
        if let previous, previous.locationID == match.id {
            since = previous.since ?? location.timestamp
        } else {
            since = location.timestamp
        }
        return ChargeLocationPresence(locationID: match.id, alias: match.alias, since: since, source: .proximity)
    }

    /// Great-circle distance on a spherical Earth. Accurate to well under a metre at the
    /// 150 m scale this is used at.
    static func distanceMeters(_ latitude1: Double, _ longitude1: Double,
                               _ latitude2: Double, _ longitude2: Double) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let dLatitude = (latitude2 - latitude1) * .pi / 180
        let dLongitude = (longitude2 - longitude1) * .pi / 180
        let a = sin(dLatitude / 2) * sin(dLatitude / 2)
            + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180) * sin(dLongitude / 2) * sin(dLongitude / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(a)))
    }
}
