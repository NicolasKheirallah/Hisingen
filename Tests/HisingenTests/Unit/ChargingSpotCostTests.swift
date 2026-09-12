import Foundation
import Testing
@testable import Hisingen

/// Pins the market-price session estimator: trapezoidal sample energy priced by the hourly
/// (or quarterly) spot series at each interval's midpoint, scaled to the authoritative
/// session energy, and `nil` — never an invented rate — whenever the price series does not
/// fully cover the charged window.
struct ChargingSpotCostTests {
    private let zoneStart = Date(timeIntervalSince1970: 1_789_100_000)

    private func price(startHour: Double, hours: Double, sek: Double) -> ElectricityPricePoint {
        ElectricityPricePoint(
            startDate: zoneStart.addingTimeInterval(startHour * 3_600),
            endDate: zoneStart.addingTimeInterval((startHour + hours) * 3_600),
            sekPerKwh: sek
        )
    }

    private func sample(minute: Double, powerKw: Double?) -> HistoricalChargingSample {
        HistoricalChargingSample(
            id: .min, sessionId: "s", vin: "V",
            timestamp: zoneStart.addingTimeInterval(minute * 60),
            soc: 0, powerKw: powerKw, voltageVolts: nil, currentAmps: nil, chargingType: nil
        )
    }

    @Test func pricesConstantPowerAcrossTwoHourlyRates() {
        let prices = [price(startHour: 0, hours: 1, sek: 1.0), price(startHour: 1, hours: 1, sek: 2.0)]
        // An intermediate sample at the rate boundary so each hour prices its own energy:
        // a single two-hour interval is priced entirely at its midpoint rate by design.
        let samples = [sample(minute: 0, powerKw: 11), sample(minute: 60, powerKw: 11),
                       sample(minute: 120, powerKw: 11)]
        let cost = ChargingSessionLedger.spotAwareCost(
            from: samples, prices: prices,
            sessionStart: zoneStart, sessionEnd: zoneStart.addingTimeInterval(7_200),
            scaleToEnergyKwh: 22
        )
        // 11 kWh at 1.0 + 11 kWh at 2.0 = 33 SEK
        #expect(abs((cost ?? 0) - 33.0) < 0.001)
    }

    @Test func scalesToAuthoritativeSessionEnergy() {
        let prices = [price(startHour: 0, hours: 2, sek: 1.5)]
        let samples = [sample(minute: 0, powerKw: 11), sample(minute: 120, powerKw: 11)]
        let cost = ChargingSessionLedger.spotAwareCost(
            from: samples, prices: prices,
            sessionStart: zoneStart, sessionEnd: zoneStart.addingTimeInterval(7_200),
            scaleToEnergyKwh: 10
        )
        // Integrated 22 kWh × 1.5 = 33, scaled to the authoritative 10 kWh → 15.
        #expect(abs((cost ?? 0) - 15.0) < 0.001)
    }

    @Test func uncoveredWindowStaysUncosted() {
        let prices = [price(startHour: 0, hours: 1, sek: 1.0)]
        let samples = [sample(minute: 0, powerKw: 11), sample(minute: 120, powerKw: 11)]
        let cost = ChargingSessionLedger.spotAwareCost(
            from: samples, prices: prices,
            sessionStart: zoneStart, sessionEnd: zoneStart.addingTimeInterval(7_200),
            scaleToEnergyKwh: 22
        )
        #expect(cost == nil, "session overruning the price coverage must stay uncosted")
    }

    @Test func pollingGapsAndSparseSamplesRefuseToPrice() {
        let prices = [price(startHour: 0, hours: 6, sek: 1.0)]
        // Single sample: nothing to integrate.
        #expect(ChargingSessionLedger.spotAwareCost(
            from: [sample(minute: 0, powerKw: 11)], prices: prices,
            sessionStart: zoneStart, sessionEnd: zoneStart.addingTimeInterval(600),
            scaleToEnergyKwh: 1
        ) == nil)
        // A gap beyond the estimable threshold is skipped; a session made only of gaps
        // integrates nothing and must not produce a zero-ish fabricated cost.
        let gapped = [sample(minute: 0, powerKw: 11),
                      sample(minute: 60, powerKw: nil),
                      sample(minute: 500, powerKw: 11)]
        #expect(ChargingSessionLedger.spotAwareCost(
            from: gapped, prices: prices,
            sessionStart: zoneStart, sessionEnd: zoneStart.addingTimeInterval(500 * 60),
            scaleToEnergyKwh: 5
        ) == nil)
    }
}
