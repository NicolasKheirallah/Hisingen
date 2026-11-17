import Foundation

/// Energy the charger delivered over one stretch, as the session-energy counter rose.
struct HomeEnergyInterval: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var kwh: Double
}

/// A completed charger session as Home Assistant knows it, before it is matched to a vehicle
/// and written into Hisingen's charging history.
struct HomeChargingSessionCandidate: Codable, Equatable, Sendable {
    /// Where the identity of the session comes from, strongest first. A stronger key replaces a
    /// weaker one on the row it describes, so the same physical session is never stored twice.
    enum KeyKind: String, Codable, Sendable {
        /// The charger vendor's own session identifier. The Home Assistant NexBlue integration
        /// exposes none; the slot exists so a future version or another charger can supply one.
        case vendorSessionID = "vendor_session_id"
        /// The vendor reported a finished session without an ID. Its time window identifies it.
        case vendorWindow = "vendor_window"
        /// An identifier minted by the durable capture component inside Home Assistant.
        case captureID = "ha_capture_id"
        /// Reconstructed from the recorder history of the charger's own sensors.
        case history = "ha_history"

        var rank: Int {
            switch self {
            case .vendorSessionID: return 4
            case .captureID: return 3
            case .vendorWindow: return 2
            case .history: return 1
            }
        }
    }

    var key: String
    var keyKind: KeyKind
    var chargerID: String
    var startedAt: Date
    var endedAt: Date
    /// What the charger metered. The battery-side estimate is a different number in a different column.
    var energyKwh: Double
    /// Which Home Assistant data produced `energyKwh`.
    var energySource: String
    /// The timestamp of the last reading behind the figure.
    var measuredAt: Date
    var intervals: [HomeEnergyInterval]
    var peakPowerKw: Double?
    /// Vehicle battery percent from a Home Assistant sensor, when the capture component had one.
    var vehicleStartPercent: Double?
    var vehicleEndPercent: Double?

    init(key: String, keyKind: KeyKind, chargerID: String, startedAt: Date, endedAt: Date,
         energyKwh: Double, energySource: String, measuredAt: Date, intervals: [HomeEnergyInterval] = [],
         peakPowerKw: Double? = nil, vehicleStartPercent: Double? = nil, vehicleEndPercent: Double? = nil) {
        self.key = key
        self.keyKind = keyKind
        self.chargerID = chargerID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.energyKwh = energyKwh
        self.energySource = energySource
        self.measuredAt = measuredAt
        self.intervals = intervals
        self.peakPowerKw = peakPowerKw
        self.vehicleStartPercent = vehicleStartPercent
        self.vehicleEndPercent = vehicleEndPercent
    }

    static func historyKey(chargerID: String, startedAt: Date) -> String {
        "ha:\(chargerID):\(Int(startedAt.timeIntervalSince1970.rounded()))"
    }

    static func captureKey(chargerID: String, captureID: String) -> String {
        "capture:\(chargerID):\(captureID)"
    }

    static func vendorKey(chargerID: String, sessionID: String) -> String {
        "vendor:\(chargerID):\(sessionID)"
    }

    /// Whether the intervals are fine enough to price slot by slot. A rise recorded across a long
    /// gap says how much arrived, not when, so pricing it by the clock would invent a profile.
    static let maximumPriceableInterval: TimeInterval = 20 * 60

    var hasPriceableIntervals: Bool {
        !intervals.isEmpty && intervals.allSatisfy { $0.end.timeIntervalSince($0.start) <= Self.maximumPriceableInterval }
    }

    var intervalEnergyKwh: Double { intervals.reduce(0) { $0 + $1.kwh } }
}

/// Rebuilds sessions from the recorder history of a charger's sensors.
///
/// The NexBlue integration keeps no session list, so a session is read out of the session-energy
/// counter: a run of readings that rise, bounded by a reset of the counter or by the cable coming
/// out. The key is the start of the first rise, which the recorder fixes for good, so syncing the
/// same history twice produces the same key twice.
enum HomeSessionReconstructor {
    /// A fall smaller than this is sensor noise; a bigger one is the counter starting over.
    static let resetThresholdKwh = 0.05
    /// Sessions under this are noise from a charger that woke and slept.
    static let minimumSessionKwh = 0.1
    /// The newest session in the window counts as finished only after this long without a rise.
    static let settleAfter: TimeInterval = 30 * 60

