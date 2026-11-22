import Foundation
import Testing
@testable import Hisingen

private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

private func sample(_ index: Int, minute: Double, soc: Double, kw: Double?) -> HistoricalChargingSample {
    HistoricalChargingSample(id: Int64(index), sessionId: "s", vin: "VIN", timestamp: t0.addingTimeInterval(minute * 60),
                             soc: soc, powerKw: kw, voltageVolts: nil, currentAmps: nil, chargingType: nil)
}

/// Samples every minute for `observed` minutes out of `total`, with one unobserved stretch between.
private func samples(observed: Int, total: Int, kw: Double, endSoc: Double) -> [HistoricalChargingSample] {
    let gapStart = observed / 2
    let gap = total - observed
    var result: [HistoricalChargingSample] = []
    for minute in 0...total where !(minute > gapStart && minute < gapStart + gap) {
        result.append(sample(minute, minute: Double(minute), soc: 20 + (endSoc - 20) * Double(minute) / Double(total), kw: kw))
    }
    return result
}

@Suite("Charging session energy from partial observation")
struct ChargingSessionUndercountTests {
    private func summary(_ observed: Int, endSoc: Double = 90) -> ChargingSessionCalculatedSummary {
        let total = 300
        return ChargingSessionSummaryCalculator.calculate(
            startSoc: 20, terminalSoc: endSoc, startedAt: t0, endedAt: t0.addingTimeInterval(Double(total) * 60),
            samples: samples(observed: observed, total: total, kw: 10, endSoc: endSoc), usableCapacityKwh: 75)
    }

    @Test("A session seen for 70% of its length does not report 70% of its energy")
    func partialObservationFallsBackToChargeLevel() {
        let result = summary(215)
        #expect(result.sampleCoverage < 0.9)
        #expect(result.source == .socCapacityEstimate)
        #expect(abs(result.energyKwh - 0.70 * 75) < 0.01)
    }

    @Test("Full observation still integrates the power")
    func fullObservationIntegrates() {
        let result = summary(300)
        #expect(result.source == .observedPowerIntegration)
        #expect(abs(result.energyKwh - 50) < 0.5)
    }

    @Test("Partial observation that agrees with the charge level keeps the integration")
    func partialButConsistentKeepsIntegration() {
        // 10 kW for 254 observed minutes is 42.3 kWh; a 20 to 80% gain of 75 kWh is 45 kWh.
        let result = summary(255, endSoc: 80)
        #expect(result.sampleCoverage < 0.9)
        #expect(result.source == .observedPowerIntegration)
        #expect(abs(result.energyKwh - 42.33) < 0.5)
    }
}
