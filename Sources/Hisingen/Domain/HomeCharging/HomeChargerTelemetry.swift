import Foundation

/// The charger's own status, from the NexBlue integration's `charging_state` enum sensor
/// (options `idle, connected, charging, finished, error, lb_waiting, delay_waiting, ev_waiting`
/// in Home Assistant core). A value the table does not know stays `.unrecognised` and carries
/// its raw token instead of being guessed into a known state.
enum HomeChargerStatus: Equatable, Sendable {
    case unplugged
    case pluggedIn
    case charging
    case finished
    case error
    /// `lb_waiting`: the load balancer (Perific/Enegic) is holding the charger for available power.
    case waitingForPower
    /// `delay_waiting`: a delayed start is active on the charger (a NexBlue schedule or EcoPilot).
    case delayedStart
    /// `ev_waiting`: the charger is ready and waiting for the car to start drawing power.
    case waitingForVehicle
    case unavailable
    case unrecognised(String)

    init(haState raw: String) {
        let token = raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch token {
        case "idle", "available", "disconnected", "unplugged": self = .unplugged
        case "connected", "plugged_in", "preparing": self = .pluggedIn
        case "charging": self = .charging
        case "finished", "complete", "completed": self = .finished
        case "error", "fault", "faulted": self = .error
        case "lb_waiting", "load_balancing", "waiting_for_power": self = .waitingForPower
        case "delay_waiting", "delayed", "delayed_start": self = .delayedStart
        case "ev_waiting", "waiting_for_vehicle", "waiting_for_car": self = .waitingForVehicle
        case "unavailable", "unknown", "": self = .unavailable
        default: self = .unrecognised(token)
        }
    }

    /// The set the charging switch reports as on (codes 2, 5 and 7 in the integration): charging,
    /// waiting for power, waiting for the car. A command to start is confirmed by one of these.
    var isChargingEnabled: Bool {
        switch self {
        case .charging, .waitingForPower, .waitingForVehicle: return true
        default: return false
        }
    }

    /// Whether the charger reported that a cable is in the car. Only states the charger itself
    /// reported count; `.unavailable` and `.unrecognised` say nothing either way.
    var cableState: Bool? {
        switch self {
        case .unplugged: return false
        case .pluggedIn, .charging, .finished, .waitingForPower, .delayedStart, .waitingForVehicle: return true
        case .error, .unavailable, .unrecognised: return nil
        }
    }

    /// Maps to Hisingen's existing states where they fit. `lb_waiting` and `ev_waiting` keep the
    /// physical session open the way a paused session does; a delayed start is a scheduled one.
    var chargingState: ChargingState {
        switch self {
        case .charging: return .charging
        case .finished: return .complete
        case .error: return .fault
        case .delayedStart: return .scheduled
        case .waitingForPower, .waitingForVehicle: return .paused
        case .unplugged, .pluggedIn: return .idle
        case .unavailable: return .unknown("UNAVAILABLE")
        case .unrecognised(let token): return .unknown(token.uppercased())
        }
    }

    var connection: ChargerConnection {
        switch self {
        case .unplugged: return .disconnected
        case .error: return .fault
        case .unavailable, .unrecognised: return .unknown
        default: return .connected
        }
    }
}

/// A value with the moment Home Assistant last vouched for it.
struct HomeChargerReading<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value
    var timestamp: Date
}

/// One supply phase as the charger measures it.
struct HomeChargerPhase: Equatable, Sendable {
    var volts: Double
    var amps: Double

    /// A phase under this voltage is not wired or not energised; it says nothing about the supply.
    static let energisedVolts = 50.0
}

/// Whether the charger uses one phase, three, or chooses by itself. A charger setting, not a reading of the car.
enum HomeChargerPhaseMode: Equatable, Sendable {
    case adaptive, singlePhase, threePhase
}

/// How the charger reaches its cloud.
enum HomeChargerNetwork: Equatable, Sendable {
    case none, wifi, mobile, ethernet
}

/// The three ceilings on charging current. The charger draws no more than the lowest of them, so
/// the card names the one that binds.
struct HomeChargerLimits: Equatable, Sendable {
    enum Binding: Equatable, Sendable { case setting, cable, circuitFuse }

    var settingAmps: Double
    var cableAmps: Double?
    var circuitFuseAmps: Double?

    var effectiveAmps: Double {
        min(settingAmps, cableAmps ?? .infinity, circuitFuseAmps ?? .infinity)
    }

