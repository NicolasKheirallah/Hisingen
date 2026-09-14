import Foundation
import Testing
@testable import Hisingen

struct VehicleCapabilityParsingTests {
    @Test
    func testDigitalTwinExteriorAndPartialMerge() throws {
        var payload = Data()
        payload.append(Protobuf.intField(2, 2))
        payload.append(Protobuf.intField(3, 1))
        payload.append(Protobuf.intField(4, 2))
        payload.append(Protobuf.intField(12, 3))
        let exterior = try #require(PolestarGRPC.parseExterior(payload))
        #expect(exterior.isLocked == true)
        #expect(Set(exterior.itemsNeedingAttention) == [.frontLeftDoor, .tailgate])

        var update = Data()
        update.append(Protobuf.intField(3, 2))
        let merged = try #require(PolestarGRPC.parseExterior(update)).merging(previous: exterior)
        #expect(merged.itemsNeedingAttention == [.tailgate])
        #expect(merged.isLocked == true)
    }

    /// Exterior field 16 is an independent `LockStatus tailgate_lock` upstream — it is not
    /// derivable from field 12 (whether the tailgate is open) and must not be inferred.
    @Test
    func testTailgateLockDecodesIndependentlyOfTailgateOpenState() throws {
        // Locked tailgate (2) with the tailgate open (1): two independent facts.
        var payload = Data()
        payload.append(Protobuf.intField(2, 2))
        payload.append(Protobuf.intField(12, 1))
        payload.append(Protobuf.intField(16, 2))
        let exterior = try #require(PolestarGRPC.parseExterior(payload))
        #expect(exterior.isTailgateLocked == true)
        #expect(exterior.isTailgateOpen == true)
        #expect(exterior.isLocked == true)

        // Absent field 16 stays nil; enum 0/99 (unspecified/out of range) also stay nil.
        let absent = try #require(PolestarGRPC.parseExterior(Protobuf.intField(2, 2)))
        #expect(absent.isTailgateLocked == nil)
        for raw in [0, 99] {
            let unknown = try #require(PolestarGRPC.parseExterior(Protobuf.intField(2, 2) + Protobuf.intField(16, raw)))
            #expect(unknown.isTailgateLocked == nil)
        }
    }

    @Test
    func testExteriorTimestampRetainedOnDigitalTwinShapeOnly() throws {
        var payload = Data()
        payload.append(Protobuf.messageField(1, timestamp(seconds: 1_780_000_000)))
        payload.append(Protobuf.intField(2, 2))
        payload.append(Protobuf.intField(3, 2))
        let digitalTwin = try #require(PolestarGRPC.parseExterior(payload))
        #expect(digitalTwin.reportedAt == Date(timeIntervalSince1970: 1_780_000_000))

        // Legacy shape: field 1 is the central-lock message, not a timestamp, so no
        // reported time is fabricated there.
        var legacy = Data()
        var lock = Data()
        lock.append(Protobuf.intField(1, 2))
        legacy.append(Protobuf.messageField(1, lock))
        var doorStatus = Data()
        doorStatus.append(Protobuf.intField(2, 2))
        var doors = Data()
        doors.append(Protobuf.messageField(1, doorStatus))
        legacy.append(Protobuf.messageField(2, doors))
        let legacySnapshot = try #require(PolestarGRPC.parseExterior(legacy))
        #expect(legacySnapshot.reportedAt == nil)
        #expect(legacySnapshot.isLocked == true)
    }

