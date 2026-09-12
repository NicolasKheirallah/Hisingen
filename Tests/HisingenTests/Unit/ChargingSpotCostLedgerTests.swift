import Foundation
import Testing
@testable import Hisingen

/// End-to-end backfill: completed sessions inside spot-price coverage get priced exactly
/// once; uncovered sessions stay uncosted and are retried by a later, wider pass.
struct ChargingSpotCostLedgerTests {
    private let vin = "SPOT-TEST-VIN"
    private let start = Date(timeIntervalSince1970: 1_789_100_000)

    private func price(startHour: Double, hours: Double, sek: Double) -> ElectricityPricePoint {
        ElectricityPricePoint(
            startDate: start.addingTimeInterval(startHour * 3_600),
            endDate: start.addingTimeInterval((startHour + hours) * 3_600),
            sekPerKwh: sek
        )
    }

    private func ingest(_ ledger: ChargingSessionLedger, minutes: Double, soc: Double,
                        power: Double?, state: ChargingState) {
        ledger.ingest(
            ChargingSessionObservation(
                vin: vin, timestamp: start.addingTimeInterval(minutes * 60),
                soc: soc, chargingState: state,
                chargerConnection: power != nil ? .connected : .disconnected,
                powerKw: power, voltageVolts: nil, currentAmps: nil,
                chargingType: .ac, targetSoc: 80
            ),
            configuration: ChargingSessionLedgerConfiguration(
                usableCapacityKwh: 79, tariffPricePerKwh: 0.37,
                nightTariffEnabled: false, currencySymbol: "kr", locationName: nil
            ),
            recordingEnabled: true
        )
    }

    @Test func backfillPricesCoveredSessionsOnce() throws {
        let database = VehicleDatabase.inMemory()
        let ledger = database.charging
        // 10:00 → 12:00 at 11 kW, ending on the second stop observation.
        ingest(ledger, minutes: 0, soc: 20, power: 11, state: .charging)
        ingest(ledger, minutes: 60, soc: 30, power: 11, state: .charging)
        ingest(ledger, minutes: 120, soc: 40, power: 11, state: .charging)
        ingest(ledger, minutes: 125, soc: 40, power: nil, state: .idle)
        ingest(ledger, minutes: 130, soc: 40, power: nil, state: .idle)

        let session = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(session.spotEstimatedCost == nil)

        let prices = [price(startHour: 0, hours: 3, sek: 1.0)]
        let updated = ledger.backfillSpotEstimatedCosts(vin: vin, prices: prices)
        #expect(updated == 1)
        let priced = try #require(ledger.recentChargingSessions(for: vin).first)
        // Sample-integrated energy scaled to the authoritative (SoC-derived) ~15.8 kWh
        // at 1.0 kr — the estimate tracks the session's own energy figure.
        let spot = try #require(priced.spotEstimatedCost)
        #expect(abs(spot - priced.energyDeliveredKwh * 1.0) < 0.5)

        // Idempotent: the priced session no longer counts as missing.
        #expect(ledger.backfillSpotEstimatedCosts(vin: vin, prices: prices) == 0)
        #expect(ledger.sessionsMissingSpotCost(vin: vin).isEmpty)
    }

    @Test func uncoveredSessionsRemainPendingForLaterPasses() throws {
        let database = VehicleDatabase.inMemory()
        let ledger = database.charging
        ingest(ledger, minutes: 0, soc: 20, power: 11, state: .charging)
        ingest(ledger, minutes: 60, soc: 30, power: 11, state: .charging)
        ingest(ledger, minutes: 120, soc: 40, power: 11, state: .charging)
        ingest(ledger, minutes: 125, soc: 40, power: nil, state: .idle)
        ingest(ledger, minutes: 130, soc: 40, power: nil, state: .idle)

        // Prices covering only a fraction of the session window.
        let partial = [price(startHour: 0, hours: 1, sek: 1.0)]
        #expect(ledger.backfillSpotEstimatedCosts(vin: vin, prices: partial) == 0)
        #expect(ledger.recentChargingSessions(for: vin).first?.spotEstimatedCost == nil)
        #expect(ledger.sessionsMissingSpotCost(vin: vin).count == 1,
                "uncovered sessions must stay pending for a later, wider pass")

        // A wider series prices them.
        let wide = [price(startHour: 0, hours: 3, sek: 2.0)]
        #expect(ledger.backfillSpotEstimatedCosts(vin: vin, prices: wide) == 1)
        let spot = try #require(ledger.recentChargingSessions(for: vin).first?.spotEstimatedCost)
        #expect(abs(spot - 15.8 * 2.0) < 1.0)
    }
}
