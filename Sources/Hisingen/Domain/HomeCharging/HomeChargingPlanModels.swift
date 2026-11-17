import Foundation

enum HomePlanTargetKind: String, Codable, Equatable, Sendable {
    /// Deliver this much energy through the charger by the deadline.
    case addKwh = "add_kwh"
    /// Bring the vehicle to this battery percentage by the deadline. Needs a battery sensor that
    /// Home Assistant maintains on its own.
    case reachPercent = "reach_percent"
}

struct HomePlanTarget: Codable, Equatable, Sendable {
    var kind: HomePlanTargetKind
    var value: Double

    var summary: String {
        switch kind {
        case .addKwh: return L10n.format("Add %@", Format.energyKwh(value))
        case .reachPercent: return L10n.format("Reach %@", Format.percent(value))
        }
    }
}

/// What Hisingen asks Home Assistant to run. The deadline is an absolute instant; the time zone
/// only decides how it is shown.
struct HomeChargingPlanRequest: Equatable, Sendable {
    var planID: String
    var chargerID: String
    var entities: HomeChargerEntityMap
    var target: HomePlanTarget
    var deadline: Date
    var timeZoneIdentifier: String
    var vehicleName: String
    /// Usable battery capacity, needed to turn a percentage into energy.
    var usableCapacityKwh: Double
    var chargingLossFactor: Double
    var tibberHome: String?
    var networkFeeOrePerKwh: Double
    /// A rate to plan with until the charger has delivered enough to measure one.
    var rateHintKw: Double

    /// The `submit_plan` / `preview_plan` action data.
    var actionData: HAJSONValue {
        var charger: [String: HAJSONValue] = [:]
        func put(_ key: String, _ value: String?) { if let value, !value.isEmpty { charger[key] = .string(value) } }
        put("switch", entities.chargingSwitch)
        put("charging_state", entities.chargingState)
        put("power", entities.power)
        put("session_energy", entities.sessionEnergy)
        put("charging_enabled", entities.chargingEnabled)
        put("vehicle_battery", entities.vehicleBattery)
        return .object([
            "plan_id": .string(planID),
            "charger_id": .string(chargerID),
            "charger": .object(charger),
            "target": .object(["type": .string(target.kind.rawValue), "value": .number(target.value)]),
            "deadline": .string(HATimestamp.format(deadline)),
            "time_zone": .string(timeZoneIdentifier),
            "vehicle": .object([
                "name": .string(vehicleName),
                "usable_capacity_kwh": .number(usableCapacityKwh),
                "charging_loss_factor": .number(chargingLossFactor)
            ]),
            "price": .object([
                "tibber_home": tibberHome.map(HAJSONValue.string) ?? .null,
                "network_fee_ore_per_kwh": .number(networkFeeOrePerKwh)
            ]),
            "rate_hint_kw": .number(rateHintKw)
        ])
    }
}

enum HomePlanPhase: String, Equatable, Sendable {
    case idle
    case scheduled
    case charging
    case waitingForPower = "waiting_for_power"
    case delayed
    /// The reader paused: no command is sent until they resume or edit the plan.
    case holding
    /// Charge now is running and overrides the plan's windows.
    case override
    case complete
    /// The deadline cannot be met at the measured rate.
    case unlikely
    case attention
    case cancelled
    case expired

    var isTerminal: Bool {
        switch self {
        case .idle, .complete, .cancelled, .expired: return true
        default: return false
        }
    }
}

struct HomePlannedWindow: Equatable, Sendable {
    var start: Date
    var end: Date
    var averagePricePerKwh: Double?
}

/// A plan's state as Home Assistant reports it in the plan status sensor's attributes.
struct HomeChargingPlanStatus: Equatable, Sendable {
    var planID: String?
    var phase: HomePlanPhase
    var target: HomePlanTarget?
    var deadline: Date?
    var windows: [HomePlannedWindow]
    var deliveredKwh: Double
    var remainingKwh: Double?
    var rateKw: Double?
    var expectedFinish: Date?
    var estimatedCost: Double?
    var currency: String?
    var priceSource: String?
    var isHeld: Bool
    var hasOverride: Bool
    /// Short reason codes from the component (`rate_below_plan`, `battery_sensor_stale`,
    /// `delayed_start_active`, ...). Shown as plain sentences by `warningText`.
    var warnings: [String]
    var message: String?
    var updatedAt: Date?