    /// The setting wins a tie: it is the one the reader can change.
    var binding: Binding {
        if let cable = cableAmps, cable < settingAmps, cable <= (circuitFuseAmps ?? .infinity) { return .cable }
        if let fuse = circuitFuseAmps, fuse < settingAmps { return .circuitFuse }
        return .setting
    }
}

/// Which entities feed one charger. `chargingState`, `power`, `sessionEnergy` and
/// `chargingSwitch` are what the card and the commands need; the rest sharpen the picture.
struct HomeChargerEntityMap: Codable, Equatable, Sendable {
    var chargingState: String?
    var power: String?
    var sessionEnergy: String?
    var lifetimeEnergy: String?
    var currentLimit: String?
    var chargingSwitch: String?
    var chargingEnabled: String?
    var cableLock: String?
    /// A battery sensor that Home Assistant itself maintains, independent of Hisingen. Required
    /// for "Reach X% by HH:mm" plans and for nothing else.
    var vehicleBattery: String?

    init(chargingState: String? = nil, power: String? = nil, sessionEnergy: String? = nil,
         lifetimeEnergy: String? = nil, currentLimit: String? = nil, chargingSwitch: String? = nil,
         chargingEnabled: String? = nil, cableLock: String? = nil, vehicleBattery: String? = nil) {
        self.chargingState = chargingState
        self.power = power
        self.sessionEnergy = sessionEnergy
        self.lifetimeEnergy = lifetimeEnergy
        self.currentLimit = currentLimit
        self.chargingSwitch = chargingSwitch
        self.chargingEnabled = chargingEnabled
        self.cableLock = cableLock
        self.vehicleBattery = vehicleBattery
    }

    var allEntityIDs: [String] {
        [chargingState, power, sessionEnergy, lifetimeEnergy, currentLimit, chargingSwitch,
         chargingEnabled, cableLock, vehicleBattery].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The minimum for a usable pairing: status to read, power and energy to show, a switch to act on.
    var missingRequired: [String] {
        var missing: [String] = []
        if chargingState?.isEmpty != false { missing.append("charging state") }
        if power?.isEmpty != false { missing.append("power") }
        if sessionEnergy?.isEmpty != false { missing.append("session energy") }
        if chargingSwitch?.isEmpty != false { missing.append("charging switch") }
        return missing
    }

    var isUsable: Bool { missingRequired.isEmpty }
}

enum HomeChargerFreshness: Equatable, Sendable {
    /// Reported within the staleness window; `age` is how long ago.
    case current(age: TimeInterval)
    case stale(age: TimeInterval)
    /// Home Assistant lists the entity but reports it unavailable (the charger is offline).
    case unavailable
    case noData
}

/// Everything read from Home Assistant about one charger, each reading stamped with when
/// Home Assistant last confirmed it.
struct HomeChargerTelemetry: Equatable, Sendable {
    /// A reading older than this is shown as stale. The NexBlue cloud integration polls every
    /// minute, so ten minutes means several polls were missed.
    static let defaultStaleAfter: TimeInterval = 600
    /// Draw under this counts as no power. Sensor noise and idle consumption sit below it.
    static let zeroPowerThresholdKw = 0.1

    var status: HomeChargerReading<HomeChargerStatus>?
    var powerKw: HomeChargerReading<Double>?
    var sessionEnergyKwh: HomeChargerReading<Double>?
    var lifetimeEnergyKwh: HomeChargerReading<Double>?
    var currentLimitAmps: HomeChargerReading<Double>?
    var chargingEnabled: HomeChargerReading<Bool>?
    /// The charger's own switch is off, so a start command would be refused. Separate from
    /// `chargingEnabled`, which says whether energy is moving now, not whether it may start.
    var isDisabled: HomeChargerReading<Bool>?
    var cableLocked: HomeChargerReading<Bool>?
    var vehicleBatteryPercent: HomeChargerReading<Double>?
    /// Per-phase voltage and current. Only direct chargers that report them fill these four.
    var phases: HomeChargerReading<[HomeChargerPhase]>?
    var cableLimitAmps: HomeChargerReading<Double>?
    var circuitFuseAmps: HomeChargerReading<Double>?
    var phaseMode: HomeChargerReading<HomeChargerPhaseMode>?
    var network: HomeChargerReading<HomeChargerNetwork>?
    /// Entities in the map that Home Assistant reports `unavailable` (not merely stale).
    var unavailableEntities: Set<String> = []