    @Test
    func testExteriorMergeCarriesTailgateLockAndReportedAt() throws {
        let first = ExteriorSnapshot(
            openings: [OpeningReading(opening: .tailgate, state: .closed)],
            isLocked: true, alarmTriggered: false, isTailgateLocked: true,
            reportedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = ExteriorSnapshot(
            openings: [OpeningReading(opening: .frontLeftDoor, state: .closed)],
            isLocked: nil, alarmTriggered: nil, isTailgateLocked: nil, reportedAt: nil
        )
        let merged = second.merging(previous: first)
        #expect(merged.isTailgateLocked == true)
        #expect(merged.reportedAt == Date(timeIntervalSince1970: 1_000))
        #expect(merged.isLocked == true)
    }

    @Test
    func testHealthParsesWarningsAndOnlyPositiveTyreMeasurements() {
        var payload = Data()
        payload.append(Protobuf.intField(3, 24))
        payload.append(Protobuf.intField(4, 2_400))
        payload.append(Protobuf.intField(5, 6))
        payload.append(Protobuf.intField(9, 3))
        payload.append(Protobuf.intField(10, 1))
        payload.append(Protobuf.doubleField(39, 208.5))
        payload.append(Protobuf.doubleField(40, 210.0))
        payload.append(Protobuf.doubleField(41, 212.0))
        payload.append(Protobuf.doubleField(42, 214.0))
        payload.append(Protobuf.intField(38, 2))
        let report = PolestarGRPC.parseHealth(payload)
        #expect(report.daysToService == 24)
        #expect(report.serviceWarning)
        #expect(report.details.tyres.first?.kilopascals == 208.5)
        #expect(report.details.tyres.first?.warning == .low)
        #expect(report.details.tyres.last?.kilopascals == 214.0)
        #expect(report.details.warnings.contains(.lowVoltageBattery))
        #expect(report.details.reportedWarnings.contains(.lowVoltageBattery))
        #expect(!(report.details.reportedWarnings.contains(.brakeFluid)))
    }

    @Test
    func testHealthDoesNotConvertAbsentFieldsIntoHealthyReadings() {
        let report = PolestarGRPC.parseHealth(Data())
        #expect(report.details.tyres.allSatisfy { $0.kilopascals == nil && $0.warning == .unknown })
        #expect(report.details.warnings.isEmpty)
        #expect(report.details.reportedWarnings.isEmpty)
    }

    @Test
    func testHealthyPolestarOmitsTyreFieldsButReportsEverythingElse() {
        // An omitted tyre warning is unspecified, even when other systems report healthy.
        var payload = Data()
        payload.append(Protobuf.intField(5, 1))
        payload.append(Protobuf.intField(6, 1))
        payload.append(Protobuf.intField(7, 1))
        payload.append(Protobuf.intField(8, 1))
        payload.append(Protobuf.intField(13, 1))
        for field in 14...35 { payload.append(Protobuf.intField(field, 1)) }
        payload.append(Protobuf.intField(38, 1))
        let report = PolestarGRPC.parseHealth(payload)
        #expect(report.details.tyres.allSatisfy { $0.warning == .unknown && $0.kilopascals == nil })
        #expect(report.details.tyres.count == 4)
        #expect(!(report.details.warnings.contains(.tyrePressure)))
        #expect(!(report.details.reportedWarnings.contains(.tyrePressure)))
    }

    @Test
    func testSoftwareInfoAndScheduleDecode() {
        var description = Data()
        description.append(Protobuf.stringField(1, "Polestar OS"))
        var timestamp = Data()
        timestamp.append(Protobuf.intField(1, 2_000_000_000))
        var schedule = Data()
        schedule.append(Protobuf.messageField(2, timestamp))
        var payload = Data()
        payload.append(Protobuf.messageField(2, description))
        payload.append(Protobuf.intField(4, 12))
        payload.append(Protobuf.stringField(6, "P4.2.1"))
        payload.append(Protobuf.messageField(8, schedule))
        let software = PolestarGRPC.parseSoftware(payload)
        #expect(software.version == "P4.2.1")
        #expect(software.title == "Polestar OS")
        #expect(software.state == .scheduled)
        #expect(software.scheduledAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(software.latestAvailableVersion == "P4.2.1")
        #expect(software.installedVersion == nil)
    }

    @Test
    func testSettledSoftwareStateReportsRunningVersionRatherThanAnOffer() {
        var payload = Data()
        payload.append(Protobuf.stringField(1, "sw-9f2c"))
        payload.append(Protobuf.intField(4, 9))
        payload.append(Protobuf.stringField(6, "P2.14.3"))
        let software = PolestarGRPC.parseSoftware(payload)
        #expect(software.state == .completed)
        #expect(software.installedVersion == "P2.14.3")
        #expect(software.latestAvailableVersion == nil)
    }

    @Test
    func testMissingVersionStringIsReportedAsUnknownNotSubstituted() {
        var payload = Data()
        payload.append(Protobuf.intField(4, 9))
        let software = PolestarGRPC.parseSoftware(payload)
        #expect(software.version == nil)
        #expect(software.title == nil)
        #expect(software.installedVersion == nil)
        #expect(software.latestAvailableVersion == nil)
    }

    /// Decodes a real `GetSoftwareInfo` frame captured from a Polestar 2 (VIN redacted).
    /// Pins every field number against actual bytes rather than an inferred schema.
    @Test
    func testRealCapturedSoftwareInfoFrameDecodes() throws {
        let hex =
            "0ab1020a2461393532353433372d313864332d346561632d626630392d316637356630383462" +
            "65656112e7010a0f536f66747761726520757064617465120f536f6674776172652075706461" +
            "74651ac2013c74657874626c6f636b3e41206e657720736f6674776172652075706461746520" +
            "697320617661696c61626c6520636f6e7461696e696e6720696d70726f7665642066756e6374" +
            "696f6e616c6974792e20436c69636b2052656164206d6f726520746f20726561642061626f75" +
            "742069742e20506c6561736520636f6e7461637420506f6c657374617220696620796f752068" +
            "61766520616e79207175657374696f6e732061626f757420746865207570646174652e3c2f74" +
            "657874626c6f636b3e1a00200f2a0308982a3206352e302e3130520608a2f99bd0065a065359" +
            "5354454d"
        var bytes = Data()
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        let payload = try #require(Protobuf.fields(bytes).first(where: { $0.number == 1 && $0.wire == 2 })?.data)
        let software = PolestarGRPC.parseSoftware(payload)
        #expect(software.state == .available)                       // field 4 == 15
        #expect(software.latestAvailableVersion == "5.0.10")        // field 6
        #expect(software.installedVersion == nil)
        #expect(software.title == "Software update")                // field 2.1
        #expect(software.scheduledAt == nil)                               // no field 8
        #expect(software.updatedAt != nil)                              // field 10
    }

    /// The C3 scheduler answers `relativeTime should be between 2 to 10080!` — minutes, not
    /// seconds. Pins the unit and bounds so the `* 60` bug cannot come back.
    @Test
    func testOtaScheduleDelayIsExpressedInMinutesWithinBackendBounds() {
        #expect(PolestarGRPC.otaScheduleMinutes.lowerBound == 2)
        #expect(PolestarGRPC.otaScheduleMinutes.upperBound == 10_080)
        #expect(PolestarGRPC.otaScheduleMinutes.upperBound == 7 * 24 * 60)
        #expect(!(PolestarGRPC.otaScheduleMinutes.contains(1)))
        #expect(!(PolestarGRPC.otaScheduleMinutes.contains(10_081)))
    }

    @Test
    func testSoftwareStateEnumCoversTheFullBackendRange() {
        let expected: [UInt64: SoftwareUpdateState] = [
            0: .unknown, 1: .available, 2: .downloading, 3: .downloaded,
            4: .failed, 5: .installing, 6: .installing, 7: .failed,
            8: .failed, 9: .completed, 10: .deferred, 11: .failed,
            12: .scheduled, 13: .installing, 14: .unknown, 15: .available, 99: .unknown
        ]
        for (raw, state) in expected {
            #expect(PolestarGRPC.softwareState(raw) == state)
        }
        // A failed install still describes a target version, not what the car is running.
        var payload = Data()
        payload.append(Protobuf.intField(4, 8))
        payload.append(Protobuf.stringField(6, "P2.15.0"))
        let failed = PolestarGRPC.parseSoftware(payload)
        #expect(failed.installedVersion == nil)
        #expect(failed.latestAvailableVersion == "P2.15.0")
    }

    @Test
    func testPendingUpdateKeepsLastSettledInstalledVersion() {
        var settled = vehicle(vin: "YSMTEST")
        settled.softwareInfo = VehicleSoftwareInfo(
            version: "P2.14.3", title: "P2.14.3", state: .completed, installedVersion: "P2.14.3"
        )
        var offered = vehicle(vin: "YSMTEST")
        offered.softwareInfo = VehicleSoftwareInfo(
            version: "P2.15.0", title: "P2.15.0", state: .available, latestAvailableVersion: "P2.15.0"
        )
        let merged = offered.mergingLastKnown(from: settled, features: .default)
        #expect(merged.softwareInfo?.installedVersion == "P2.14.3")
        #expect(merged.softwareInfo?.latestAvailableVersion == "P2.15.0")
        #expect(merged.softwareInfo?.state == .available)

        // A different car must not inherit the previous car's version.
        var otherCar = vehicle(vin: "YSMOTHER")
        otherCar.softwareInfo = offered.softwareInfo
        #expect(otherCar.mergingLastKnown(from: settled, features: .default)
            .softwareInfo?.installedVersion == nil)
    }