    init?(entity: HAEntityState) {
        guard let phase = HomePlanPhase(rawValue: entity.state) else { return nil }
        let attributes = entity.attributes
        self.phase = phase
        planID = attributes["plan_id"]?.stringValue
        if let object = attributes["target"]?.objectValue,
           let kind = object["type"]?.stringValue.flatMap(HomePlanTargetKind.init(rawValue:)),
           let value = object["value"]?.doubleValue {
            target = HomePlanTarget(kind: kind, value: value)
        } else {
            target = nil
        }
        deadline = attributes["deadline"]?.stringValue.flatMap(HATimestamp.parse)
        windows = (attributes["windows"]?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let start = object["start"]?.stringValue.flatMap(HATimestamp.parse),
                  let end = object["end"]?.stringValue.flatMap(HATimestamp.parse) else { return nil }
            return HomePlannedWindow(start: start, end: end, averagePricePerKwh: object["avg_price"]?.doubleValue)
        }
        deliveredKwh = attributes["delivered_kwh"]?.doubleValue ?? 0
        remainingKwh = attributes["remaining_kwh"]?.doubleValue
        rateKw = attributes["rate_kw"]?.doubleValue
        expectedFinish = attributes["expected_finish"]?.stringValue.flatMap(HATimestamp.parse)
        estimatedCost = attributes["estimated_cost"]?.doubleValue
        currency = attributes["currency"]?.stringValue
        priceSource = attributes["price_source"]?.stringValue
        isHeld = attributes["hold"]?.boolValue ?? (phase == .holding)
        hasOverride = attributes["override"]?.boolValue ?? (phase == .override)
        warnings = (attributes["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        message = attributes["message"]?.stringValue
        updatedAt = attributes["updated_at"]?.stringValue.flatMap(HATimestamp.parse)
    }

    init(phase: HomePlanPhase, planID: String? = nil, target: HomePlanTarget? = nil, deadline: Date? = nil,
         windows: [HomePlannedWindow] = [], deliveredKwh: Double = 0, remainingKwh: Double? = nil,
         rateKw: Double? = nil, expectedFinish: Date? = nil, estimatedCost: Double? = nil,
         currency: String? = nil, priceSource: String? = nil, isHeld: Bool = false, hasOverride: Bool = false,
         warnings: [String] = [], message: String? = nil, updatedAt: Date? = nil) {
        self.phase = phase
        self.planID = planID
        self.target = target
        self.deadline = deadline
        self.windows = windows
        self.deliveredKwh = deliveredKwh
        self.remainingKwh = remainingKwh
        self.rateKw = rateKw
        self.expectedFinish = expectedFinish
        self.estimatedCost = estimatedCost
        self.currency = currency
        self.priceSource = priceSource
        self.isHeld = isHeld
        self.hasOverride = hasOverride
        self.warnings = warnings
        self.message = message
        self.updatedAt = updatedAt
    }

    func warningText(_ code: String) -> String {
        switch code {
        case "rate_below_plan": return L10n.text("The car is charging slower than planned. The plan was recalculated.")
        case "deadline_unlikely": return L10n.text("The target is unlikely by the deadline at the current charging rate.")
        case "battery_sensor_stale": return L10n.text("The battery sensor in Home Assistant has not updated recently.")
        case "delayed_start_active": return L10n.text("NexBlue is holding the start with a delayed start.")
        case "command_unconfirmed": return L10n.text("The charger did not confirm the last command.")
        case "charger_unavailable": return L10n.text("The charger is unavailable in Home Assistant.")
        case "prices_missing": return L10n.text("Tibber prices are missing for part of the period.")
        case "waiting_for_power": return L10n.text("Waiting for available power.")
        case "waiting_for_vehicle": return L10n.text("Waiting for the car to start drawing power.")
        case "car_limit_reached": return L10n.text("The car stopped at its own battery limit, which is the ceiling for a plan.")
        default: return code
        }
    }
}

/// Which target types the installation supports, and why a type is missing.
struct HomeChargingCapabilities: Equatable, Sendable {
    enum ReachPercentGap: Equatable, Sendable {
        case noSensorConfigured
        case sensorUnavailable
        case sensorStale(age: TimeInterval)
        case sensorNotABattery
    }

    var supportsAddKwh = true
    var reachPercentGap: ReachPercentGap?
    var supportsReachPercent: Bool { reachPercentGap == nil }

    /// A battery reading older than this is not a basis for a percentage plan.
    static let batterySensorStaleAfter: TimeInterval = 30 * 60

    static func evaluate(batterySensor: HAEntityState?, configured: Bool, now: Date) -> HomeChargingCapabilities {
        guard configured else { return HomeChargingCapabilities(reachPercentGap: .noSensorConfigured) }
        guard let sensor = batterySensor else { return HomeChargingCapabilities(reachPercentGap: .sensorUnavailable) }
        guard !sensor.isUnavailable, let value = sensor.number else {
            return HomeChargingCapabilities(reachPercentGap: .sensorUnavailable)
        }
        guard sensor.unit == "%", (0...100).contains(value) else {
            return HomeChargingCapabilities(reachPercentGap: .sensorNotABattery)
        }
        guard let at = sensor.freshestTimestamp else { return HomeChargingCapabilities(reachPercentGap: .sensorUnavailable) }
        let age = now.timeIntervalSince(at)
        guard age <= batterySensorStaleAfter else {
            return HomeChargingCapabilities(reachPercentGap: .sensorStale(age: age))
        }
        return HomeChargingCapabilities()
    }

    var reachPercentExplanation: String? {
        guard let gap = reachPercentGap else { return nil }
        switch gap {
        case .noSensorConfigured:
            return L10n.text("Reach a battery percentage needs a battery sensor that Home Assistant keeps on its own. None is chosen.")
        case .sensorUnavailable:
            return L10n.text("The chosen battery sensor is unavailable in Home Assistant.")
        case .sensorStale(let age):
            return L10n.format("The battery sensor last updated %@ ago, too long to plan from.", Format.shortDuration(minutes: Int(age / 60)))
        case .sensorNotABattery:
            return L10n.text("The chosen sensor does not report a percentage between 0 and 100.")
        }
    }
}

/// The plan Hisingen last handed to Home Assistant, kept so the vehicle-side scheduler keeps
/// deferring while Home Assistant is unreachable and across a relaunch.
struct HomeChargingPlanRecord: Codable, Equatable, Sendable {
    var planID: String
    var vin: String
    var chargerID: String
    var deadline: Date
    var submittedAt: Date
    /// Set when Home Assistant reported the plan finished, cancelled or expired.
    var endedAt: Date?
}

enum HomeChargingOwnership {
    /// Home Assistant keeps ownership briefly past the deadline: the last window may still be running.
    static let graceAfterDeadline: TimeInterval = 3_600

    /// Whether Home Assistant is running a plan for this vehicle, so the vehicle-side scheduler must wait.
    static func isHomeAssistantOwned(vin: String, record: HomeChargingPlanRecord?, now: Date) -> Bool {
        guard let record, record.endedAt == nil,
              record.vin.caseInsensitiveCompare(vin) == .orderedSame else { return false }
        return now < record.deadline.addingTimeInterval(graceAfterDeadline)
    }

    /// The record after a status report: a terminal phase closes it.
    static func updated(_ record: HomeChargingPlanRecord?, with status: HomeChargingPlanStatus?, now: Date) -> HomeChargingPlanRecord? {
        guard var record, record.endedAt == nil, let status else { return record }
        if let reported = status.planID {
            guard reported == record.planID else { return record }
        } else {
            // A status with no plan id is only trusted when it was written after the submission;
            // an older one is the sensor still showing the previous plan.
            guard let updatedAt = status.updatedAt, updatedAt >= record.submittedAt else { return record }
        }
        if status.phase.isTerminal { record.endedAt = now }
        return record
    }
}
