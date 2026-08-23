import Foundation
import CoreLocation
import OSLog

actor ReverseGeocoder {
    private let logger = AppLog.logger("geocoder")
    // Deliberately NOT recorded in APIDiagnosticLogStore: this goes through Apple's
    // CLGeocoder, not our HTTP transport — there is no request metadata to capture,
    // and coordinates must never enter a diagnostic artifact.
    private var cache: [String: String] = [:]
    private let geocoder = CLGeocoder()

    func geocode(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                var parts: [String] = []
                if let street = placemark.thoroughfare {
                    if let number = placemark.subThoroughfare {
                        parts.append("\(street) \(number)")
                    } else {
                        parts.append(street)
                    }
                } else if let name = placemark.name {
                    parts.append(name)
                }

                if let city = placemark.locality {
                    parts.append(city)
                }

                let formatted = parts.joined(separator: ", ")
                if !formatted.isEmpty {
                    cache[key] = formatted
                    return formatted
                }
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug("Reverse geocoding failed: \(error, privacy: .public)")
        }
        return nil
    }
}

