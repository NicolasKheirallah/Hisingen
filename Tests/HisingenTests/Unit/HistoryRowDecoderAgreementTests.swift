import Foundation
import Testing
@testable import Hisingen

/// The per-VIN reader and the backup must agree about the same row.
///
/// That is the whole point of `HistoryRowDecoder`: the column-index → field mapping exists once,
/// so the reader that fills the dashboard and the backup that leaves the machine cannot drift
/// apart. These tests pin the agreement end to end, through the real queries on both sides —
/// they would fail if a future edit forked the decoder back into a second copy, or reordered a
/// `SELECT` list without moving its decoder with it.
///
/// Timestamps are whole seconds: the backup encodes dates as ISO 8601 without fractional
/// seconds, so a sub-second fixture value would fail on formatting rather than on the mapping
/// this test is about.
@MainActor
struct HistoryRowDecoderAgreementTests {
    private let vin = "YSM-ROW-AGREEMENT"
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func backupAgreesWithTheReaderForSameTypedTables() throws {
        let database = VehicleDatabase.inMemory()
        let sampleTimestamp = base.addingTimeInterval(60)

        #expect(database.recordConnectivity(
            vin: vin, networkType: "LTE", signalBars: 3, wakeReason: "poll",
            timestamp: sampleTimestamp))
        #expect(database.recordCabinClimate(
            vin: vin, interiorCelsius: 21.5, requestedCelsius: 22.5, timestamp: sampleTimestamp))
        #expect(database.addFuelEntry(
            vin: vin, date: sampleTimestamp, liters: 41.25, pricePerLiter: 1.879, odometerKm: 12_345))
        let sessionID = database.charging.startChargingSession(vin: vin, startSoc: 41)
        database.charging.recordChargingSample(
            sessionId: sessionID, vin: vin, soc: 42, powerKw: 10.5,
            voltage: 231, current: 16, timestamp: sampleTimestamp
        )

        let payload = try backupPayload(database)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // These four encode their domain record directly, so the comparison can be exact.
        #expect(try decode([VehicleDatabase.ConnectivityRecord].self, from: payload, key: "connectivity", decoder: decoder)
            == database.history.recentConnectivity(for: vin))
        #expect(try decode([VehicleDatabase.CabinClimateRecord].self, from: payload, key: "cabinClimate", decoder: decoder)
            == database.history.recentCabinClimate(for: vin))
        #expect(try decode([VehicleDatabase.FuelEntry].self, from: payload, key: "fuelEntries", decoder: decoder)
            == database.history.recentFuelEntries(for: vin))
        #expect(try decode([HistoricalChargingSample].self, from: payload, key: "chargingSamples", decoder: decoder)
            == database.charging.chargingSamples(for: sessionID))
    }

    @Test
    func backupAgreesWithTheReaderForProjectedTables() throws {
        let database = VehicleDatabase.inMemory()
        let sampleTimestamp = base.addingTimeInterval(120)

        #expect(database.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 54_321, sohPct: 93.5, degPct: 6.5,
            usableKwh: 74.25, measurementSource: BatteryHealthRecord.fullChargeRangeSource,
            timestamp: sampleTimestamp))
        #expect(database.recordAirQuality(
            vin: vin, airQualityIndex: 17, particulateMatter25: 4.5,
            particulateMatter10: 9.5, filterRemainingPercent: 78, timestamp: sampleTimestamp))
        #expect(database.recordTelemetry(
            vin: vin, odometerKm: 54_321, tripManualKm: 12.5, tripAutoKm: 30.5,
            avgConsumption: 18.25, ambientTempC: 7.5, latitude: 57.7089, longitude: 11.9746,
            timestamp: sampleTimestamp))
        database.recordCommandAudit(
            id: "audit-agreement", vin: vin, command: "lock", status: "success",
            durationMs: 1_234, error: "none", timestamp: sampleTimestamp)

        let payload = try backupPayload(database)

        // These project into a backup-only shape, so compare through the fields that matter.
        let battery = try #require(
            try array(payload, key: "batteryHealth")?.first as? [String: Any])
        let readerBattery = try #require(database.history.batteryHealthHistory(for: vin).first)
        #expect(battery["odometerKm"] as? Double == readerBattery.odometerKm)
        #expect(battery["stateOfHealthPct"] as? Double == readerBattery.stateOfHealthPct)
        #expect(battery["degradationPct"] as? Double == readerBattery.degradationPct)
        #expect(battery["effectiveUsableKwh"] as? Double == readerBattery.effectiveUsableKwh)
        #expect(battery["measurementSource"] as? String == readerBattery.measurementSource)

        let air = try #require(try array(payload, key: "airQuality")?.first as? [String: Any])
        let readerAir = try #require(database.history.recentAirQuality(for: vin).first)
        // The backup's keys differ from the record's, which is exactly how a shifted index
        // would hide: `aqi` would silently carry the PM2.5 value.
        #expect(air["aqi"] as? Double == readerAir.airQualityIndex)
        #expect(air["pm25"] as? Double == readerAir.particulateMatter25)
        #expect(air["pm10"] as? Double == readerAir.particulateMatter10)
        #expect(air["filterPercent"] as? Double == readerAir.filterRemainingPercent)

        let telemetry = try #require(try array(payload, key: "telemetry")?.first as? [String: Any])
        let readerTelemetry = try #require(database.history.recentTelemetry(for: vin).first)
        #expect(telemetry["odometerKm"] as? Double == readerTelemetry.odometerKm)
        #expect(telemetry["averageConsumption"] as? Double == readerTelemetry.averageConsumption)
        #expect(telemetry["unit"] as? String == readerTelemetry.averageConsumptionUnit)
        #expect(telemetry["ambientTempC"] as? Double == readerTelemetry.ambientTemperatureCelsius)
        #expect(telemetry["latitude"] as? Double == readerTelemetry.latitude)
        #expect(telemetry["longitude"] as? Double == readerTelemetry.longitude)

        let command = try #require(try array(payload, key: "remoteCommands")?.first as? [String: Any])
        let readerCommand = try #require(database.history.recentCommandAudits(for: vin).first)
        #expect(command["command"] as? String == readerCommand.command)
        #expect(command["status"] as? String == readerCommand.status)
        #expect(command["durationMs"] as? Int == readerCommand.durationMs)
        #expect(command["errorMessage"] as? String == readerCommand.errorMessage)
    }

    /// The backup drops coordinates by projection, not by query, so the rest of the row must
    /// survive intact when they are excluded.
    @Test
    func excludingCoordinatesDropsOnlyCoordinates() throws {
        let database = VehicleDatabase.inMemory()
        #expect(database.recordTelemetry(
            vin: vin, odometerKm: 1_111, tripManualKm: 2, tripAutoKm: 3,
            avgConsumption: 4, ambientTempC: 5, latitude: 57.7, longitude: 11.9,
            timestamp: base))

        let payload = try backupPayload(database, includeCoordinates: false)

        let telemetry = try #require(try array(payload, key: "telemetry")?.first as? [String: Any])
        #expect(telemetry["latitude"] == nil)
        #expect(telemetry["longitude"] == nil)
        #expect(telemetry["odometerKm"] as? Double == 1_111)
        #expect(telemetry["ambientTempC"] as? Double == 5)
    }

    /// The agreement tests compare the reader against the backup, so a decoder that is wrong in
    /// the *same* way on both sides would still pass them. These pin the values themselves:
    /// every column's value is distinct, so a shifted index cannot land on a matching number.
    @Test
    func readersReturnTheValuesThatWereWritten() throws {
        let database = VehicleDatabase.inMemory()
        let sampleTimestamp = base.addingTimeInterval(180)

        #expect(database.recordAirQuality(
            vin: vin, airQualityIndex: 17, particulateMatter25: 4.5,
            particulateMatter10: 9.5, filterRemainingPercent: 78, timestamp: sampleTimestamp))
        #expect(database.recordTelemetry(
            vin: vin, odometerKm: 54_321, tripManualKm: 12.5, tripAutoKm: 30.5,
            avgConsumption: 18.25, consumptionUnit: "kwh", ambientTempC: 7.5,
            latitude: 57.7089, longitude: 11.9746, timestamp: sampleTimestamp))
        #expect(database.recordConnectivity(
            vin: vin, networkType: "5G", signalBars: 3, wakeReason: "stream",
            timestamp: sampleTimestamp))
        #expect(database.recordCabinClimate(
            vin: vin, interiorCelsius: 21.5, requestedCelsius: 22.5, timestamp: sampleTimestamp))
        #expect(database.addFuelEntry(
            vin: vin, date: sampleTimestamp, liters: 41.25, pricePerLiter: 1.879, odometerKm: 12_345))

        let air = try #require(database.history.recentAirQuality(for: vin).first)
        #expect(air.airQualityIndex == 17)
        #expect(air.particulateMatter25 == 4.5)
        #expect(air.particulateMatter10 == 9.5)
        #expect(air.filterRemainingPercent == 78)

        let telemetry = try #require(database.history.recentTelemetry(for: vin).first)
        #expect(telemetry.odometerKm == 54_321)
        #expect(telemetry.tripManualKm == 12.5)
        #expect(telemetry.tripAutomaticKm == 30.5)
        #expect(telemetry.averageConsumption == 18.25)
        #expect(telemetry.ambientTemperatureCelsius == 7.5)
        #expect(telemetry.latitude == 57.7089)
        #expect(telemetry.longitude == 11.9746)
        // Selected last in the canonical column list, so the likeliest to be mis-indexed.
        #expect(telemetry.averageConsumptionUnit == "kwh")

        let connectivity = try #require(database.history.recentConnectivity(for: vin).first)
        #expect(connectivity.networkType == "5G")
        #expect(connectivity.signalBars == 3)
        #expect(connectivity.wakeReason == "stream")

        let climate = try #require(database.history.recentCabinClimate(for: vin).first)
        #expect(climate.interiorCelsius == 21.5)
        #expect(climate.requestedCelsius == 22.5)

        let fuel = try #require(database.history.recentFuelEntries(for: vin).first)
        #expect(fuel.liters == 41.25)
        #expect(fuel.pricePerLiter == 1.879)
        #expect(fuel.odometerKm == 12_345)
    }

    @Test
    func chargingSampleReadsEveryColumnInOrder() throws {
        let database = VehicleDatabase.inMemory()
        let sessionID = database.charging.startChargingSession(vin: vin, startSoc: 41)
        let sampleTimestamp = base.addingTimeInterval(240)
        database.charging.recordChargingSample(
            sessionId: sessionID, vin: vin, soc: 42, powerKw: 10.5, voltage: 231, current: 16,
            chargingType: ChargingType.dc.rawValue, timestamp: sampleTimestamp
        )

        let sample = try #require(database.charging.chargingSamples(for: sessionID).first)
        #expect(sample.vin == vin)
        #expect(sample.soc == 42)
        #expect(sample.powerKw == 10.5)
        #expect(sample.voltageVolts == 231)
        #expect(sample.currentAmps == 16)
        #expect(sample.chargingType == ChargingType.dc.rawValue)
    }

    /// The battery-health predicate is one constant now, so the count a settings screen shows and
    /// the rows the export writes are the same set by construction.
    @Test
    func batteryHealthCountAndExportUseTheSameSources() throws {
        let database = VehicleDatabase.inMemory()
        #expect(database.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 1_000, sohPct: 99, degPct: 1, usableKwh: 70,
            measurementSource: BatteryHealthRecord.fullChargeRangeSource, timestamp: base))
        #expect(database.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 2_000, sohPct: 98, degPct: 2, usableKwh: 69,
            measurementSource: BatteryHealthRecord.calculatedSource,
            timestamp: base.addingTimeInterval(60)))
        #expect(database.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 3_000, sohPct: 97, degPct: 3, usableKwh: 68,
            measurementSource: BatteryHealthRecord.legacyEstimateSource,
            timestamp: base.addingTimeInterval(120)))

        let payload = try backupPayload(database)
        let exported = try array(payload, key: "batteryHealth")?.count

        #expect(exported == 3)
        #expect(database.recordCounts().batteryHealth == exported)
    }

    // MARK: - Helpers

    private func backupPayload(
        _ database: VehicleDatabase, includeCoordinates: Bool = true
    ) throws -> [String: Any] {
        let data = try database.exportBackupJSON(includeCoordinates: includeCoordinates)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func array(_ payload: [String: Any], key: String) throws -> [Any]? {
        try #require(payload[key] != nil, "backup payload has no \(key) array")
        return payload[key] as? [Any]
    }

    private func decode<T: Decodable>(
        _ type: [T].Type, from payload: [String: Any], key: String, decoder: JSONDecoder
    ) throws -> [T] {
        let list = try #require(try array(payload, key: key), "\(key) is not an array")
        let data = try JSONSerialization.data(withJSONObject: list)
        return try decoder.decode(type, from: data)
    }
}
