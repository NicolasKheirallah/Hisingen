import Foundation

/// A JSON value as Home Assistant reports it inside entity attributes and action responses.
enum HAJSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([HAJSONValue])
    case object([String: HAJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([HAJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: HAJSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Numbers, and numeric strings (Home Assistant states are always strings).
    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [HAJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: HAJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// Home Assistant timestamps are ISO 8601 with up to microsecond precision and a numeric offset.
/// Foundation's parsers disagree about long fractions, so the fraction is cut to milliseconds first.
enum HATimestamp {
    static func parse(_ text: String) -> Date? {
        let normalised = truncateFraction(text)
        if let date = try? Date(normalised, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(normalised, strategy: Date.ISO8601FormatStyle())
    }

    /// `2026-11-16T17:00:00+00:00`, the shape every Home Assistant endpoint accepts.
    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }

    private static func truncateFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let afterDot = text.index(after: dot)
        var digitsEnd = afterDot
        while digitsEnd < text.endIndex, text[digitsEnd].isNumber { digitsEnd = text.index(after: digitsEnd) }
        let digitCount = text.distance(from: afterDot, to: digitsEnd)
        guard digitCount > 3 else { return text }
        let keepEnd = text.index(afterDot, offsetBy: 3)
        return String(text[..<keepEnd]) + String(text[digitsEnd...])
    }
}

/// One entity state as `GET /api/states` and the `state_changed` event deliver it.
struct HAEntityState: Equatable, Sendable, Decodable {
    let entityID: String
    let state: String
    let attributes: [String: HAJSONValue]
    let lastChanged: Date?
    let lastUpdated: Date?
    /// Advances on every write, even when the value did not change (Home Assistant 2024.3 and
    /// later). It is the honest "when was this last confirmed" for a steady reading.
    let lastReported: Date?

    init(entityID: String, state: String, attributes: [String: HAJSONValue] = [:],
         lastChanged: Date? = nil, lastUpdated: Date? = nil, lastReported: Date? = nil) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
        self.lastUpdated = lastUpdated
        self.lastReported = lastReported
    }

    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state, attributes
        case lastChanged = "last_changed"
        case lastUpdated = "last_updated"
        case lastReported = "last_reported"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decode(String.self, forKey: .entityID)
        state = try container.decode(String.self, forKey: .state)
        attributes = try container.decodeIfPresent([String: HAJSONValue].self, forKey: .attributes) ?? [:]
        func date(_ key: CodingKeys) -> Date? {
            (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(HATimestamp.parse)
        }
        lastChanged = date(.lastChanged)
        lastUpdated = date(.lastUpdated)
        lastReported = date(.lastReported)
    }

    /// The newest moment Home Assistant vouches for this reading.
    var freshestTimestamp: Date? { lastReported ?? lastUpdated ?? lastChanged }

    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }

    var domain: String { entityID.split(separator: ".").first.map(String.init) ?? "" }

    var friendlyName: String? { attributes["friendly_name"]?.stringValue }
    var unit: String? { attributes["unit_of_measurement"]?.stringValue }
    var deviceClass: String? { attributes["device_class"]?.stringValue }
    var stateClass: String? { attributes["state_class"]?.stringValue }
    var options: [String]? { attributes["options"]?.arrayValue?.compactMap(\.stringValue) }

    var number: Double? {
        guard !isUnavailable else { return nil }
        return Double(state.trimmingCharacters(in: .whitespaces))
    }
}

/// A `state_changed` event reduced to what the charger session needs.
struct HAStateChange: Equatable, Sendable {
    let entityID: String
    let newState: HAEntityState?
}

/// One state in a `GET /api/history/period` response. With `minimal_response` the middle entries
/// carry only the state and `last_changed`.
struct HAHistoryPoint: Equatable, Sendable, Decodable {
    let entityID: String?
    let state: String
    let at: Date

    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case lastChanged = "last_changed"
        case lastUpdated = "last_updated"
    }

    init(entityID: String?, state: String, at: Date) {
        self.entityID = entityID
        self.state = state
        self.at = at
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decodeIfPresent(String.self, forKey: .entityID)
        state = try container.decode(String.self, forKey: .state)
        let changed = (try? container.decodeIfPresent(String.self, forKey: .lastChanged)).flatMap { $0 }.flatMap(HATimestamp.parse)
        let updated = (try? container.decodeIfPresent(String.self, forKey: .lastUpdated)).flatMap { $0 }.flatMap(HATimestamp.parse)
        guard let at = changed ?? updated else {
            throw DecodingError.dataCorruptedError(forKey: .lastChanged, in: container,
                                                   debugDescription: "History entry has no timestamp")
        }
        self.at = at
    }
}
