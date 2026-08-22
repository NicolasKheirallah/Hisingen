import Foundation

enum BatteryHealthConfidence: String, Codable, Sendable {
    case low, medium, high

    var displayName: String {
        switch self {
        case .low: return L10n.text("Low confidence")
        case .medium: return L10n.text("Medium confidence")
        case .high: return L10n.text("High confidence")
        }
    }
}

struct BatteryHealthSignal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let estimatedSOHPercent: Double
    let weight: Double
    let explanation: String
}

struct BatteryHealthEstimate: Equatable, Sendable {
    let stateOfHealthPercent: Double
    let degradationPercent: Double
    let estimatedUsableCapacityKwh: Double
    let referenceUsableCapacityKwh: Double
    let confidence: BatteryHealthConfidence
    let signals: [BatteryHealthSignal]

    var methodologySummary: String {
        let names = signals.map(\.title).joined(separator: ", ")
        return L10n.format(
            "Calculated estimate — not a battery-management-system measurement. Hisingen combines %@ and weights each signal by its reliability. Driving style, weather, charging losses, tyre pressure, vehicle variant and incomplete history can materially affect the result.",
            names
        )
    }
}

struct VehicleSpecificationOverride: Codable, Equatable, Sendable {
    var usableBatteryCapacityKwh: Double?
    var wltpRangeKm: Double?
    var isEmpty: Bool { usableBatteryCapacityKwh == nil && wltpRangeKm == nil }
}

/// The last stored SoH estimate, fed back in so a fresh calculation can be smoothed toward it
/// instead of standing entirely on its own. Deliberately holds only primitives rather than the
/// SQLite-backed `BatteryHealthRecord` — this file stays a pure `Domain` type with no dependency
/// on `Services/Persistence`.
struct BatteryHealthPriorEstimate: Sendable {
    let stateOfHealthPercent: Double
    let timestamp: Date
}

struct ChargeIntegratedCapacityEstimate: Equatable, Sendable {
    let capacityKwh: Double
    let sessionCount: Int
    /// (Q3 − Q1) ÷ median across qualifying sessions — how much the sessions disagree with each
    /// other, relative to their own scale. 0 when too few sessions exist to form quartiles.
    let relativeSpread: Double
}

enum BatteryHealthEstimator {
    /// Estimates older than this are treated as a cold start rather than a smoothing anchor —
    /// enough time has passed that real degradation could have happened, and anchoring to a
    /// stale number would suppress a genuine change for too long.
    private static let smoothingMaxAge: TimeInterval = 14 * 24 * 60 * 60

