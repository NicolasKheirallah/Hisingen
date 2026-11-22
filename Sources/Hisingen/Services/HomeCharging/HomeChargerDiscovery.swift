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

/// One entity's Home Assistant device metadata, as the administrator-only registry template
/// returns it. Grouping by `deviceID` finds a charger from any integration's naming scheme,
/// which is what lets discovery go beyond NexBlue's `<device>_charging_state` convention.
struct HADeviceEntity: Equatable, Sendable {
    var entityID: String
    var deviceID: String
    var deviceName: String?
    var manufacturer: String?
    var model: String?
    var serial: String?
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

    /// A charger found through Home Assistant's device registry rather than through NexBlue's
    /// name prefix. The device's enum status sensor anchors it; every other entity on the same
    /// device is classified by device class and name. The charging switch is mapped only when
    /// every status option is one Hisingen can read: a start or pause is confirmed from that
    /// state sensor, so discovery must not offer a write it cannot confirm.
    static func chargers(in states: [HAEntityState], devices: [String: HADeviceEntity]) -> [DiscoveredCharger] {
        let statesByID = Dictionary(states.map { ($0.entityID, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: devices.values, by: \.deviceID)
        var found: [DiscoveredCharger] = []
        for (_, entries) in groups.sorted(by: { $0.key < $1.key }) {
            let deviceStates = entries.compactMap { statesByID[$0.entityID] }
            guard let anchor = stateAnchor(in: deviceStates) else { continue }
            var map = HomeChargerEntityMap(chargingState: anchor.entityID)
            for state in deviceStates.sorted(by: { $0.entityID < $1.entityID }) where state.entityID != anchor.entityID {
                classify(state, into: &map)
            }
            // A device with only a status and a switch is not a charger Hisingen can show; it
            // needs at least the power and session-energy readings the card is built on.
            guard map.power != nil, map.sessionEnergy != nil else { continue }
            if !isConfirmable(anchor) { map.chargingSwitch = nil }

            let identity = entries.first
            let display = identity?.deviceName?.nilIfEmpty
                ?? identity?.serial?.nilIfEmpty
                ?? identity?.deviceID
                ?? anchor.entityID
            let brand = identity?.manufacturer?.nilIfEmpty
            found.append(DiscoveredCharger(
                id: identity?.serial?.nilIfEmpty ?? identity?.deviceID ?? anchor.entityID,
                name: brand.map { "\($0) \(display)" } ?? display,
                entities: map
            ))
        }
        return found.sorted { $0.id < $1.id }
    }

    /// The device's status reading. An enum sensor needs at least two options Hisingen can read;
    /// a plain state sensor must be named like a status and currently read as one.
    private static func stateAnchor(in states: [HAEntityState]) -> HAEntityState? {
        let sensors = states.filter { $0.domain == "sensor" }
        if let enumAnchor = sensors.first(where: { state in
            guard let options = state.options, options.count >= 2 else { return false }
            return options.filter(isKnownStatus).count >= 2
        }) {
            return enumAnchor
        }
        return sensors.first { state in
            let name = (state.friendlyName ?? state.entityID).lowercased()
            guard name.contains("status") || name.contains("state") else { return false }
            return isKnownStatus(state.state)
        }
    }

    private static func isKnownStatus(_ raw: String) -> Bool {
        if case .unrecognised = HomeChargerStatus(haState: raw) { return false }
        return true
    }

    /// Every option must be readable, so a future state can confirm a command. A plain state
    /// sensor without an option list cannot promise that and stays read-only.
    private static func isConfirmable(_ anchor: HAEntityState) -> Bool {
        guard let options = anchor.options, !options.isEmpty else { return false }
        return options.allSatisfy(isKnownStatus)
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
        let registry = await deviceRegistry(using: client)
        let serials = registry?.mapValues { (serial: $0.serial, name: $0.deviceName) } ?? [:]
        // `number` is here for the writable current limit: a charger integration exposes the
        // settable ceiling as a number entity, and that is the only charger write Hisingen
        // performs beyond charge/pause without a vendor API.
        let mappable: Set<String> = ["sensor", "switch", "binary_sensor", "number"]
        let entities = states.filter { mappable.contains($0.domain) }
            .map { DiscoveredEntity(id: $0.entityID, name: $0.friendlyName ?? $0.entityID, domain: $0.domain) }
            .sorted { $0.id < $1.id }
        let byPrefix = chargers(in: states, serialsByEntity: serials)
        let byDevice = registry.map { chargers(in: states, devices: $0) } ?? []
        return HomeAssistantDiscovery(
            chargers: merge(byDevice, with: byPrefix),
            entities: entities,
            batterySensors: batterySensors(in: states),
            timeZone: config.timeZone,
            version: config.version,
            hasTibber: config.hasIntegration("tibber"),
            usedDeviceRegistry: registry != nil
        )
    }

    /// Device-found chargers lead; the name-prefix pass only adds chargers whose anchor is not
    /// already represented, so a NexBlue install seen through both routes appears once.
    private static func merge(_ primary: [DiscoveredCharger], with fallback: [DiscoveredCharger]) -> [DiscoveredCharger] {
        var result = primary
        let anchors = Set(primary.compactMap { $0.entities.chargingState })
        for charger in fallback where charger.entities.chargingState.map({ !anchors.contains($0) }) ?? true {
            result.append(charger)
        }
        return result.sorted { $0.id < $1.id }
    }

    /// NexBlue, Easee and Zaptec are the charger integrations this build knows how to read. An
    /// integration that is not loaded contributes nothing; the domains are Home Assistant's own
    /// integration ids, not vendor endpoints. Administrator tokens only: any other failure means
    /// device grouping is unavailable and the NexBlue name-prefix pass is used alone.
    private static let deviceTemplate = """
    {% set ns = namespace(items=[]) %}\
    {% for domain in ['nexblue', 'easee', 'zaptec'] %}\
    {% for e in integration_entities(domain) %}\
    {% set d = device_id(e) %}\
    {% set ns.items = ns.items + [{'entity_id': e, 'device_id': d, 'name': (device_attr(d, 'name') if d else none), 'manufacturer': (device_attr(d, 'manufacturer') if d else none), 'model': (device_attr(d, 'model') if d else none), 'serial': (device_attr(d, 'serial_number') if d else none)}] %}\
    {% endfor %}{% endfor %}{{ ns.items | tojson }}
    """

    static func deviceRegistry(using client: HomeAssistantClient) async -> [String: HADeviceEntity]? {
        guard let text = try? await client.renderTemplate(deviceTemplate),
              let array = (try? JSONDecoder().decode(HAJSONValue.self, from: Data(text.utf8)))?.arrayValue else { return nil }
        var result: [String: HADeviceEntity] = [:]
        for item in array {
            guard let object = item.objectValue,
                  let entity = object["entity_id"]?.stringValue,
                  let device = object["device_id"]?.stringValue else { continue }
            result[entity] = HADeviceEntity(
                entityID: entity, deviceID: device,
                deviceName: object["name"]?.stringValue,
                manufacturer: object["manufacturer"]?.stringValue,
                model: object["model"]?.stringValue,
                serial: object["serial"]?.stringValue
            )
        }
        return result
    }
}
