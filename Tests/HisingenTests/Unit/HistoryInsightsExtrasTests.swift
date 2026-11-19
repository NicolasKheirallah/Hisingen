import Foundation
import Testing
@testable import Hisingen

struct HistoryInsightsExtrasTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func level(_ hours: Double, _ percent: Double, _ text: String = "parked") -> VehicleMetricRecord {
        VehicleMetricRecord(id: Int64(hours * 100), vin: "V", timestamp: start.addingTimeInterval(hours * 3_600),
                            metric: "soc", value: percent, text: text, ref: nil)
    }

    private func trip(from: Double, to: Double) -> TripHistoryEntry {
        TripHistoryEntry(id: "t\(from)", vin: "V", startedAt: start.addingTimeInterval(from * 3_600),
                         endedAt: start.addingTimeInterval(to * 3_600), distanceKm: 10, averageConsumption: 18,
                         ambientTemperatureCelsius: 5, startLatitude: nil, startLongitude: nil,
                         endLatitude: nil, endLongitude: nil)
    }

    // MARK: Parked drain

    @Test func parkedDrainAveragesObservedParkedHours() {
        let levels = [level(0, 80), level(6, 78.5), level(12, 77)]
        let drain = HistoryInsights.parkedDrain(levels: levels, trips: [], calendar: calendar)
        #expect(drain.observedHours == 12)
        #expect(abs((drain.percentPerDay ?? 0) - 6) < 0.001)
    }

    @Test func parkedDrainLeavesOutPluggedPairsTripsRisesAndImpossibleRates() {
        let levels = [level(0, 80, "plugged"), level(2, 85, "plugged"),
                      level(4, 84), level(6, 83),          // overlaps the trip below
                      level(8, 84), level(10, 90),         // a rise
                      level(12, 70), level(14, 60)]        // 5 points an hour: a drive, not a parked car
        let drain = HistoryInsights.parkedDrain(levels: levels, trips: [trip(from: 4.5, to: 5)], calendar: calendar)
        #expect(drain.days.isEmpty)
        #expect(drain.percentPerDay == nil)
    }

    @Test func parkedDrainNeedsSixObservedHoursBeforeItClaimsASlope() {
        let drain = HistoryInsights.parkedDrain(levels: [level(0, 80), level(3, 79)], trips: [], calendar: calendar)
        #expect(drain.observedHours == 3)
        #expect(drain.percentPerDay == nil)
    }

    // MARK: Cost

    @Test func costPerHundredKilometresNeedsBothInputs() {
        #expect(HistoryInsights.costPer100Km(consumptionKwhPer100Km: 20, pricePerKwh: 1.5) == 30)
        #expect(HistoryInsights.costPer100Km(consumptionKwhPer100Km: 0, pricePerKwh: 1.5) == nil)
        #expect(HistoryInsights.costPer100Km(consumptionKwhPer100Km: 20, pricePerKwh: 0) == nil)
    }

    @Test func spotSavingsCountOnlyMarketPricedSessions() throws {
        func session(_ id: String, kwh: Double, spot: Double?) -> HistoricalChargingSession {
            var value = HistoricalChargingSession(id: id, vin: "V", startedAt: start, endedAt: start + 3_600,
                                                  startSoc: 20, endSoc: 60, energyDeliveredKwh: kwh,
                                                  peakPowerKw: 11, averagePowerKw: 9, locationName: nil, createdAt: start)
            value.spotEstimatedCost = spot
            return value
        }
        let savings = try #require(HistoryInsights.spotSavings(
            sessions: [session("a", kwh: 20, spot: 20), session("b", kwh: 10, spot: nil)], fixedPricePerKwh: 2))
        #expect(savings.sessionCount == 1)
        #expect(savings.reference == 40)
        #expect(savings.saved == 20)
        #expect(savings.percent == 50)
        #expect(HistoryInsights.spotSavings(sessions: [], fixedPricePerKwh: 2) == nil)
    }

    // MARK: Energy by month

    @Test func energySplitTakesTheLastReadingOfEachChargeCycle() {
        func sample(_ day: Double, driving: Double, climate: Double) -> VehicleMetricRecord {
            let value = EnergyBreakdownSample(driving: driving, climate: climate, battery: 0, other: 0)
            let text = String(data: try! JSONEncoder().encode(value), encoding: .utf8)
            return VehicleMetricRecord(id: Int64(day * 10), vin: "V", timestamp: start.addingTimeInterval(day * 86_400),
                                       metric: "energy_since_charge", value: value.total, text: text, ref: nil)
        }
        let months = HistoryInsights.monthlyEnergySplit(samples: [
            sample(0, driving: 1_000, climate: 100),
            sample(1, driving: 5_000, climate: 500),       // first cycle ends here
            sample(2, driving: 800, climate: 50),          // reset by a charge
            sample(3, driving: 3_000, climate: 300)
        ], calendar: calendar)
        let driving = months.reduce(0) { $0 + $1.driving }
        let climate = months.reduce(0) { $0 + $1.climate }
        #expect(driving == 8_000)
        #expect(climate == 800)
    }

    // MARK: Coverage, software, projection

    @Test func coverageCountsDistinctHoursPerDay() {
        let day = calendar.startOfDay(for: start)
        let stamps = [day + 100, day + 200, day + 3_700, day + 90_000]
        let coverage = HistoryInsights.recordingCoverage(timestamps: stamps, calendar: calendar)
        #expect(coverage.map(\.hours) == [2, 1])
    }

    @Test func softwareChangesSkipTheFirstVersionSeen() {
        func version(_ day: Double, _ text: String) -> VehicleMetricRecord {
            VehicleMetricRecord(id: Int64(day), vin: "V", timestamp: start + day * 86_400, metric: "software_version",
                                value: nil, text: text, ref: nil)
        }
        let changes = HistoryInsights.softwareChanges(from: [version(0, "1.0"), version(5, "1.1"), version(9, "1.2")])
        #expect(changes.map(\.version) == ["1.1", "1.2"])
    }

    @Test func projectionWaitsForThreeDaysThenScalesToTheMonth() {
        let monthStart = calendar.dateInterval(of: .month, for: start)!.start
        #expect(HistoryInsights.monthEndProjection(monthToDate: 100, now: monthStart + 86_400, calendar: calendar) == nil)
        let days = Double(calendar.range(of: .day, in: .month, for: start)!.count)
        let projected = HistoryInsights.monthEndProjection(monthToDate: 100, now: monthStart + 5 * 86_400, calendar: calendar)
        #expect(abs((projected ?? 0) - 100 / 5 * days) < 0.001)
    }

    @Test func warrantyOutlookSaysWhichLimitComesFirst() throws {
        let now = start
        let outlook = try #require(HistoryInsights.batteryWarrantyOutlook(
            odometerKm: 140_000, limitKm: 160_000, validUntil: now.addingTimeInterval(5 * 365 * 86_400),
            kmPerDay: 50, now: now))
        #expect(outlook.kilometresLeft == 20_000)
        #expect(outlook.distanceRunsOutFirst)
        #expect(HistoryInsights.batteryWarrantyOutlook(odometerKm: 1, limitKm: nil, validUntil: nil, kmPerDay: 10) == nil)
    }

    // MARK: Normalised consumption

    @Test func normalisedConsumptionRemovesTheTemperatureEffect() {
        func trip(_ day: Double, celsius: Double) -> TripHistoryEntry {
            // consumption = 30 - 0.8 * temperature, exactly
            TripHistoryEntry(id: "n\(day)", vin: "V", startedAt: start + day * 86_400, endedAt: start + day * 86_400 + 600,
                             distanceKm: 10, averageConsumption: 30 - 0.8 * celsius, ambientTemperatureCelsius: celsius,
                             startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil)
        }
        let months = HistoryInsights.monthlyNormalisedConsumption(
            from: [trip(0, celsius: 0), trip(1, celsius: 5), trip(2, celsius: 10)], calendar: calendar)
        let month = months.first
        #expect(months.count == 1)
        // Every trip lies on the fitted line, so each normalises to the 15 degree figure, 30 - 12 = 18.
        #expect(abs((month?.normalised ?? 0) - 18) < 0.001)
        #expect((month?.raw ?? 0) > 18)
    }
}