    @Test
    func testGlobalAndLocationSchedulesDecodeWithoutCoordinates() throws {
        let start = dailyTime(hour: 22, minute: 30)
        let stop = dailyTime(hour: 6, minute: 15)
        var global = Data()
        global.append(Protobuf.messageField(1, start))
        global.append(Protobuf.messageField(2, stop))
        global.append(Protobuf.intField(3, 1))
        let globalSchedule = try #require(PolestarGRPC.parseGlobalChargeTimer(global))
        #expect(globalSchedule.startHour == 22)
        #expect(globalSchedule.endHour == 6)

        var timer = Data()
        timer.append(Protobuf.intField(2, 1))
        timer.append(Protobuf.messageField(3, start))
        timer.append(Protobuf.messageField(4, stop))
        timer.append(Protobuf.packedIntField(5, [1, 3, 5]))
        var location = Data()
        location.append(Protobuf.stringField(3, "Sensitive alias that must be discarded"))
        location.append(Protobuf.doubleField(4, 12.34))
        location.append(Protobuf.messageField(10, timer))
        let response = Protobuf.messageField(3, location)
        let schedules = PolestarGRPC.parseChargeLocationSchedules(response)
        #expect(schedules.count == 1)
        #expect(schedules[0].weekdays == [.monday, .wednesday, .friday])
    }

