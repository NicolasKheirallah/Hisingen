import Foundation

enum ChargingEvent: Equatable, Sendable {
    case started
    case completed
    case fault
    case interrupted
    case lowBattery(threshold: Int)

    var identifierComponent: String {
        switch self {
        case .started: return "started"
        case .completed: return "completed"
        case .fault: return "fault"
        case .interrupted: return "interrupted"
        case .lowBattery(let threshold): return "low-\(threshold)"
        }
    }
}

struct ChargingBaseline: Codable, Equatable, Sendable {
    let vin: String
    var state: ChargingState
    var connection: ChargerConnection
    var batteryPercentage: Double?
    var targetPercentage: Int?
    var vehicleReportedAt: Date?
    var sampledAt: Date?
    var chargingSessionActive: Bool
    var interruptionSamples: Int
    var lowBatteryNotified: Bool
    /// Recent event fingerprints, newest last. A set-with-history (not a single slot)
    /// because one evaluation can emit two events at once — e.g. started + low battery —
    /// and a single overwritten slot let the first event's duplicate slip through.
    var recentEventFingerprints: [String] = []

    enum CodingKeys: String, CodingKey {
        case vin, state, connection, batteryPercentage, targetPercentage
        case vehicleReportedAt, sampledAt, chargingSessionActive, interruptionSamples
        case lowBatteryNotified, recentEventFingerprints, lastEventFingerprint
    }

    init(vin: String, state: ChargingState, connection: ChargerConnection,
         batteryPercentage: Double?, targetPercentage: Int?, vehicleReportedAt: Date?,
         sampledAt: Date?, chargingSessionActive: Bool, interruptionSamples: Int,
         lowBatteryNotified: Bool, recentEventFingerprints: [String] = []) {
        self.vin = vin
        self.state = state
        self.connection = connection
        self.batteryPercentage = batteryPercentage
        self.targetPercentage = targetPercentage
        self.vehicleReportedAt = vehicleReportedAt
        self.sampledAt = sampledAt
        self.chargingSessionActive = chargingSessionActive
        self.interruptionSamples = interruptionSamples
        self.lowBatteryNotified = lowBatteryNotified
        self.recentEventFingerprints = recentEventFingerprints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vin = try values.decode(String.self, forKey: .vin)
        state = try values.decode(ChargingState.self, forKey: .state)
        connection = try values.decode(ChargerConnection.self, forKey: .connection)
        batteryPercentage = try values.decodeIfPresent(Double.self, forKey: .batteryPercentage)
        targetPercentage = try values.decodeIfPresent(Int.self, forKey: .targetPercentage)
        vehicleReportedAt = try values.decodeIfPresent(Date.self, forKey: .vehicleReportedAt)
        sampledAt = try values.decodeIfPresent(Date.self, forKey: .sampledAt)
        chargingSessionActive = try values.decode(Bool.self, forKey: .chargingSessionActive)
        interruptionSamples = try values.decode(Int.self, forKey: .interruptionSamples)
        lowBatteryNotified = try values.decode(Bool.self, forKey: .lowBatteryNotified)
        if let history = try values.decodeIfPresent([String].self, forKey: .recentEventFingerprints) {
            recentEventFingerprints = history
        } else if let legacy = try values.decodeIfPresent(String.self, forKey: .lastEventFingerprint) {
            // Pre-multi-event installs persisted a single fingerprint; keep its dedup.
            recentEventFingerprints = [legacy]
        } else {
            recentEventFingerprints = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vin, forKey: .vin)
        try container.encode(state, forKey: .state)
        try container.encode(connection, forKey: .connection)
        try container.encode(batteryPercentage, forKey: .batteryPercentage)
        try container.encode(targetPercentage, forKey: .targetPercentage)
        try container.encode(vehicleReportedAt, forKey: .vehicleReportedAt)
        try container.encode(sampledAt, forKey: .sampledAt)
        try container.encode(chargingSessionActive, forKey: .chargingSessionActive)
        try container.encode(interruptionSamples, forKey: .interruptionSamples)
        try container.encode(lowBatteryNotified, forKey: .lowBatteryNotified)
        try container.encode(recentEventFingerprints, forKey: .recentEventFingerprints)
    }
}

struct ChargingDetectionResult: Equatable, Sendable {
    let events: [ChargingEvent]
    let baseline: ChargingBaseline
}