@Suite(.serialized)
struct VehicleMetricLogTests {
    @Test func batteryLevelIsStoredOnlyWhenItMovesFlipsOrGoesQuiet() {
        let database = VehicleDatabase.inMemory()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(database.history.recordBatteryLevel(vin: "V", percentage: 80, plugged: false, timestamp: at))
        #expect(!database.history.recordBatteryLevel(vin: "V", percentage: 80.4, plugged: false, timestamp: at + 60))
        #expect(database.history.recordBatteryLevel(vin: "V", percentage: 79, plugged: false, timestamp: at + 120))
        #expect(database.history.recordBatteryLevel(vin: "V", percentage: 79, plugged: true, timestamp: at + 180))
        #expect(database.history.recordBatteryLevel(vin: "V", percentage: 79, plugged: true, timestamp: at + 180 + 31 * 60))
        #expect(database.history.metrics(for: "V", metric: .batteryLevel).count == 4)
    }

    @Test func softwareVersionIsStoredOnlyOnChange() {
        let database = VehicleDatabase.inMemory()
        #expect(database.history.recordSoftwareVersion(vin: "V", version: "1.0"))
        #expect(!database.history.recordSoftwareVersion(vin: "V", version: " 1.0 "))
        #expect(database.history.recordSoftwareVersion(vin: "V", version: "1.1"))
        #expect(!database.history.recordSoftwareVersion(vin: "V", version: "  "))
    }

    @Test func sessionNotesKeepTheNewestAndClearOnEmpty() {
        let database = VehicleDatabase.inMemory()
        database.history.setSessionNote("slow cable", sessionID: "s1", vin: "V")
        database.history.setSessionNote("public, 150 kW", sessionID: "s1", vin: "V")
        database.history.setSessionNote("other", sessionID: "s2", vin: "V")
        #expect(database.history.sessionNotes(for: "V") == ["s1": "public, 150 kW", "s2": "other"])
        database.history.setSessionNote("", sessionID: "s1", vin: "V")
        #expect(database.history.sessionNotes(for: "V") == ["s2": "other"])
    }

    @Test func wipingAVehicleClearsItsMetricLog() throws {
        let database = VehicleDatabase.inMemory()
        database.history.recordBatteryLevel(vin: "V", percentage: 50, plugged: false)
        database.history.recordBatteryLevel(vin: "W", percentage: 60, plugged: false)
        try database.wipeVehicleOrThrow(for: "V")
        #expect(database.history.metrics(for: "V", metric: .batteryLevel).isEmpty)
        #expect(database.history.metrics(for: "W", metric: .batteryLevel).count == 1)
        try database.wipeFleetOrThrow()
        #expect(database.history.metrics(for: "W", metric: .batteryLevel).isEmpty)
    }
}