    static func reconstruct(chargerID: String, status: [HAHistoryPoint], energy: [HAHistoryPoint],
                            power: [HAHistoryPoint] = [], now: Date) -> [HomeChargingSessionCandidate] {
        let readings = numericPoints(energy)
        guard readings.count >= 2 else { return [] }

        let statusTimeline = status.sorted { $0.at < $1.at }
        let unplugTimes = unplugTransitions(statusTimeline)
        let currentStatus = statusTimeline.last.map { HomeChargerStatus(haState: $0.state) }

        // Split the readings into runs. A run ends where the counter resets or the cable came out
        // between two readings.
        var runs: [[(at: Date, value: Double)]] = [[readings[0]]]
        var boundaryBefore: [Bool] = [false]
        for (previous, next) in zip(readings, readings.dropFirst()) {
            let reset = next.value < previous.value - resetThresholdKwh
            let unplugged = unplugTimes.contains { $0 > previous.at && $0 <= next.at }
            if reset || unplugged {
                runs.append([next])
                boundaryBefore.append(true)
            } else {
                runs[runs.count - 1].append(next)
            }
        }

        var candidates: [HomeChargingSessionCandidate] = []
        for (index, run) in runs.enumerated() {
            let isFirst = index == 0
            let isLast = index == runs.count - 1
            // The first run starts at the edge of the fetched window. Unless the counter was at
            // its floor there, the start is outside what the recorder returned and the run is skipped:
            // keying a partial session would give the same session a second key on a later sync.
            if isFirst, let first = run.first, first.value > resetThresholdKwh { continue }

            var intervals: [HomeEnergyInterval] = []
            for (a, b) in zip(run, run.dropFirst()) {
                let delta = b.value - a.value
                guard delta > 0, b.at > a.at else { continue }
                intervals.append(HomeEnergyInterval(start: a.at, end: b.at, kwh: delta))
            }
            let head = boundaryBefore[index] ? max(0, (run.first?.value ?? 0)) : 0
            let total = intervals.reduce(0) { $0 + $1.kwh } + head
            guard total >= minimumSessionKwh, let first = intervals.first, let last = intervals.last else { continue }

            if isLast {
                let settled = now.timeIntervalSince(last.end) >= settleAfter
                let stillCharging = currentStatus?.isChargingEnabled ?? false
                guard settled, !stillCharging else { continue }
            }

            let peak = peakPower(power, from: first.start, to: last.end)
            candidates.append(HomeChargingSessionCandidate(
                key: HomeChargingSessionCandidate.historyKey(chargerID: chargerID, startedAt: first.start),
                keyKind: .history, chargerID: chargerID,
                startedAt: first.start, endedAt: last.end, energyKwh: total,
                energySource: "ha_session_energy_sensor", measuredAt: last.end,
                intervals: intervals, peakPowerKw: peak
            ))
        }
        return candidates
    }

    private static func numericPoints(_ points: [HAHistoryPoint]) -> [(at: Date, value: Double)] {
        var byTime: [Date: Double] = [:]
        for point in points {
            guard let value = Double(point.state.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { continue }
            byTime[point.at] = value
        }
        return byTime.sorted { $0.key < $1.key }.map { (at: $0.key, value: $0.value) }
    }

    private static func unplugTransitions(_ timeline: [HAHistoryPoint]) -> [Date] {
        var times: [Date] = []
        var previousUnplugged = false
        for point in timeline {
            let unplugged = HomeChargerStatus(haState: point.state) == .unplugged
            if unplugged && !previousUnplugged { times.append(point.at) }
            previousUnplugged = unplugged
        }
        return times
    }

    private static func peakPower(_ points: [HAHistoryPoint], from start: Date, to end: Date) -> Double? {
        points.filter { $0.at >= start && $0.at <= end }
            .compactMap { Double($0.state) }
            .max()
    }
}

/// A charging session Hisingen itself observed from the vehicle, reduced to what matching needs.
struct ObservedVehicleSession: Equatable, Sendable {
    var id: String
    var vin: String
    var start: Date
    var end: Date
}

/// Decides which vehicle, if any, a charger session belongs to.
enum HomeSessionAttribution {
    enum Reason: Equatable, Sendable {
        /// The charger is shared and the paired vehicle's own charging does not overlap.
        case sharedChargerWithoutOverlap
        /// A different vehicle's charging overlaps, alone or alongside the paired one.
        case overlapsAnotherVehicle
    }

    enum Decision: Equatable, Sendable {
        /// Fill the wallbox columns on a row Hisingen already holds for the paired vehicle.
        case enrich(rowID: String, vin: String)
        /// No vehicle-side row exists; add one for the paired vehicle (explicit pairing, dedicated charger).
        case newForVehicle(vin: String)
        case unassigned(Reason)
    }

    /// The share of the shorter session that must overlap for two sessions to be the same charge.
    static let requiredOverlap = 0.5

    static func decide(candidate: HomeChargingSessionCandidate, pairing: HomeChargingPairing,
                       observed: [ObservedVehicleSession]) -> Decision {
        let overlapping = observed.filter { overlapFraction(candidate: candidate, session: $0) >= requiredOverlap }
        let others = overlapping.filter { !pairing.isPaired(toVehicle: $0.vin) }
        if !others.isEmpty { return .unassigned(.overlapsAnotherVehicle) }
        let own = overlapping.filter { pairing.isPaired(toVehicle: $0.vin) }
        if let best = own.max(by: { overlapSeconds(candidate: candidate, session: $0) < overlapSeconds(candidate: candidate, session: $1) }) {
            return .enrich(rowID: best.id, vin: pairing.vin)
        }
        return pairing.isSharedCharger ? .unassigned(.sharedChargerWithoutOverlap) : .newForVehicle(vin: pairing.vin)
    }

    static func overlapSeconds(candidate: HomeChargingSessionCandidate, session: ObservedVehicleSession) -> TimeInterval {
        max(0, min(candidate.endedAt, session.end).timeIntervalSince(max(candidate.startedAt, session.start)))
    }

    static func overlapFraction(candidate: HomeChargingSessionCandidate, session: ObservedVehicleSession) -> Double {
        let shorter = max(60, min(candidate.endedAt.timeIntervalSince(candidate.startedAt),
                                  session.end.timeIntervalSince(session.start)))
        return overlapSeconds(candidate: candidate, session: session) / shorter
    }
}