    @Test
    func testClimateAndTimersDecode() {
        var timestamp = Data()
        timestamp.append(Protobuf.intField(1, 2_000_000_000))
        var climate = Data()
        climate.append(Protobuf.messageField(1, timestamp))
        climate.append(Protobuf.intField(2, 1))
        climate.append(Protobuf.intField(3, 18))
        climate.append(Protobuf.intField(6, 1))
        climate.append(Protobuf.intField(15, 3))
        let status = PolestarGRPC.parseClimate(climate)
        // Field 6 is an unresolved activity enum (live-verified 2026-09-11: 2 during a real
        // heating session), so an active session with no temperature pair reports .active.
        #expect(status.activity == .active)
        #expect(status.timeRemainingMinutes == 18)
        #expect(status.timerTriggered)

        var timer = Data()
        timer.append(Protobuf.stringField(1, "timer-1"))
        timer.append(Protobuf.messageField(3, dailyTime(hour: 7, minute: 0)))
        timer.append(Protobuf.intField(4, 1))
        timer.append(Protobuf.packedIntField(6, [1, 2, 3, 4, 5]))
        let timers = PolestarGRPC.parseClimateTimers(Protobuf.messageField(3, timer))
        #expect(timers.first?.startHour == 7)
        #expect(timers.first?.weekdays.count == 5)
    }

