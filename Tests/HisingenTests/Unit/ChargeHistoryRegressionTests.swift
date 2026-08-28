import Foundation
import Testing
@testable import Hisingen

@Suite("Charge history regression tests")
struct ChargeHistoryRegressionTests {
    @Test("Unfinished sessions never appear as completed history")
    func unfinishedSessionIsExcluded() {
        let database = VehicleDatabase.inMemory()
        let vin = "ACTIVE-HISTORY-VIN"
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

        let id = database.startChargingSession(
            vin: vin, startSoc: 62, startedAt: startedAt
        )
        database.recordChargingSample(
            sessionId: id, vin: vin, soc: 62, powerKw: 4,
            voltage: nil, current: nil, timestamp: startedAt
        )

        #expect(database.activeChargingSession(for: vin)?.id == id)
        #expect(database.recentChargingSessions(for: vin).isEmpty)

        database.completeChargingSession(
            id: id, endSoc: 62, energyDeliveredKwh: 0,
            peakPowerKw: 4, averagePowerKw: 4,
            endedAt: startedAt.addingTimeInterval(60)
        )
        #expect(database.recentChargingSessions(for: vin).isEmpty)
    }

    @Test("Legacy summary is reconciled with its observed charging samples")
    func legacySummaryAndSamplesAreReconciled() throws {
        let database = VehicleDatabase.inMemory()
        let vin = "LEGACY-HISTORY-VIN"
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let firstObservedAt = startedAt.addingTimeInterval(9 * 60 * 60 + 46 * 60)
        let endedAt = startedAt.addingTimeInterval(10 * 60 * 60 + 12 * 60)

        let id = database.startChargingSession(
            vin: vin, startSoc: 42, startedAt: startedAt
        )
        database.recordChargingSample(
            sessionId: id, vin: vin, soc: 70, powerKw: 4,
            voltage: nil, current: nil, timestamp: firstObservedAt
        )
        database.recordChargingSample(
            sessionId: id, vin: vin, soc: 72, powerKw: 4,
            voltage: nil, current: nil, timestamp: endedAt
        )
        // Reproduce the old failure: the durable final values were all written as zero.
        database.completeChargingSession(
            id: id, endSoc: 42, energyDeliveredKwh: 0,
            peakPowerKw: 4, averagePowerKw: 4, endedAt: endedAt
        )

        let record = try #require(database.recentChargingSessions(for: vin).first)
        let session = record.toDomainSession(database: database, usableCapacityKwh: 79)

        #expect(session.startBatteryPercentage == 42)
        #expect(session.endBatteryPercentage == 72)
        #expect(session.percentageAdded == 30)
        #expect(abs(session.kwhDelivered - 23.7) < 0.001)
        #expect(session.durationMinutes == 612)
        #expect(session.samples.first?.batteryPercentage == session.startBatteryPercentage)
        #expect(session.samples.last?.batteryPercentage == session.endBatteryPercentage)
        #expect(session.samples.first?.timestamp == session.startDate)
        #expect(session.samples.last?.timestamp == session.endDate)

        let dashboardSession = record.reconciled(database: database, usableCapacityKwh: 79)
        #expect(dashboardSession.endSoc == 72)
        #expect(abs(dashboardSession.energyDeliveredKwh - 23.7) < 0.001)

        database.repairLegacyChargingSessions(for: vin, usableCapacityKwh: 79)
        let repairedRecord = try #require(database.recentChargingSessions(for: vin).first)
        #expect(repairedRecord.endSoc == 72)
        #expect(abs(repairedRecord.energyDeliveredKwh - 23.7) < 0.001)
    }

    @Test("Finalization uses the last charging sample when the stop snapshot SoC is stale")
    @MainActor
    func staleStopSnapshotDoesNotEraseCharge() throws {
        let database = VehicleDatabase.inMemory()
        let suite = "ChargeHistoryRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.storeChargingHistory = true
        let store = VehicleStateStore(
            defaults: defaults, database: database, preferences: preferences
        )
        let vin = "STALE-STOP-VIN"
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

        store.save(state(vin: vin, soc: 40, charging: true, powerWatts: nil, at: startedAt))
        store.save(state(
            vin: vin, soc: 55, charging: true, powerWatts: 4_000,
            at: startedAt.addingTimeInterval(3_600)
        ))
        // The provider can return an older SoC in the first non-charging snapshot.
        store.save(state(
            vin: vin, soc: 40, charging: false, powerWatts: nil,
            at: startedAt.addingTimeInterval(3_660)
        ))

        let session = try #require(database.recentChargingSessions(for: vin).first)
        #expect(session.startSoc == 40)
        #expect(session.endSoc == 55)
        #expect(abs(session.energyDeliveredKwh - 11.85) < 0.001)
        #expect(session.peakPowerKw == 4)
        #expect(session.averagePowerKw == 4)
        #expect(session.startedAt == startedAt)
        #expect(session.endedAt == startedAt.addingTimeInterval(3_660))
    }

    @MainActor
    private func state(
        vin: String, soc: Double, charging: Bool, powerWatts: Int?, at date: Date
    ) -> VehicleState {
        VehicleState(
            batteryPercentage: soc,
            rangeKm: nil,
            chargingState: charging ? .charging : .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: powerWatts,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: charging ? .ac : .none,
            chargerConnection: charging ? .connected : .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            vin: vin,
            ownerFirstName: nil,
            odometerKm: nil,
            imageData: nil,
            fetchedAt: date,
            vehicleReportedAt: date,
            dataWarnings: []
        )
    }
}
