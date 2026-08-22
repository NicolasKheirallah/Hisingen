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

enum BatteryHealthEstimator {
    static func estimate(
        state: VehicleState,
        chargingSessions: [ChargingSession],
        specification: VehicleSpecificationOverride? = nil,
        now: Date = Date()
    ) -> BatteryHealthEstimate? {
        guard state.powertrain.hasElectricRange else { return nil }
        let referenceCapacity = specification?.usableBatteryCapacityKwh
            ?? positive(state.factoryUsableBatteryCapacityKwh)
        let referenceRange = specification?.wltpRangeKm
            ?? positive(state.model.nominalWltpRangeKm)
        guard let referenceCapacity, referenceCapacity >= 5 else { return nil }

        var signals: [BatteryHealthSignal] = []
        if let capacity = chargeIntegratedCapacity(from: chargingSessions), capacity > 0 {
            signals.append(BatteryHealthSignal(
                id: "charge-power", title: L10n.text("charge-power integration"),
                estimatedSOHPercent: bounded(capacity / referenceCapacity * 100, lower: 65, upper: 103),
                weight: 0.55,
                explanation: L10n.format("Observed charger power integrated over time and divided by the battery percentage gained suggests %.1f kWh. A charging-loss allowance is applied.", capacity)
            ))
        }

        if let range = state.rangeKm.map(Double.init), let soc = state.batteryPercentage,
           soc >= 20, let referenceRange, referenceRange > 0 {
            let expectedAtSOC = referenceRange * soc / 100 * expectedRangeFactor(at: state.weather?.temperatureCelsius)
            if expectedAtSOC > 0 {
                signals.append(BatteryHealthSignal(
                    id: "range", title: L10n.text("range versus model reference"),
                    estimatedSOHPercent: bounded(range / expectedAtSOC * 100, lower: 60, upper: 105),
                    weight: 0.20,
                    explanation: L10n.format("Vehicle-reported range at %.0f%% charge is compared with the configured WLTP/model reference and adjusted for available ambient temperature.", soc)
                ))
            }
        }

        if let observed = state.batteryDiagnostics?.averageConsumption, observed > 5,
           let referenceWhPerKm = state.model.averageConsumptionWhPerKm {
            signals.append(BatteryHealthSignal(
                id: "consumption", title: L10n.text("long-term consumption"),
                estimatedSOHPercent: bounded((referenceWhPerKm / 10) / observed * 100, lower: 65, upper: 105),
                weight: 0.10,
                explanation: L10n.text("Long-term vehicle-reported consumption is compared with the model reference. This is a weak signal because speed, climate and terrain dominate consumption.")
            ))
        }

        if let prior = ageAndMileagePrior(state: state, now: now) {
            signals.append(BatteryHealthSignal(
                id: "age-mileage", title: L10n.text("age and mileage prior"),
                estimatedSOHPercent: prior, weight: 0.15,
                explanation: L10n.text("A conservative fleet-style prior based on model year and odometer stabilizes sparse estimates; it is not vehicle telemetry.")
            ))
        }

        guard !signals.isEmpty else { return nil }
        let totalWeight = signals.reduce(0) { $0 + $1.weight }
        let raw = signals.reduce(0) { $0 + $1.estimatedSOHPercent * $1.weight } / totalWeight
        let soh = rounded(bounded(raw, lower: 55, upper: 100))
        let confidence: BatteryHealthConfidence = signals.contains(where: { $0.id == "charge-power" }) && signals.count >= 3
            ? .high : (signals.count >= 2 ? .medium : .low)
        return BatteryHealthEstimate(
            stateOfHealthPercent: soh, degradationPercent: rounded(100 - soh),
            estimatedUsableCapacityKwh: rounded(referenceCapacity * soh / 100),
            referenceUsableCapacityKwh: referenceCapacity, confidence: confidence, signals: signals
        )
    }

    static func chargeIntegratedCapacity(from sessions: [ChargingSession]) -> Double? {
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
            return inputKwh * 0.90 / (socGain / 100)
        }.filter { $0 >= 5 && $0 <= 150 }.sorted()
        guard !estimates.isEmpty else { return nil }
        return estimates[estimates.count / 2]
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

    private static func expectedRangeFactor(at temperature: Double?) -> Double {
        guard let temperature else { return 0.90 }
        switch temperature {
        case ..<(-10): return 0.64
        case -10..<0: return 0.72
        case 0..<10: return 0.82
        case 10..<18: return 0.91
        case 18..<27: return 0.98
        case 27..<35: return 0.92
        default: return 0.84
        }
    }

    private static func positive(_ value: Double) -> Double? { value > 0 ? value : nil }
    private static func bounded(_ value: Double, lower: Double, upper: Double) -> Double { min(max(value, lower), upper) }
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