    init(status: HomeChargerReading<HomeChargerStatus>? = nil,
         powerKw: HomeChargerReading<Double>? = nil,
         sessionEnergyKwh: HomeChargerReading<Double>? = nil,
         lifetimeEnergyKwh: HomeChargerReading<Double>? = nil,
         currentLimitAmps: HomeChargerReading<Double>? = nil,
         chargingEnabled: HomeChargerReading<Bool>? = nil,
         isDisabled: HomeChargerReading<Bool>? = nil,
         cableLocked: HomeChargerReading<Bool>? = nil,
         vehicleBatteryPercent: HomeChargerReading<Double>? = nil,
         unavailableEntities: Set<String> = [],
         phases: HomeChargerReading<[HomeChargerPhase]>? = nil,
         cableLimitAmps: HomeChargerReading<Double>? = nil,
         circuitFuseAmps: HomeChargerReading<Double>? = nil,
         phaseMode: HomeChargerReading<HomeChargerPhaseMode>? = nil,
         network: HomeChargerReading<HomeChargerNetwork>? = nil) {
        self.phases = phases
        self.cableLimitAmps = cableLimitAmps
        self.circuitFuseAmps = circuitFuseAmps
        self.phaseMode = phaseMode
        self.network = network
        self.status = status
        self.powerKw = powerKw
        self.sessionEnergyKwh = sessionEnergyKwh
        self.lifetimeEnergyKwh = lifetimeEnergyKwh
        self.currentLimitAmps = currentLimitAmps
        self.chargingEnabled = chargingEnabled
        self.isDisabled = isDisabled
        self.cableLocked = cableLocked
        self.vehicleBatteryPercent = vehicleBatteryPercent
        self.unavailableEntities = unavailableEntities
    }

    /// Reads every mapped entity out of a state table. `fallbackTimestamp` stamps a reading whose
    /// state carries no timestamp at all (a fixture, or a very old Home Assistant).
    static func make(from states: [String: HAEntityState], map: HomeChargerEntityMap,
                     fallbackTimestamp: Date? = nil) -> HomeChargerTelemetry {
        var telemetry = HomeChargerTelemetry()

        func stamped(_ id: String?) -> (state: HAEntityState, at: Date)? {
            guard let id, let state = states[id] else { return nil }
            guard !state.isUnavailable else {
                telemetry.unavailableEntities.insert(id)
                return nil
            }
            guard let at = state.freshestTimestamp ?? fallbackTimestamp else { return nil }
            return (state, at)
        }

        if let id = map.chargingState, let state = states[id] {
            if state.isUnavailable {
                telemetry.unavailableEntities.insert(id)
                if let at = state.freshestTimestamp ?? fallbackTimestamp {
                    telemetry.status = HomeChargerReading(value: .unavailable, timestamp: at)
                }
            } else if let at = state.freshestTimestamp ?? fallbackTimestamp {
                telemetry.status = HomeChargerReading(value: HomeChargerStatus(haState: state.state), timestamp: at)
            }
        }
        if let (state, at) = stamped(map.power), let value = state.number {
            telemetry.powerKw = HomeChargerReading(value: Self.kilowatts(value, unit: state.unit), timestamp: at)
        }
        if let (state, at) = stamped(map.sessionEnergy), let value = state.number {
            telemetry.sessionEnergyKwh = HomeChargerReading(value: Self.kilowattHours(value, unit: state.unit), timestamp: at)
        }
        if let (state, at) = stamped(map.lifetimeEnergy), let value = state.number {
            telemetry.lifetimeEnergyKwh = HomeChargerReading(value: Self.kilowattHours(value, unit: state.unit), timestamp: at)
        }
        if let (state, at) = stamped(map.currentLimit), let value = state.number {
            telemetry.currentLimitAmps = HomeChargerReading(value: value, timestamp: at)
        }
        if let (state, at) = stamped(map.chargingEnabled) {
            telemetry.chargingEnabled = HomeChargerReading(value: state.state == "on", timestamp: at)
        }
        if let (state, at) = stamped(map.cableLock) {
            // A lock-class binary sensor is "on" when unlocked.
            let unlockedIsOn = state.deviceClass == "lock"
            telemetry.cableLocked = HomeChargerReading(value: unlockedIsOn ? state.state != "on" : state.state == "on",
                                                       timestamp: at)
        }
        if let (state, at) = stamped(map.vehicleBattery), let value = state.number, (0...100).contains(value) {
            telemetry.vehicleBatteryPercent = HomeChargerReading(value: value, timestamp: at)
        }
        return telemetry
    }

