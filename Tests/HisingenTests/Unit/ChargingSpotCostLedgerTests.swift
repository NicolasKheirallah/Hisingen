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
        // at 1.0 kr – the estimate tracks the session's own energy figure.
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

    @Test func dcAndManuallyEditedSessionsAreExcludedFromHomeSpotBackfill() throws {
        let database = VehicleDatabase.inMemory()
        let ledger = database.charging
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        let config = ChargingSessionLedgerConfiguration(usableCapacityKwh: 79, tariffPricePerKwh: 2.0,
                                                        currencySymbol: "kr", locationName: "Ionity")

        // 1. Auto-recorded DC session starts as public and receives zero spot backfill.
        for (offset, soc, kw, state) in [
            (0, 20.0, 140.0, ChargingState.charging),
            (60, 50.0, 120.0, ChargingState.charging),
            (65, 50.0, 0.0, ChargingState.idle),
            (70, 50.0, 0.0, ChargingState.idle)
        ] {
            ledger.ingest(
                ChargingSessionObservation(
                    vin: vin, timestamp: base.addingTimeInterval(Double(offset) * 60), soc: soc,
                    chargingState: state, chargerConnection: .connected,
                    powerKw: kw > 0 ? kw : nil, voltageVolts: nil, currentAmps: nil,
                    chargingType: .dc, targetSoc: 80
                ),
                configuration: config,
                recordingEnabled: true
            )
        }
        let dcSession = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(dcSession.place == .publicCharging)

        // 2. Home AC session recorded and then manually edited with a receipt stays excluded.
        let homeID = ledger.startChargingSession(vin: vin, startSoc: 20, place: .home,
                                                 startedAt: base.addingTimeInterval(7_200))
        ledger.completeChargingSession(id: homeID, endSoc: 50, energyDeliveredKwh: 20,
                                       peakPowerKw: 11, averagePowerKw: 11,
                                       endedAt: base.addingTimeInterval(10_800))
        let originalHome = try #require(ledger.sessionsMissingSpotCost(vin: vin).first)
        #expect(ledger.updateSpotEstimatedCost(for: originalHome, cost: 18))
        ledger.updateChargingSessionDetails(
            id: homeID, vin: vin, startedAt: base.addingTimeInterval(7_200),
            endedAt: base.addingTimeInterval(10_800), locationName: "Home", place: .home,
            energyKwh: 20, totalCost: 44, pricePerKwh: 2.2
        )

        let prices = [price(startHour: 0, hours: 5, sek: 1.0)]
        #expect(ledger.sessionsMissingSpotCost(vin: vin).isEmpty)
        #expect(ledger.backfillSpotEstimatedCosts(vin: vin, prices: prices) == 0)

        let editedHome = try #require(ledger.recentChargingSessions(for: vin).first { $0.id == homeID })
        #expect(editedHome.costManuallyEdited)
        #expect(editedHome.spotEstimatedCost == nil)
        #expect(editedHome.estimatedCost == 44)
        #expect(!ledger.updateSpotEstimatedCost(for: originalHome, cost: 18))
    }

    @Test func renamingARecordedSessionKeepsAutomaticPricing() throws {
        let database = VehicleDatabase.inMemory()
        let ledger = database.charging
        let end = start.addingTimeInterval(3_600)
        let id = ledger.startChargingSession(vin: vin, startSoc: 20, startedAt: start)
        ledger.completeChargingSession(
            id: id, endSoc: 50, energyDeliveredKwh: 20, peakPowerKw: 11, averagePowerKw: 11,
            endedAt: end, tariffPricePerKwh: 2, estimatedCost: 40
        )
        let original = try #require(ledger.sessionsMissingSpotCost(vin: vin).first)
        #expect(ledger.updateSpotEstimatedCost(for: original, cost: 18))

        ledger.updateChargingSessionDetails(
            id: id, vin: vin, startedAt: start, endedAt: end, locationName: "Home charger",
            place: .home, energyKwh: 20, totalCost: 40, pricePerKwh: 2, priceChanged: false
        )
        let renamed = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(renamed.locationName == "Home charger")
        #expect(!renamed.costManuallyEdited)
        #expect(renamed.estimatedCost == 40)
        #expect(renamed.spotEstimatedCost == 18)

        ledger.updateChargingSessionDetails(
            id: id, vin: vin, startedAt: start, endedAt: end, locationName: renamed.locationName,
            place: .home, energyKwh: 25, totalCost: 40, pricePerKwh: 2, priceChanged: false
        )
        let corrected = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(!corrected.costManuallyEdited)
        #expect(corrected.estimatedCost == 50)
        #expect(corrected.spotEstimatedCost == nil)
        #expect(ledger.sessionsMissingSpotCost(vin: vin).map(\.id) == [id])
        #expect(!ledger.updateSpotEstimatedCost(for: original, cost: 18))
    }
}