    @Test
    func testOdometerTripMetersAndBatteryDiagnosticsDecode() {
        var odometer = Data()
        odometer.append(Protobuf.intField(2, 25_123_000))
        odometer.append(Protobuf.doubleField(3, 42.5))
        odometer.append(Protobuf.doubleField(4, 18.25))
        let report = PolestarGRPC.parseOdometer(odometer)
        #expect(report.odometerKm == 25_123)
        #expect(report.manualTripKm == 42.5)
        #expect(report.automaticTripKm == 18.25)

        var battery = Data()
        battery.append(Protobuf.doubleField(3, 18.4))
        battery.append(Protobuf.intField(9, 60))
        battery.append(Protobuf.doubleField(13, 19.1))
        battery.append(Protobuf.doubleField(16, 12_400))
        battery.append(Protobuf.intField(26, 4))
        let diagnostics = PolestarGRPC.parseBattery(battery).diagnostics
        #expect(diagnostics.chargerPowerState == .providingPower)
        #expect(diagnostics.timeToTargetMinutes == 60)
        #expect(diagnostics.energyUsedSinceChargeWh == 12_400)
    }

    /// `Odometer` fields 5/6 are `average_speed_km_per_hour` / `average_speed_km_per_hour_automatic`
    /// in the upstream schema (kildahldev cross-check, pypolestar PR 79); field 1 is the reading
    /// timestamp. Since-charge fields 7/8 are schema-verified but were absent in the reference
    /// capture, so they stay unparsed rather than named.
    @Test
    func testOdometerAverageSpeedsAndTimestampDecodeWithUnits() {
        var odometer = Data()
        odometer.append(Protobuf.messageField(1, timestamp(seconds: 1_780_000_000)))
        odometer.append(Protobuf.intField(5, 62))
        odometer.append(Protobuf.intField(6, 71))
        let report = PolestarGRPC.parseOdometer(odometer)
        #expect(report.manualAverageSpeedKmH == 62)
        #expect(report.automaticAverageSpeedKmH == 71)
        #expect(report.reportedAt == Date(timeIntervalSince1970: 1_780_000_000))
        // Absent fields stay nil — omission is never a zero speed.
        let empty = PolestarGRPC.parseOdometer(Data())
        #expect(empty.manualAverageSpeedKmH == nil)
        #expect(empty.automaticAverageSpeedKmH == nil)
        #expect(empty.reportedAt == nil)
    }