struct ChargingTransitionDetector {
    let maximumEventAge: TimeInterval = 20 * 60

    func evaluate(previous: ChargingBaseline?, current: VehicleState,
                  lowBatteryThreshold: Int, now: Date = Date()) -> ChargingDetectionResult {
        var baseline = ChargingBaseline(
            vin: current.vin,
            state: current.chargingState,
            connection: current.chargerConnection,
            batteryPercentage: current.batteryPercentage,
            targetPercentage: current.chargeTargetPercentage,
            vehicleReportedAt: current.vehicleReportedAt,
            sampledAt: current.vehicleReportedAt ?? current.fetchedAt,
            chargingSessionActive: current.isCharging,
            interruptionSamples: 0,
            lowBatteryNotified: false
        )
        guard let previous, previous.vin == current.vin else {
            return ChargingDetectionResult(events: [], baseline: baseline)
        }

        let isNewSample: Bool
        if let oldDate = previous.vehicleReportedAt, let newDate = current.vehicleReportedAt {
            isNewSample = newDate > oldDate
        } else {
            isNewSample = (current.vehicleReportedAt ?? current.fetchedAt) > (previous.sampledAt ?? .distantPast)
        }
        let isRecent = current.vehicleReportedAt.map { now.timeIntervalSince($0) <= maximumEventAge } ?? true
        guard isNewSample else {
            return ChargingDetectionResult(events: [], baseline: previous)
        }

        baseline.chargingSessionActive = previous.chargingSessionActive
        baseline.lowBatteryNotified = previous.lowBatteryNotified
        baseline.recentEventFingerprints = previous.recentEventFingerprints
        var events: [ChargingEvent] = []

        let explicitFault = current.chargingState == .fault || current.chargerConnection == .fault
        if explicitFault && previous.state != .fault && previous.connection != .fault {
            events.append(.fault)
            baseline.chargingSessionActive = false
            baseline.interruptionSamples = 0
        } else if current.isCharging {
            if !previous.chargingSessionActive { events.append(.started) }
            baseline.chargingSessionActive = true
            baseline.interruptionSamples = 0
        } else if previous.chargingSessionActive && current.isComplete {
            events.append(.completed)
            baseline.chargingSessionActive = false
            baseline.interruptionSamples = 0
        } else if previous.chargingSessionActive && isInterruptionCandidate(current) {
            baseline.interruptionSamples = previous.interruptionSamples + 1
            if baseline.interruptionSamples >= 2 {
                events.append(.interrupted)
                baseline.chargingSessionActive = false
                baseline.interruptionSamples = 0
            }
        } else {
            baseline.interruptionSamples = 0
        }

        if current.isCharging || current.batteryPercentage.map({ $0 > Double(lowBatteryThreshold + 5) }) == true {
            baseline.lowBatteryNotified = false
        } else if let level = current.batteryPercentage,
                  level <= Double(lowBatteryThreshold), !previous.lowBatteryNotified {
            events.append(.lowBattery(threshold: lowBatteryThreshold))
            baseline.lowBatteryNotified = true
        }

        if !isRecent { events = [] }
        // History cap bounds growth on long-running installs; 20 entries is far more
        // than any single evaluation can emit, so dedup within a sample burst holds.
        let recent = baseline.recentEventFingerprints.suffix(16)
        var history = Array(recent)
        let filtered = events.filter { event in
            let fingerprint = Self.fingerprint(event: event, state: current)
            guard !history.contains(fingerprint) else { return false }
            history.append(fingerprint)
            return true
        }
        baseline.recentEventFingerprints = history
        return ChargingDetectionResult(events: filtered, baseline: baseline)
    }

    private func isInterruptionCandidate(_ state: VehicleState) -> Bool {
        guard !state.isComplete else { return false }
        switch state.chargingState {
        case .paused, .scheduled, .smartCharging: return false
        default: break
        }
        return state.chargerConnection == .disconnected || state.chargingState == .idle
    }

    private static func fingerprint(event: ChargingEvent, state: VehicleState) -> String {
        let timestamp = Int((state.vehicleReportedAt ?? state.fetchedAt).timeIntervalSince1970)
        return "\(state.vin)|\(event.identifierComponent)|\(timestamp)"
    }
}

