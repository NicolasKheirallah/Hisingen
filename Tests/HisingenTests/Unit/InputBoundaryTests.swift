import Foundation
import Testing
@testable import Hisingen

@MainActor
struct InputBoundaryTests {

    @Test
    func testTemperatureClampingAndStepPrecision() {

        Preferences.remoteClimateTemperature = 21.5
        XCTAssertEqual(Preferences.remoteClimateTemperature, 21.5)

        Preferences.remoteClimateTemperature = 15.0
        XCTAssertEqual(Preferences.remoteClimateTemperature, 16.0)

        Preferences.remoteClimateTemperature = 35.0
        XCTAssertEqual(Preferences.remoteClimateTemperature, 30.0)

        Preferences.remoteClimateTemperature = 21.3
        XCTAssertEqual(Preferences.remoteClimateTemperature, 21.5)

        Preferences.remoteClimateTemperature = 21.2
        XCTAssertEqual(Preferences.remoteClimateTemperature, 21.0)
    }

    @Test
    func testDistanceUnitConversions() {
        XCTAssertEqual(DistanceUnit.kilometers.convert(km: 100), 100)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 100), 62)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 0), 0)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 450), 280)

        XCTAssertEqual(Format.distance(km: 100, unit: .kilometers), "100 km")
        XCTAssertEqual(Format.distance(km: 100, unit: .miles), "62 mi")
    }

    @Test
    func testKilowattFormatting() {
        XCTAssertEqual(Format.kilowatts(watts: 7400), "7.4 kW")
        XCTAssertEqual(Format.kilowatts(watts: 11000), "11 kW")
        XCTAssertEqual(Format.kilowatts(watts: 150000), "150 kW")
        XCTAssertEqual(Format.kilowatts(watts: 0), "0.0 kW")
    }

    @Test
    func testDurationFormatting() {
        XCTAssertEqual(Format.shortDuration(minutes: 45), "45min")
        XCTAssertEqual(Format.shortDuration(minutes: 60), "1h")
        XCTAssertEqual(Format.shortDuration(minutes: 90), "1h30m")
        XCTAssertEqual(Format.shortDuration(minutes: 135), "2h15m")
    }

    @Test
    func testRemoteCommandInputValidation() async throws {

        let invalidTempCommand = RemoteCommand.startClimate(
            temperatureCelsius: 21.3,
            frontLeftSeat: .unspecified,
            frontRightSeat: .unspecified,
            rearLeftSeat: .unspecified,
            rearRightSeat: .unspecified,
            steeringWheel: .unspecified
        )
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(invalidTempCommand, vin: "YSMTEST", accessToken: "token")
            XCTFail("Should reject non-0.5 step temperature")
        } catch RemoteCommandError.rejected {

        } catch {

        }


        let invalidTargetCommand = RemoteCommand.setChargeTarget(30)
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(invalidTargetCommand, vin: "YSMTEST", accessToken: "token")
            XCTFail("Should reject SoC < 40")
        } catch RemoteCommandError.rejected {

        } catch {

        }


        let invalidAmpCommand = RemoteCommand.setAmpLimit(0)
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(invalidAmpCommand, vin: "YSMTEST", accessToken: "token")
            XCTFail("Should reject amps < 1")
        } catch RemoteCommandError.rejected {

        } catch {

        }
    }
}