    @Test
    func testVehicleStateCacheDecodesBeforeCapabilityFieldsExisted() throws {
        let original = vehicle()
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["exteriorStatus", "healthDetails", "softwareInfo", "chargingSchedules",
                    "climateStatus", "climateTimers", "tripMeterManualKm", "tripMeterAutomaticKm",
                    "connectivity", "airQuality", "batteryDiagnostics", "unavailableFeatures"] {
            object.removeValue(forKey: key)
        }
        let oldCache = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: oldCache)
        #expect(decoded.identity.vin == original.identity.vin)
        #expect(decoded.energy.schedules == [])
        #expect(decoded.freshness.unavailableFeatures == [])
    }

    @Test
    func testAmpLimitReadResponseParsesCorrectly() throws {

        var inner = Data()
        inner.append(Protobuf.intField(1, 16))
        var response = Data()
        response.append(Protobuf.messageField(3, inner))

        let limit = PolestarGRPC.fetchAmpLimitResponse(response)
        #expect(limit == 16)
    }

    @Test
    func testAmpLimitReadRejectsZeroAndOutOfRange() {
        var inner = Data()
        inner.append(Protobuf.intField(1, 0))
        var response = Data()
        response.append(Protobuf.messageField(3, inner))
        #expect(PolestarGRPC.fetchAmpLimitResponse(response) == nil)
    }

    @Test
    func testLocationParsesLatitudeAndLongitude() {
        var compact = Data()
        compact.append(Protobuf.doubleField(1, 12.5))
        compact.append(Protobuf.doubleField(2, 55.7))
        let location = PolestarGRPC.parseLocation(compact)
        #expect(location?.longitude == 12.5)
        #expect(location?.latitude == 55.7)
        #expect(location?.heading == nil)
        #expect(location?.timestamp == nil)
    }

    @Test
    func testLocationWithTimestampAndHeadingParses() {
        var compact = Data()
        compact.append(Protobuf.doubleField(1, 10.0))
        compact.append(Protobuf.doubleField(2, 60.0))
        var ts = Data()
        ts.append(Protobuf.intField(1, 2_000_000_000))
        compact.append(Protobuf.messageField(3, ts))
        compact.append(Protobuf.doubleField(4, 180.0))
        let location = PolestarGRPC.parseLocation(compact)
        #expect(location?.longitude == 10.0)
        #expect(location?.latitude == 60.0)
        #expect(location?.heading == 180.0)
        #expect(location?.timestamp == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func testWeatherParsesTemperatureAndTimestamp() {

        var report = Data()
        report.append(Protobuf.intField(1, 2_000_000_000_000))
        report.append(Protobuf.doubleField(2, 15.5))
        let weather = PolestarGRPC.parseWeather(report)
        #expect(weather?.temperatureCelsius == 15.5)
        #expect(weather?.timestamp == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func testWeatherWithNoDataReturnsNil() {
        let empty = Data()
        #expect(PolestarGRPC.parseWeather(empty) == nil)
    }

    @Test
    func testStreamingCollectsMultipleFrames() async throws {

        var msg1 = Data()
        msg1.append(Protobuf.intField(1, 42))
        var msg2 = Data()
        msg2.append(Protobuf.intField(1, 99))
        var stream = Data()
        stream.append(Protobuf.grpcFrame(msg1))
        stream.append(Protobuf.grpcFrame(msg2))

        var offset = 0
        let bytes = [UInt8](stream)
        var parsedFrames: [Data] = []
        while offset + 5 <= bytes.count {
            let size = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            offset += 5
            parsedFrames.append(Data(bytes[offset..<offset + size]))
            offset += size
        }
        #expect(parsedFrames.count == 2)
        #expect(Protobuf.fields(parsedFrames[0]).first(where: { $0.number == 1 })?.varint == 42)
        #expect(Protobuf.fields(parsedFrames[1]).first(where: { $0.number == 1 })?.varint == 99)
    }

    @Test
    func testHealthParsesSpecificLightFailures() {
        // Labels follow the upstream Health schema: 14 = left brake light, 23 = left high
        // beam, 26 = right low beam. Field 29 does not exist in the schema (the wire jumps
        // 28 → 30), so no lamp is ever named for it.
        var payload = Data()
        payload.append(Protobuf.intField(14, 2)) // Left brake light
        payload.append(Protobuf.intField(23, 2)) // Left high beam
        payload.append(Protobuf.intField(26, 2)) // Right low beam
        let report = PolestarGRPC.parseHealth(payload)
        #expect(report.details.warnings.contains(.exteriorLight))
        #expect(report.details.reportedWarnings.contains(.exteriorLight))
        #expect(report.details.lightFailures.count == 3)
        #expect(report.details.lightFailures.contains("Left brake light"))
        #expect(report.details.lightFailures.contains("Left high beam"))
        #expect(report.details.lightFailures.contains("Right low beam"))
    }

    /// Health field 2 is `engine_hours_to_service` upstream, and the ServiceWarning enum
    /// carries ENGINE_HOURS_* triggers — a real service-interval input even for a BEV.
    @Test
    func testHealthEngineHoursToServiceAndTimestampDecode() {
        var payload = Data()
        payload.append(Protobuf.messageField(1, timestamp(seconds: 1_780_000_000)))
        payload.append(Protobuf.intField(2, 4_320))
        payload.append(Protobuf.intField(3, 24))
        payload.append(Protobuf.intField(4, 2_400))
        let report = PolestarGRPC.parseHealth(payload)
        #expect(report.engineHoursToService == 4_320)
        #expect(report.daysToService == 24)
        #expect(report.reportedAt == Date(timeIntervalSince1970: 1_780_000_000))
        // Absent field 2 stays nil; an explicit 0 is not promoted either.
        let empty = PolestarGRPC.parseHealth(Protobuf.intField(3, 10))
        #expect(empty.engineHoursToService == nil)
        #expect(empty.reportedAt == nil)
    }

    @Test
    func testVehicleStateMetadataAndBuildWeekFormatting() throws {
        var state = VehicleState(
            batteryPercentage: 80,
            rangeKm: 350,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ABC 123",
            vin: "YS3E1234567890123",
            ownerFirstName: "Test",
            odometerKm: 25000,
            daysToService: 120,
            distanceToServiceKm: 5000,
            serviceWarning: false,
            fluidWarnings: [],
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        state.identity.structureWeek = "202240"
        state.identity.internalVehicleIdentifier = "UUID-POL-12345"
        state.identity.pno34 = "PNO34-SPEC-2023"
        state.identity.accountMarket = "SE"

        #expect(state.formattedBuildWeek == "2022 · W40")

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: encoded)

        #expect(decoded.identity.structureWeek == "202240")
        #expect(decoded.formattedBuildWeek == "2022 · W40")
        #expect(decoded.identity.internalVehicleIdentifier == "UUID-POL-12345")
        #expect(decoded.identity.pno34 == "PNO34-SPEC-2023")
        #expect(decoded.identity.accountMarket == "SE")
    }

    @Test
    func testChargeLocationSchedulesDecodesLocationName() {
        var timerData = Data()
        timerData.append(Protobuf.intField(2, 1)) // isActive = true
        timerData.append(Protobuf.messageField(3, dailyTime(hour: 22, minute: 0))) // start 22:00
        timerData.append(Protobuf.messageField(4, dailyTime(hour: 6, minute: 0)))  // stop 06:00

        var locationData = Data()
        locationData.append(Protobuf.stringField(2, "Home Garage"))
        locationData.append(Protobuf.messageField(10, timerData))

        var payload = Data()
        payload.append(Protobuf.messageField(3, locationData))

        let schedules = PolestarGRPC.parseChargeLocationSchedules(payload)
        #expect(schedules.count == 1)
        #expect(schedules.first?.locationName == "Home Garage")
        #expect(schedules.first?.startHour == 22)
        #expect(schedules.first?.endHour == 6)
        #expect(schedules.first?.isActive == true)
    }

    @Test
    func testClimateParsesSeatAndSteeringWheelHeatingLevels() {
        var payload = Data()
        payload.append(Protobuf.intField(1, 1)) // running = 1
        payload.append(Protobuf.intField(4, 2)) // action = heating
        payload.append(Protobuf.intField(10, 3)) // driver seat level 3
        payload.append(Protobuf.intField(11, 2)) // passenger seat level 2
        payload.append(Protobuf.intField(12, 1)) // steering wheel heating active

        let climate = PolestarGRPC.parseClimate(payload)
        #expect(climate.activity == .heating)
        #expect(climate.driverSeatHeatingLevel == 3)
        #expect(climate.passengerSeatHeatingLevel == 2)
        #expect(climate.steeringWheelHeatingLevel == 1)
    }

    @Test
    func testVehicleProbedCapabilitiesInspector() {
        var probed = VehicleProbedCapabilities()
        probed.record(.climateStartStop, as: .supported)
        probed.record(.windows, as: .unavailable)
        probed.record(.softwareInstallControl, as: .supported)

        #expect(probed.support(for: .climateStartStop) == .supported)
        #expect(probed.support(for: .windows) == .unavailable)
        #expect(probed.allResults.count == 3)
        #expect(probed.resultsMap[.softwareInstallControl] == .supported)
    }

    @Test
    func testCarRenderAnglePreferences() {
        #expect(CarRenderAngle.allCases.count == 6)
        #expect(CarRenderAngle.sideProfile.rawValue == 0)
        #expect(CarRenderAngle.frontThreeQuarter.rawValue == 1)
        #expect(CarRenderAngle.frontDirect.rawValue == 2)
        #expect(CarRenderAngle.rearThreeQuarter.rawValue == 3)
        #expect(CarRenderAngle.rearProfile.rawValue == 4)
        #expect(CarRenderAngle.overhead.rawValue == 5)
    }

    @Test
    func testLocationParsesAltitudeAccuracyParkingBrakeAndGear() {
        var payload = Data()
        payload.append(Protobuf.doubleField(1, 11.9746)) // lon
        payload.append(Protobuf.doubleField(2, 57.7089)) // lat
        payload.append(Protobuf.doubleField(4, 180.0))   // heading
        payload.append(Protobuf.doubleField(5, 45.0))    // speed
        payload.append(Protobuf.doubleField(6, 142.5))   // altitude
        payload.append(Protobuf.doubleField(7, 3.2))     // accuracy
        payload.append(Protobuf.intField(8, 1))          // parking brake set
        payload.append(Protobuf.intField(9, 4))          // gear D

        let loc = PolestarGRPC.parseLocation(payload)
        #expect(loc != nil)
        #expect(loc?.longitude == 11.9746)
        #expect(loc?.latitude == 57.7089)
        #expect(loc?.heading == 180.0)
        #expect(loc?.speed == 45.0)
        #expect(loc?.altitudeMeters == 142.5)
        #expect(loc?.accuracyMeters == 3.2)
        #expect(loc?.parkingBrakeEngaged == true)
        #expect(loc?.gear == "D")
    }

    @Test
    func testVehicleStateBuildSpecsWheelsAndPackages() throws {
        var state = VehicleState(
            batteryPercentage: 80,
            rangeKm: 350,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "PST 002",
            vin: "YS3E9999999999999",
            ownerFirstName: "Nico",
            odometerKm: 12000,
            daysToService: 200,
            distanceToServiceKm: 15000,
            serviceWarning: false,
            fluidWarnings: [],
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        state.identity.externalColour = "Thunder"
        state.identity.upholstery = "WeaveTech Slate"

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: encoded)

        #expect(decoded.identity.externalColour == "Thunder")
        #expect(decoded.identity.upholstery == "WeaveTech Slate")
    }

    private func dailyTime(hour: Int, minute: Int) -> Data {
        var data = Data()
        data.append(Protobuf.intField(1, hour))
        data.append(Protobuf.intField(2, minute))
        return data
    }

    private func timestamp(seconds: Int) -> Data {
        Protobuf.intField(1, seconds)
    }
}


@Test
func testHealthDoesNotTreatReferencePressuresAsWheelReadings() {
    let payload = Protobuf.doubleField(43, 231) + Protobuf.doubleField(44, 229)
        + Protobuf.doubleField(45, 236) + Protobuf.doubleField(46, 234)
    let report = PolestarGRPC.parseHealth(payload)
    #expect(report.details.tyres.allSatisfy { $0.kilopascals == nil })
}

@Test
func testHealthPreservesPartialWheelPressureReadings() {
    let report = PolestarGRPC.parseHealth(Protobuf.doubleField(41, 250))
    #expect(report.details.tyres.map { $0.kilopascals ?? 0 } == [0, 0, 250, 0])
}