    static func estimate(
        state: VehicleState,
        chargingSessions: [ChargingSession],
        specification: VehicleSpecificationOverride? = nil,
        previous: BatteryHealthPriorEstimate? = nil,
        now: Date = Date()
    ) -> BatteryHealthEstimate? {
        guard state.powertrain.hasElectricRange else { return nil }
        // Prefer, in order: a user-entered VIN-specific override, the provider's own reported
        // pack spec (Volvo's `batteryCapacityKWH` — exact for that VIN), then the generic
        // per-model-family table (can't distinguish Standard Range/Long Range trims).
        let referenceCapacity = specification?.usableBatteryCapacityKwh
            ?? state.reportedBatteryCapacityKwh.flatMap(positive)
            ?? positive(state.factoryUsableBatteryCapacityKwh)
        let referenceRange = specification?.wltpRangeKm
            ?? positive(state.model.nominalWltpRangeKm)
        guard let referenceCapacity, referenceCapacity >= 5 else { return nil }

        var signals: [BatteryHealthSignal] = []
        if let charge = chargeIntegratedCapacity(from: chargingSessions), charge.capacityKwh > 0 {
            // More qualifying sessions, and tighter agreement between them, earn more trust —
            // rather than always weighting a single noisy session the same as five consistent
            // ones. Saturates at 5 sessions; a wide spread floors out at 0.4 rather than
            // vanishing, since even disagreeing sessions are still real telemetry.
            let sessionConfidence = min(1.0, 0.4 + 0.15 * Double(charge.sessionCount - 1))
            let agreementConfidence = max(0.4, 1.0 - charge.relativeSpread)
            let weight = 0.55 * sessionConfidence * agreementConfidence
            signals.append(BatteryHealthSignal(
                id: "charge-power", title: L10n.text("charge-power integration"),
                estimatedSOHPercent: bounded(charge.capacityKwh / referenceCapacity * 100, lower: 65, upper: 103),
                weight: weight,
                explanation: L10n.format("Observed charger power integrated over time and divided by the battery percentage gained across %.0f qualifying session(s) suggests %.1f kWh. A charging-loss allowance based on the reported AC/DC type is applied.", Double(charge.sessionCount), charge.capacityKwh)
            ))
        }

        if let range = state.rangeKm.map(Double.init), let soc = state.batteryPercentage,
           soc >= 20, let referenceRange, referenceRange > 0 {
            let expectedAtSOC = referenceRange * soc / 100 * expectedRangeFactor(at: recentAmbientTemperature(state: state))
            if expectedAtSOC > 0 {
                signals.append(BatteryHealthSignal(
                    id: "range", title: L10n.text("range versus model reference"),
                    estimatedSOHPercent: bounded(range / expectedAtSOC * 100, lower: 60, upper: 105),
                    weight: 0.20,
                    explanation: L10n.format("Vehicle-reported range at %.0f%% charge is compared with the configured WLTP/model reference and adjusted for recent ambient temperature.", soc)
                ))
            }
        }

        // `averageConsumption` is reliably kWh/100km for Volvo (the API tags its own unit); for
        // Polestar it's an unlabeled raw gRPC double whose unit has not been independently
        // verified. The plausibility band below (5–60 kWh/100km covers every real BEV) exists
        // specifically so an unverified 10x unit mismatch degrades to "signal skipped" instead
        // of silently corrupting the blended SoH.
        if let observed = state.batteryDiagnostics?.averageConsumption, observed > 5, observed < 60,
           let referenceWhPerKm = state.model.averageConsumptionWhPerKm {
            signals.append(BatteryHealthSignal(
                id: "consumption", title: L10n.text("long-term consumption"),
                estimatedSOHPercent: bounded((referenceWhPerKm / 10) / observed * 100, lower: 65, upper: 105),
                weight: 0.10,
                explanation: L10n.text("Long-term vehicle-reported consumption is compared with the model reference. This is a weak signal because speed, climate and terrain dominate consumption.")
            ))
        }

        if let prior = ageAndMileagePrior(state: state, now: now) {
            // A true prior: it carries more weight when little else is available, and steps
            // aside as real telemetry-backed signals accumulate, rather than always counting
            // for a flat 15% regardless of how much better evidence already exists.
            let priorWeight = signals.isEmpty ? 0.35 : (signals.count == 1 ? 0.25 : 0.15)
            signals.append(BatteryHealthSignal(
                id: "age-mileage", title: L10n.text("age and mileage prior"),
                estimatedSOHPercent: prior, weight: priorWeight,
                explanation: L10n.text("A conservative fleet-style prior based on model year and odometer stabilizes sparse estimates; it is not vehicle telemetry.")
            ))
        }

        guard !signals.isEmpty else { return nil }
        let totalWeight = signals.reduce(0) { $0 + $1.weight }
        let raw = signals.reduce(0) { $0 + $1.estimatedSOHPercent * $1.weight } / totalWeight
        let rawSoh = bounded(raw, lower: 55, upper: 100)
        let chargePowerIsStrong = signals.contains { $0.id == "charge-power" && $0.weight >= 0.45 }
        let confidence: BatteryHealthConfidence = chargePowerIsStrong && signals.count >= 3
            ? .high : (signals.count >= 2 ? .medium : .low)
        let soh = smoothed(rawSoh, toward: previous, confidence: confidence, now: now)
        return BatteryHealthEstimate(
            stateOfHealthPercent: soh, degradationPercent: rounded(100 - soh),
            estimatedUsableCapacityKwh: rounded(referenceCapacity * soh / 100),
            referenceUsableCapacityKwh: referenceCapacity, confidence: confidence, signals: signals
        )
    }

    /// Blends a fresh calculation with the last stored estimate rather than presenting each
    /// refresh's number as if it stood entirely on its own — a battery can't materially gain or
    /// lose SoH between two polls minutes apart, so refresh-to-refresh noise (one odd charging
    /// session, a cold morning) shouldn't visibly move the displayed number. How much the new
    /// reading is trusted scales with `confidence`, so a well-evidenced estimate can still move
    /// the number meaningfully in one step, while a low-confidence one nudges it gently.
    private static func smoothed(
        _ rawSoh: Double, toward previous: BatteryHealthPriorEstimate?,
        confidence: BatteryHealthConfidence, now: Date
    ) -> Double {
        guard let previous, now.timeIntervalSince(previous.timestamp) <= smoothingMaxAge else {
            return rounded(rawSoh)
        }
        let alpha: Double
        switch confidence {
        case .high: alpha = 0.6
        case .medium: alpha = 0.4
        case .low: alpha = 0.25
        }
        return rounded(previous.stateOfHealthPercent + alpha * (rawSoh - previous.stateOfHealthPercent))
    }

    /// Real-world AC/DC conversion loss differs materially: AC charging still passes through the
    /// vehicle's onboard charger (roughly 10–15% loss), while DC fast charging mostly bypasses
    /// it, leaving mainly internal-resistance/BMS-balancing overhead (roughly 2–5%). `.unknown`
    /// (including every sample recorded before charging type was captured) keeps the original
    /// blended estimate.
    private static func chargingLossFactor(for type: ChargingType) -> Double {
        switch type {
        case .ac: return 0.88
        case .dc: return 0.97
        case .wireless, .none, .unknown: return 0.90
        }
    }