    private static func kilowatts(_ value: Double, unit: String?) -> Double {
        unit?.lowercased() == "w" ? value / 1_000 : value
    }

    private static func kilowattHours(_ value: Double, unit: String?) -> Double {
        unit?.lowercased() == "wh" ? value / 1_000 : value
    }

    /// Freshness of the charger status, the reading every other line leans on.
    func freshness(now: Date, staleAfter: TimeInterval = HomeChargerTelemetry.defaultStaleAfter) -> HomeChargerFreshness {
        guard let status else { return .noData }
        if status.value == .unavailable { return .unavailable }
        let age = max(0, now.timeIntervalSince(status.timestamp))
        return age > staleAfter ? .stale(age: age) : .current(age: age)
    }

    /// Whether a single reading is fresh enough to show as a live number.
    func isFresh<V>(_ reading: HomeChargerReading<V>?, now: Date,
                    staleAfter: TimeInterval = HomeChargerTelemetry.defaultStaleAfter) -> Bool {
        guard let reading else { return false }
        return now.timeIntervalSince(reading.timestamp) <= staleAfter
    }
}

/// How sure the card is that a cable is in the car, and who said so.
enum HomeConnectorEvidence: Equatable, Sendable {
    /// The charger reported it, in a reading that is still current.
    case confirmedByCharger
    /// The charger is stale or silent; the vehicle reports a connection.
    case reportedByVehicle
    /// Neither source speaks directly; derived from power or session activity.
    case inferred
    case unknown
}

/// What the charger is doing right now, resolved from status, power and freshness. This is the
/// single decision the card, the notification layer and the command tracker all read.
enum HomeChargerActivity: Equatable, Sendable {
    case noCable
    case pluggedIn
    case charging(powerKw: Double)
    /// The charger is enabled and the car draws nothing.
    case enabledNoDraw
    case waitingForPower
    case delayedStart
    case waitingForVehicle
    case finished
    case fault
    case unavailable
    case stale
}

extension HomeChargerTelemetry {
    /// The current ceilings, or `nil` when the charger gave no limit setting to compare against.
    var limits: HomeChargerLimits? {
        guard let setting = currentLimitAmps?.value, setting > 0 else { return nil }
        return HomeChargerLimits(settingAmps: setting, cableAmps: cableLimitAmps?.value,
                                 circuitFuseAmps: circuitFuseAmps?.value)
    }

    /// The phases carrying voltage, so a single-phase charger is not shown two empty phases.
    var energisedPhases: [HomeChargerPhase] {
        (phases?.value ?? []).filter { $0.volts >= HomeChargerPhase.energisedVolts }
    }

    func activity(now: Date, staleAfter: TimeInterval = HomeChargerTelemetry.defaultStaleAfter) -> HomeChargerActivity {
        switch freshness(now: now, staleAfter: staleAfter) {
        case .noData, .unavailable: return .unavailable
        case .stale: return .stale
        case .current: break
        }
        guard let status = status?.value else { return .unavailable }
        let power = isFresh(powerKw, now: now, staleAfter: staleAfter) ? powerKw?.value : nil
        switch status {
        case .unplugged: return .noCable
        case .pluggedIn: return .pluggedIn
        case .charging:
            guard let power else { return .charging(powerKw: 0) }
            return power < Self.zeroPowerThresholdKw ? .enabledNoDraw : .charging(powerKw: power)
        case .waitingForPower: return .waitingForPower
        case .delayedStart: return .delayedStart
        case .waitingForVehicle: return .waitingForVehicle
        case .finished: return .finished
        case .error: return .fault
        case .unavailable, .unrecognised: return .unavailable
        }
    }

    func connectorEvidence(now: Date, vehicleConnection: ChargerConnection?,
                           staleAfter: TimeInterval = HomeChargerTelemetry.defaultStaleAfter) -> (connected: Bool?, evidence: HomeConnectorEvidence) {
        if case .current = freshness(now: now, staleAfter: staleAfter),
           let cable = status?.value.cableState {
            return (cable, .confirmedByCharger)
        }
        if let vehicleConnection, vehicleConnection != .unknown {
            return (vehicleConnection == .connected, .reportedByVehicle)
        }
        if isFresh(powerKw, now: now, staleAfter: staleAfter), (powerKw?.value ?? 0) >= Self.zeroPowerThresholdKw {
            return (true, .inferred)
        }
        return (nil, .unknown)
    }
}
