import Foundation
import Testing
@testable import Hisingen

/// Volvo's API supplies a since-charge consumption figure but no energy total, so Hisingen
/// derives the energy from the distance driven since the ledger's last completed charge.
/// These pins hold the estimator's honesty rules: any missing or contradictory input keeps
/// the row silent instead of producing a number.
struct VolvoChargeEnergyEstimatorTests {

    @Test("Consumption × distance is the Wh answer")
    func computesWh() {
        let wh = VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(
            consumptionSinceChargeKwhPer100Km: 18.5,
            odometerKmNow: 12_340.0,
            odometerKmAtLastChargeEnd: 12_300.0
        )
        // 18.5 kWh/100 km × 40 km = 7.4 kWh = 7 400 Wh.
        #expect(wh == 7_400)
    }

    @Test("Any missing input keeps the estimate silent")
    func missingInputsStaySilent() {
        #expect(VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(consumptionSinceChargeKwhPer100Km: nil, odometerKmNow: 100, odometerKmAtLastChargeEnd: 90) == nil)
        #expect(VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(consumptionSinceChargeKwhPer100Km: 18, odometerKmNow: nil, odometerKmAtLastChargeEnd: 90) == nil)
        #expect(VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(consumptionSinceChargeKwhPer100Km: 18, odometerKmNow: 100, odometerKmAtLastChargeEnd: nil) == nil)
    }

    @Test("A negative distance means the odometer samples disagree and the row stays silent")
    func backwardsDistanceStaysSilent() {
        #expect(VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(consumptionSinceChargeKwhPer100Km: 18, odometerKmNow: 90, odometerKmAtLastChargeEnd: 100) == nil)
    }

    @Test("Distances past the trust horizon stay silent")
    func farDistanceStaysSilent() {
        #expect(VolvoChargeEnergyEstimator.energyUsedSinceChargeWh(consumptionSinceChargeKwhPer100Km: 18, odometerKmNow: 3_400, odometerKmAtLastChargeEnd: 1_400) == nil)
    }

    @Test("The odometer sample nearest the session end wins")
    func nearestSampleWins() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let records = [
        HistoricalTelemetryRecord(
            id: 1, vin: "V", timestamp: base.addingTimeInterval(-18_000),
            odometerKm: 100, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: nil, averageConsumptionUnit: nil,
            ambientTemperatureCelsius: nil, latitude: nil, longitude: nil
        ),
        HistoricalTelemetryRecord(
            id: 2, vin: "V", timestamp: base.addingTimeInterval(-600),
            odometerKm: 131.5, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: nil, averageConsumptionUnit: nil,
            ambientTemperatureCelsius: nil, latitude: nil, longitude: nil
        ),
        HistoricalTelemetryRecord(
            id: 3, vin: "V", timestamp: base.addingTimeInterval(600),
            odometerKm: 133, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: nil, averageConsumptionUnit: nil,
            ambientTemperatureCelsius: nil, latitude: nil, longitude: nil
        )
        ]
        #expect(VolvoChargeEnergyEstimator.odometerKm(in: records, nearest: base) == 131.5)
    }

    @Test("Samples without an odometer value, or beyond the tolerance, are skipped")
    func unusableSamplesAreSkipped() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let far =         HistoricalTelemetryRecord(
            id: 1, vin: "V", timestamp: date.addingTimeInterval(-43_200),
            odometerKm: 90, tripManualKm: nil, tripAutomaticKm: nil,
            averageConsumption: nil, averageConsumptionUnit: nil,
            ambientTemperatureCelsius: nil, latitude: nil, longitude: nil
        )
        #expect(VolvoChargeEnergyEstimator.odometerKm(in: [far], nearest: date) == nil)
    }
}