    static func chargeIntegratedCapacity(from sessions: [ChargingSession]) -> ChargeIntegratedCapacityEstimate? {
        let estimates = sessions.compactMap { session -> Double? in
            let samples = session.samples.sorted { $0.timestamp < $1.timestamp }
            guard samples.count >= 3, let first = samples.first, let last = samples.last else { return nil }
            let socGain = last.batteryPercentage - first.batteryPercentage
            guard socGain >= 10 else { return nil }
            var inputKwh = 0.0
            for pair in zip(samples, samples.dropFirst()) {
                guard let p0 = pair.0.powerWatts, let p1 = pair.1.powerWatts, p0 > 0, p1 > 0 else { continue }
                let seconds = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
                guard seconds > 0, seconds <= 20 * 60 else { continue }
                inputKwh += (Double(p0 + p1) / 2) / 1_000 * seconds / 3_600
            }
            guard inputKwh >= 1 else { return nil }
            let dominantType = samples.map(\.chargingType)
                .filter { $0 != .unknown }
                .reduce(into: [ChargingType: Int]()) { counts, type in counts[type, default: 0] += 1 }
                .max { $0.value < $1.value }?.key ?? .unknown
            return inputKwh * chargingLossFactor(for: dominantType) / (socGain / 100)
        }.filter { $0 >= 5 && $0 <= 150 }.sorted()
        guard !estimates.isEmpty else { return nil }
        let median = estimates[estimates.count / 2]
        guard median > 0 else { return nil }
        var relativeSpread = 0.0
        if estimates.count >= 4 {
            let q1 = estimates[estimates.count / 4]
            let q3 = estimates[(estimates.count * 3) / 4]
            relativeSpread = (q3 - q1) / median
        }
        return ChargeIntegratedCapacityEstimate(capacityKwh: median, sessionCount: estimates.count, relativeSpread: relativeSpread)
    }

    private static func ageAndMileagePrior(state: VehicleState, now: Date) -> Double? {
        let year = state.modelYear.flatMap(Int.init)
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        guard year != nil || state.odometerKm != nil else { return nil }
        let age = Double(max(0, currentYear - (year ?? currentYear)))
        let loss = (age == 0 ? 0.5 : 1.8 + max(0, age - 1) * 1.1)
            + Double(state.odometerKm ?? 0) / 20_000 * 0.7
        return bounded(100 - loss, lower: 70, upper: 100)
    }

    /// (temperature °C, expected fraction of WLTP range) at the center of each of the original
    /// step-function's bands. Interpolating linearly between them removes the artificial
    /// discontinuities a plain bucket lookup has at each boundary (e.g. 17.9°C vs 18.0°C used to
    /// jump by 0.07) while keeping the same characteristic value at each band's typical
    /// temperature; outside the first/last anchor the factor holds flat, matching the original
    /// unbounded `..<` / `default` cases.
    private static let temperatureRangeFactorAnchors: [(temp: Double, factor: Double)] = [
        (-15, 0.64), (-5, 0.72), (5, 0.82), (14, 0.91), (22.5, 0.98), (31, 0.92), (40, 0.84)
    ]

    /// `VehicleWeather` is fetched on its own schedule and carries its own `timestamp`,
    /// independent of when `rangeKm`/`batteryPercentage` were last reported (`state.dataTimestamp`)
    /// — a car asleep for hours can have a fresh weather reading paired with a stale range
    /// reading. Applying today's temperature correction to that stale range would mismatch cause
    /// and effect, so the reading is only used when it's within a few hours of the range data it's
    /// meant to explain; otherwise this falls back to `expectedRangeFactor`'s temperature-unknown
    /// default.
    private static func recentAmbientTemperature(state: VehicleState) -> Double? {
        guard let weather = state.weather, let timestamp = weather.timestamp,
              abs(timestamp.timeIntervalSince(state.dataTimestamp)) <= 3 * 60 * 60 else { return nil }
        return weather.temperatureCelsius
    }

    private static func expectedRangeFactor(at temperature: Double?) -> Double {
        guard let temperature else { return 0.90 }
        let anchors = temperatureRangeFactorAnchors
        if temperature <= anchors.first!.temp { return anchors.first!.factor }
        if temperature >= anchors.last!.temp { return anchors.last!.factor }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where temperature <= upper.temp {
            let fraction = (temperature - lower.temp) / (upper.temp - lower.temp)
            return lower.factor + fraction * (upper.factor - lower.factor)
        }
        return anchors.last!.factor
    }

    private static func positive(_ value: Double) -> Double? { value > 0 ? value : nil }
    private static func bounded(_ value: Double, lower: Double, upper: Double) -> Double { min(max(value, lower), upper) }
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
