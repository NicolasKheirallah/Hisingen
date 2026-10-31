import Foundation

// Layouts follow the public unofficial-polestar-api client.
enum PolestarLocationWeatherCodec {
    static func location(_ data: Data) -> VehicleLocation? {
        guard let fields = try? Protobuf.decode(data) else { return nil }
        let compact = compactLocation(fields)
        let shifted: VehicleLocation? = {
            guard let lon = number(fields, 2), let lat = number(fields, 3), valid(lat, lon) else { return nil }
            let date = field(fields, 4, 0).map { Date(timeIntervalSince1970: Double(Int64(bitPattern: $0.varint))) }
            return VehicleLocation(latitude: lat, longitude: lon, timestamp: date)
        }()
        var wrapped: [(Int, VehicleLocation)] = []
        for number in [2, 5] {
            if let payload = field(fields, number, 2)?.data {
                guard let nested = try? Protobuf.decode(payload) else { return nil }
                if let result = compactLocation(nested) { wrapped.append((number, result)) }
            }
        }
        guard wrapped.count <= 1 else { return nil }
        if let (number, nested) = wrapped.first, let shifted {
            guard compact == nil, number == 5, shifted.latitude == nested.latitude,
                  shifted.longitude == nested.longitude else { return nil }
            return nested
        }
        let candidates = [compact, shifted, wrapped.first?.1].compactMap { $0 }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func compactLocation(_ fields: [Protobuf.Field]) -> VehicleLocation? {
        guard let lon = number(fields, 1), let lat = number(fields, 2), valid(lat, lon) else { return nil }
        var date: Date?
        if let timestamp = field(fields, 3, 2) {
            guard let parts = try? Protobuf.decode(timestamp.data) else { return nil }
            guard !parts.contains(where: { ($0.number == 1 || $0.number == 2) && $0.wire != 0 }) else { return nil }
            let seconds = Int64(bitPattern: field(parts, 1, 0)?.varint ?? 0)
            let nanos = field(parts, 2, 0)?.varint ?? 0
            guard nanos < 1_000_000_000 else { return nil }
            date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        } else if let seconds = field(fields, 3, 0) {
            date = Date(timeIntervalSince1970: Double(Int64(bitPattern: seconds.varint)))
        }
        return VehicleLocation(latitude: lat, longitude: lon, timestamp: date)
    }

    static func weather(_ data: Data) -> VehicleWeather? {
        guard let fields = try? Protobuf.decode(data) else { return nil }
        if let report = field(fields, 1, 2) {
            guard let nested = try? Protobuf.decode(report.data) else { return nil }
            return weatherReport(nested)
        }
        return weatherReport(fields)
    }

    private static func weatherReport(_ fields: [Protobuf.Field]) -> VehicleWeather? {
        let timestamp = field(fields, 1, 0).map {
            Date(timeIntervalSince1970: Double(Int64(bitPattern: $0.varint)) / 1_000)
        }
        let temperature = number(fields, 2)
        guard temperature != nil else { return nil }
        return VehicleWeather(temperatureCelsius: temperature, condition: nil, timestamp: timestamp)
    }

    private static func field(_ fields: [Protobuf.Field], _ number: Int, _ wire: Int) -> Protobuf.Field? {
        guard let value = fields.last(where: { $0.number == number }), value.wire == wire else { return nil }
        return value
    }

    private static func number(_ fields: [Protobuf.Field], _ number: Int) -> Double? {
        let result: Double?
        if let value = fields.last(where: { $0.number == number }), value.wire == 1 {
            result = Protobuf.double(from: value.data)
        } else if let value = fields.last(where: { $0.number == number }), value.wire == 5 {
            result = Protobuf.float(from: value.data).map(Double.init)
        } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func valid(_ latitude: Double, _ longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
