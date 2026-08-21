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
    var lastEventFingerprint: String?
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
            lowBatteryNotified: false,
            lastEventFingerprint: nil
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
        baseline.lastEventFingerprint = previous.lastEventFingerprint
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
        let filtered = events.filter { event in
            let fingerprint = Self.fingerprint(event: event, state: current)
            if fingerprint == previous.lastEventFingerprint { return false }
            baseline.lastEventFingerprint = fingerprint
            return true
        }
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

