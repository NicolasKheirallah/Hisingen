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
        XCTAssertEqual(software.latestAvailableVersion, "P4.2.1")
        XCTAssertNil(software.installedVersion)
    }

    @Test
    func testSettledSoftwareStateReportsRunningVersionRatherThanAnOffer() {
        var payload = Data()
        payload.append(Protobuf.stringField(1, "sw-9f2c"))
        payload.append(Protobuf.intField(4, 9))
        payload.append(Protobuf.stringField(6, "P2.14.3"))
        let software = PolestarGRPC.parseSoftware(payload)
        XCTAssertEqual(software.state, .completed)
        XCTAssertEqual(software.installedVersion, "P2.14.3")
        XCTAssertNil(software.latestAvailableVersion)
    }

    @Test
    func testMissingVersionStringIsReportedAsUnknownNotSubstituted() {
        var payload = Data()
        payload.append(Protobuf.intField(4, 9))
        let software = PolestarGRPC.parseSoftware(payload)
        XCTAssertNil(software.version)
        XCTAssertNil(software.title)
        XCTAssertNil(software.installedVersion)
        XCTAssertNil(software.latestAvailableVersion)
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
            XCTAssertEqual(PolestarGRPC.softwareState(raw), state)
        }
        // A failed install still describes a target version, not what the car is running.
        var payload = Data()
        payload.append(Protobuf.intField(4, 8))
        payload.append(Protobuf.stringField(6, "P2.15.0"))
        let failed = PolestarGRPC.parseSoftware(payload)
        XCTAssertNil(failed.installedVersion)
        XCTAssertEqual(failed.latestAvailableVersion, "P2.15.0")
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
        XCTAssertEqual(merged.softwareInfo?.installedVersion, "P2.14.3")
        XCTAssertEqual(merged.softwareInfo?.latestAvailableVersion, "P2.15.0")
        XCTAssertEqual(merged.softwareInfo?.state, .available)

        // A different car must not inherit the previous car's version.
        var otherCar = vehicle(vin: "YSMOTHER")
        otherCar.softwareInfo = offered.softwareInfo
        XCTAssertNil(otherCar.mergingLastKnown(from: settled, features: .default)
            .softwareInfo?.installedVersion)
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

    @Test
    func testHealthParsesSpecificLightFailures() {
        var payload = Data()
        payload.append(Protobuf.intField(14, 2)) // Left low beam
        payload.append(Protobuf.intField(17, 2)) // Right high beam
        payload.append(Protobuf.intField(26, 2)) // Left brake light
        let report = PolestarGRPC.parseHealth(payload)
        XCTAssertTrue(report.details.warnings.contains(.exteriorLight))
        XCTAssertEqual(report.details.lightFailures.count, 3)
        XCTAssertTrue(report.details.lightFailures.contains("Left low beam"))
        XCTAssertTrue(report.details.lightFailures.contains("Right high beam"))
        XCTAssertTrue(report.details.lightFailures.contains("Left brake light"))
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
        state.structureWeek = "202240"
        state.internalVehicleIdentifier = "UUID-POL-12345"
        state.pno34 = "PNO34-SPEC-2023"
        state.accountMarket = "SE"

        XCTAssertEqual(state.formattedBuildWeek, "2022 · W40")

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: encoded)

        XCTAssertEqual(decoded.structureWeek, "202240")
        XCTAssertEqual(decoded.formattedBuildWeek, "2022 · W40")
        XCTAssertEqual(decoded.internalVehicleIdentifier, "UUID-POL-12345")
        XCTAssertEqual(decoded.pno34, "PNO34-SPEC-2023")
        XCTAssertEqual(decoded.accountMarket, "SE")
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
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules.first?.locationName, "Home Garage")
        XCTAssertEqual(schedules.first?.startHour, 22)
        XCTAssertEqual(schedules.first?.endHour, 6)
        XCTAssertTrue(schedules.first?.isActive == true)
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
        XCTAssertEqual(climate.activity, .heating)
        XCTAssertEqual(climate.driverSeatHeatingLevel, 3)
        XCTAssertEqual(climate.passengerSeatHeatingLevel, 2)
        XCTAssertEqual(climate.steeringWheelHeatingLevel, 1)
    }

    @Test
    func testVehicleProbedCapabilitiesInspector() {
        var probed = VehicleProbedCapabilities()
        probed.record(.climateStartStop, as: .supported)
        probed.record(.windows, as: .unavailable)
        probed.record(.softwareInstallControl, as: .supported)

        XCTAssertEqual(probed.support(for: .climateStartStop), .supported)
        XCTAssertEqual(probed.support(for: .windows), .unavailable)
        XCTAssertEqual(probed.allResults.count, 3)
        XCTAssertEqual(probed.resultsMap[.softwareInstallControl], .supported)
    }

    @Test
    func testCarRenderAnglePreferences() {
        XCTAssertEqual(CarRenderAngle.allCases.count, 4)
        XCTAssertEqual(CarRenderAngle.frontThreeQuarter.rawValue, 0)
        XCTAssertEqual(CarRenderAngle.rearThreeQuarter.rawValue, 1)
        XCTAssertEqual(CarRenderAngle.sideProfile.rawValue, 2)
        XCTAssertEqual(CarRenderAngle.overhead.rawValue, 3)
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
        XCTAssertNotNil(loc)
        XCTAssertEqual(loc?.longitude, 11.9746)
        XCTAssertEqual(loc?.latitude, 57.7089)
        XCTAssertEqual(loc?.heading, 180.0)
        XCTAssertEqual(loc?.speed, 45.0)
        XCTAssertEqual(loc?.altitudeMeters, 142.5)
        XCTAssertEqual(loc?.accuracyMeters, 3.2)
        XCTAssertEqual(loc?.parkingBrakeEngaged, true)
        XCTAssertEqual(loc?.gear, "D")
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
        state.externalColour = "Thunder"
        state.upholstery = "WeaveTech Slate"
        state.wheels = "19\" 5-Double Spoke"
        state.packages = ["Pilot Pack", "Plus Pack"]

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: encoded)

        XCTAssertEqual(decoded.externalColour, "Thunder")
        XCTAssertEqual(decoded.upholstery, "WeaveTech Slate")
        XCTAssertEqual(decoded.wheels, "19\" 5-Double Spoke")
        XCTAssertEqual(decoded.packages, ["Pilot Pack", "Plus Pack"])
    }

    private func dailyTime(hour: Int, minute: Int) -> Data {
        var data = Data()
        data.append(Protobuf.intField(1, hour))
        data.append(Protobuf.intField(2, minute))
        return data
    }
}


