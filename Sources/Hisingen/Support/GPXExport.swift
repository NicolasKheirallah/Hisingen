import Foundation

/// GPX 1.1 for the trip history. Each trip with a recorded start or end position becomes one
/// track segment; a trip with neither becomes no track at all, never a placeholder point at
/// 0,0. A trip with one recorded end contributes the one point it has.
enum GPXExport {
    private struct Point {
        var latitude: Double
        var longitude: Double
        var time: Date
    }

    static func data(trips: [TripHistoryEntry], vehicleName: String,
                     generatedAt: Date = Date()) -> Data {
        Data(document(trips: trips, vehicleName: vehicleName, generatedAt: generatedAt).utf8)
    }

    static func document(trips: [TripHistoryEntry], vehicleName: String,
                         generatedAt: Date = Date()) -> String {
        let title = L10n.format("%@ trip tracks", vehicleName)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Hisingen" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata>
        <name>\(XMLText.escape(title))</name>
        <time>\(Format.iso8601.string(from: generatedAt))</time>
        </metadata>

        """
        for trip in trips {
            let points = trackPoints(for: trip)
            guard !points.isEmpty else { continue }
            let name = trackName(for: trip)
            xml += "<trk>\n<name>\(XMLText.escape(name))</name>\n<trkseg>\n"
            for point in points {
                xml += "<trkpt lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\">"
                xml += "<time>\(Format.iso8601.string(from: point.time))</time></trkpt>\n"
            }
            xml += "</trkseg>\n</trk>\n"
        }
        xml += "</gpx>\n"
        return xml
    }

    private static func trackPoints(for trip: TripHistoryEntry) -> [Point] {
        var points: [Point] = []
        if let latitude = validLatitude(trip.startLatitude), let longitude = validLongitude(trip.startLongitude) {
            points.append(Point(latitude: latitude, longitude: longitude, time: trip.startedAt))
        }
        if let latitude = validLatitude(trip.endLatitude), let longitude = validLongitude(trip.endLongitude) {
            points.append(Point(latitude: latitude, longitude: longitude, time: trip.endedAt))
        }
        return points
    }

    private static func validLatitude(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-90...90).contains(value) else { return nil }
        return value
    }

    private static func validLongitude(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-180...180).contains(value) else { return nil }
        return value
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func trackName(for trip: TripHistoryEntry) -> String {
        L10n.format("Trip %@", Format.iso8601.string(from: trip.startedAt))
    }
}
