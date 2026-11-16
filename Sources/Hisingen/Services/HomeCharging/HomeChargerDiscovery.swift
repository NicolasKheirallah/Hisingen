import Foundation

struct DiscoveredCharger: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var entities: HomeChargerEntityMap
    /// What the classifier could not place; the setup screen offers manual mapping for these.
    var missing: [String] { entities.missingRequired }
}

struct DiscoveredBatterySensor: Equatable, Identifiable, Sendable {
    var id: String { entityID }
    var entityID: String
    var name: String
    var percent: Double?
    var lastReported: Date?
}

/// Any entity the reader might map by hand when discovery missed it or an entity was renamed.
struct DiscoveredEntity: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var domain: String
}

struct HomeAssistantDiscovery: Equatable, Sendable {
    var chargers: [DiscoveredCharger]
    var entities: [DiscoveredEntity]
    var batterySensors: [DiscoveredBatterySensor]
    var timeZone: String
    var version: String
    var hasTibber: Bool
    /// False when the token could not run the template call. Chargers are still found by their
    /// entity names, only without the device serial number.
    var usedDeviceRegistry: Bool
}

/// Finds charger entities in the state table. The Home Assistant NexBlue integration creates
/// entities named `<device>_<entity>`, so the charging-state enum sensor anchors a charger and
/// every other entity with the same prefix belongs to it.
enum HomeChargerDiscovery {
    /// Options the NexBlue `charging_state` enum sensor lists. Two of these together identify it.
    private static let nexblueStateOptions: Set<String> = ["idle", "connected", "charging", "finished", "error",
                                                           "lb_waiting", "delay_waiting", "ev_waiting"]

    static func chargers(in states: [HAEntityState], serialsByEntity: [String: (serial: String?, name: String?)] = [:]) -> [DiscoveredCharger] {
        let anchors = states.filter { state in
            guard state.domain == "sensor", let options = state.options else { return false }
            return options.filter { nexblueStateOptions.contains($0) }.count >= 5
        }
        return anchors.compactMap { anchor in
            guard let prefix = prefix(of: anchor.entityID) else { return nil }
            let members = states.filter { $0.entityID.dropFirst($0.domain.count + 1).hasPrefix(prefix) }
            var map = HomeChargerEntityMap(chargingState: anchor.entityID)
            for member in members where member.entityID != anchor.entityID {
                classify(member, into: &map)
            }
            let known = serialsByEntity[anchor.entityID]
            let serial = known?.serial?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let name = known?.name?.nilIfEmpty ?? serial ?? prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_")).uppercased()
            return DiscoveredCharger(id: serial ?? prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_")),
                                     name: L10n.format("NexBlue %@", name), entities: map)
        }
        .sorted { $0.id < $1.id }
    }

    static func batterySensors(in states: [HAEntityState]) -> [DiscoveredBatterySensor] {
        states.filter { state in
            state.domain == "sensor" && state.unit == "%" && state.deviceClass == "battery"
        }
        .map {
            DiscoveredBatterySensor(entityID: $0.entityID, name: $0.friendlyName ?? $0.entityID,
                                    percent: $0.number, lastReported: $0.freshestTimestamp)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `sensor.nx123_charging_state` gives `nx123_`.
    static func prefix(of entityID: String) -> String? {
        guard let object = entityID.split(separator: ".", maxSplits: 1).last else { return nil }
        let suffix = "charging_state"
        guard object.hasSuffix(suffix) else { return nil }
        let prefix = String(object.dropLast(suffix.count))
        return prefix.isEmpty ? nil : prefix
    }

    private static func classify(_ state: HAEntityState, into map: inout HomeChargerEntityMap) {
        let name = (state.friendlyName ?? state.entityID).lowercased()
        switch state.domain {
        case "switch":
            if map.chargingSwitch == nil { map.chargingSwitch = state.entityID }
        case "binary_sensor":
            if state.deviceClass == "lock" || name.contains("lock") {
                map.cableLock = map.cableLock ?? state.entityID
            } else if name.contains("enabled") || name.contains("disable") {
                map.chargingEnabled = map.chargingEnabled ?? state.entityID
            }
        case "sensor":
            switch state.deviceClass {
            case "power":
                if state.unit?.lowercased() == "kw" || state.unit?.lowercased() == "w" {
                    map.power = map.power ?? state.entityID
                }
            case "energy":
                if state.stateClass == "total_increasing" {
                    map.lifetimeEnergy = map.lifetimeEnergy ?? state.entityID
                } else if state.stateClass == "total" || state.stateClass == nil {
                    map.sessionEnergy = map.sessionEnergy ?? state.entityID
                }
            case "current":
                if name.contains("limit"), !name.contains("cable") {
                    map.currentLimit = map.currentLimit ?? state.entityID
                }
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: - Live discovery

    /// Reads the config, every state and (best effort) the device registry through a template.
    static func discover(using client: HomeAssistantClient) async throws -> HomeAssistantDiscovery {
        async let configTask = client.config()
        async let statesTask = client.states()
        let (config, states) = try await (configTask, statesTask)
        let serials = await deviceSerials(using: client)
        let mappable: Set<String> = ["sensor", "switch", "binary_sensor"]
        let entities = states.filter { mappable.contains($0.domain) }
            .map { DiscoveredEntity(id: $0.entityID, name: $0.friendlyName ?? $0.entityID, domain: $0.domain) }
            .sorted { $0.id < $1.id }
        return HomeAssistantDiscovery(
            chargers: chargers(in: states, serialsByEntity: serials ?? [:]),
            entities: entities,
            batterySensors: batterySensors(in: states),
            timeZone: config.timeZone,
            version: config.version,
            hasTibber: config.hasIntegration("tibber"),
            usedDeviceRegistry: serials != nil
        )
    }

    private static let serialTemplate = """
    {% set ns = namespace(items=[]) %}\
    {% for e in integration_entities('nexblue') %}\
    {% set d = device_id(e) %}\
    {% set ns.items = ns.items + [{'entity_id': e, 'serial': (device_attr(d, 'serial_number') if d else none), 'name': (device_attr(d, 'name') if d else none)}] %}\
    {% endfor %}{{ ns.items | tojson }}
    """

    /// Administrator tokens only; any other failure just means serials are unavailable.
    static func deviceSerials(using client: HomeAssistantClient) async -> [String: (serial: String?, name: String?)]? {
        guard let text = try? await client.renderTemplate(serialTemplate),
              let array = (try? JSONDecoder().decode(HAJSONValue.self, from: Data(text.utf8)))?.arrayValue else { return nil }
        var result: [String: (serial: String?, name: String?)] = [:]
        for item in array {
            guard let object = item.objectValue, let entity = object["entity_id"]?.stringValue else { continue }
            result[entity] = (object["serial"]?.stringValue, object["name"]?.stringValue)
        }
        return result
    }
}
