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
        let exterior = try XCTUnwrap(PolestarGRPC.parseExterior(payload))
        XCTAssertEqual(exterior.isLocked, true)
        XCTAssertEqual(Set(exterior.itemsNeedingAttention), [.frontLeftDoor, .tailgate])

        var update = Data()
        update.append(Protobuf.intField(3, 2))
        let merged = try XCTUnwrap(PolestarGRPC.parseExterior(update)).merging(previous: exterior)
        XCTAssertEqual(merged.itemsNeedingAttention, [.tailgate])
        XCTAssertEqual(merged.isLocked, true)
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
        payload.append(Protobuf.doubleField(40, 0))
        payload.append(Protobuf.intField(38, 2))
        let report = PolestarGRPC.parseHealth(payload)
        XCTAssertEqual(report.daysToService, 24)
        XCTAssertTrue(report.serviceWarning)
        XCTAssertEqual(report.details.tyres.first?.kilopascals, 208.5)
        XCTAssertEqual(report.details.tyres.first?.warning, .low)
        XCTAssertNil(report.details.tyres.last?.kilopascals)
        XCTAssertTrue(report.details.warnings.contains(.lowVoltageBattery))
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
        XCTAssertEqual(software.version, "P4.2.1")
        XCTAssertEqual(software.title, "Polestar OS")
        XCTAssertEqual(software.state, .scheduled)
        XCTAssertEqual(software.scheduledAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func testGlobalAndLocationSchedulesDecodeWithoutCoordinates() throws {
        let start = dailyTime(hour: 22, minute: 30)
        let stop = dailyTime(hour: 6, minute: 15)
        var global = Data()
        global.append(Protobuf.messageField(1, start))
        global.append(Protobuf.messageField(2, stop))
        global.append(Protobuf.intField(3, 1))
        let globalSchedule = try XCTUnwrap(PolestarGRPC.parseGlobalChargeTimer(global))
        XCTAssertEqual(globalSchedule.startHour, 22)
        XCTAssertEqual(globalSchedule.endHour, 6)

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
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules[0].weekdays, [.monday, .wednesday, .friday])
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
        XCTAssertEqual(status.activity, .ventilating)
        XCTAssertEqual(status.timeRemainingMinutes, 18)
        XCTAssertTrue(status.timerTriggered)

        var timer = Data()
        timer.append(Protobuf.stringField(1, "timer-1"))
        timer.append(Protobuf.messageField(3, dailyTime(hour: 7, minute: 0)))
        timer.append(Protobuf.intField(4, 1))
        timer.append(Protobuf.packedIntField(6, [1, 2, 3, 4, 5]))
        let timers = PolestarGRPC.parseClimateTimers(Protobuf.messageField(3, timer))
        XCTAssertEqual(timers.first?.startHour, 7)
        XCTAssertEqual(timers.first?.weekdays.count, 5)
    }

    @Test
    func testOdometerTripMetersAndBatteryDiagnosticsDecode() {
        var odometer = Data()
        odometer.append(Protobuf.intField(2, 25_123_000))
        odometer.append(Protobuf.doubleField(3, 42.5))
        odometer.append(Protobuf.doubleField(4, 18.25))
        let report = PolestarGRPC.parseOdometer(odometer)
        XCTAssertEqual(report.odometerKm, 25_123)
        XCTAssertEqual(report.manualTripKm, 42.5)
        XCTAssertEqual(report.automaticTripKm, 18.25)

        var battery = Data()
        battery.append(Protobuf.doubleField(3, 18.4))
        battery.append(Protobuf.intField(9, 60))
        battery.append(Protobuf.doubleField(13, 19.1))
        battery.append(Protobuf.doubleField(16, 12_400))
        battery.append(Protobuf.intField(26, 4))
        let diagnostics = PolestarGRPC.parseBattery(battery).diagnostics
        XCTAssertEqual(diagnostics.chargerPowerState, .providingPower)
        XCTAssertEqual(diagnostics.timeToTargetMinutes, 60)
        XCTAssertEqual(diagnostics.energyUsedSinceChargeWh, 12_400)
    }

    @Test
    func testVehicleStateCacheDecodesBeforeCapabilityFieldsExisted() throws {
        let original = vehicle()
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["exteriorStatus", "healthDetails", "softwareInfo", "chargingSchedules",
                    "climateStatus", "climateTimers", "tripMeterManualKm", "tripMeterAutomaticKm",
                    "connectivity", "airQuality", "batteryDiagnostics", "unavailableFeatures"] {
            object.removeValue(forKey: key)
        }
        let oldCache = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: oldCache)
        XCTAssertEqual(decoded.vin, original.vin)
        XCTAssertEqual(decoded.chargingSchedules, [])
        XCTAssertEqual(decoded.unavailableFeatures, [])
    }

    @Test
    func testAmpLimitReadResponseParsesCorrectly() throws {

        var inner = Data()
        inner.append(Protobuf.intField(1, 16))
        var response = Data()
        response.append(Protobuf.messageField(3, inner))

        let limit = PolestarGRPC.fetchAmpLimitResponse(response)
        XCTAssertEqual(limit, 16)
    }

    @Test
    func testAmpLimitReadRejectsZeroAndOutOfRange() {
        var inner = Data()
        inner.append(Protobuf.intField(1, 0))
        var response = Data()
        response.append(Protobuf.messageField(3, inner))
        XCTAssertNil(PolestarGRPC.fetchAmpLimitResponse(response))
    }

    @Test
    func testLocationParsesLatitudeAndLongitude() {
        var compact = Data()
        compact.append(Protobuf.doubleField(1, 12.5))
        compact.append(Protobuf.doubleField(2, 55.7))
        let location = PolestarGRPC.parseLocation(compact)
        XCTAssertEqual(location?.longitude, 12.5)
        XCTAssertEqual(location?.latitude, 55.7)
        XCTAssertNil(location?.heading)
        XCTAssertNil(location?.timestamp)
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
        XCTAssertEqual(location?.longitude, 10.0)
        XCTAssertEqual(location?.latitude, 60.0)
        XCTAssertEqual(location?.heading, 180.0)
        XCTAssertEqual(location?.timestamp, Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func testWeatherParsesTemperatureAndTimestamp() {

        var report = Data()
        report.append(Protobuf.intField(1, 2_000_000_000_000))
        report.append(Protobuf.doubleField(2, 15.5))
        let weather = PolestarGRPC.parseWeather(report)
        XCTAssertEqual(weather?.temperatureCelsius, 15.5)
        XCTAssertEqual(weather?.timestamp, Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func testWeatherWithNoDataReturnsNil() {
        let empty = Data()
        XCTAssertNil(PolestarGRPC.parseWeather(empty))
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

        let frames = stream.map { $0 }
        XCTAssertEqual(frames.count, stream.count)

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
        XCTAssertEqual(parsedFrames.count, 2)
        XCTAssertEqual(Protobuf.fields(parsedFrames[0]).first(where: { $0.number == 1 })?.varint, 42)
        XCTAssertEqual(Protobuf.fields(parsedFrames[1]).first(where: { $0.number == 1 })?.varint, 99)
    }

    private func dailyTime(hour: Int, minute: Int) -> Data {
        var data = Data()
        data.append(Protobuf.intField(1, hour))
        data.append(Protobuf.intField(2, minute))
        return data
    }
}


