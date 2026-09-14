import Foundation
import Testing
@testable import Hisingen

@MainActor
struct InputBoundaryTests {

    @Test
    func testTemperatureClampingAndStepPrecision() throws {

        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        store.remoteClimateTemperature = 21.5
        #expect(store.remoteClimateTemperature == 21.5)

        store.remoteClimateTemperature = 15.0
        #expect(store.remoteClimateTemperature == 16.0)

        store.remoteClimateTemperature = 35.0
        #expect(store.remoteClimateTemperature == 30.0)

        store.remoteClimateTemperature = 21.3
        #expect(store.remoteClimateTemperature == 21.5)

        store.remoteClimateTemperature = 21.2
        #expect(store.remoteClimateTemperature == 21.0)
    }

    @Test
    func testDistanceUnitConversions() {
        #expect(DistanceUnit.kilometers.convert(km: 100) == 100)
        #expect(DistanceUnit.miles.convert(km: 100) == 62)
        #expect(DistanceUnit.miles.convert(km: 0) == 0)
        #expect(DistanceUnit.miles.convert(km: 450) == 280)

        #expect(Format.distance(km: 100, unit: .kilometers) == "100 km")
        #expect(Format.distance(km: 100, unit: .miles) == "62 mi")
    }

    @Test
    func testKilowattFormatting() {
        // Locale-aware decimals rule: sub-10 kW keeps one fraction digit, 10 kW and up none.
        func expectedKw(_ kw: Double) -> String {
            let decimals = kw >= 10 ? 0 : 1
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = decimals
            formatter.maximumFractionDigits = decimals
            return formatter.string(from: NSNumber(value: kw))! + " kW"
        }
        #expect(Format.kilowatts(watts: 7400) == expectedKw(7.4))
        #expect(Format.kilowatts(watts: 11000) == expectedKw(11))
        #expect(Format.kilowatts(watts: 150000) == expectedKw(150))
        #expect(Format.kilowatts(watts: 0) == expectedKw(0))
    }

    @Test
    func testDurationFormatting() {
        #expect(Format.shortDuration(minutes: 45) == "45min")
        #expect(Format.shortDuration(minutes: 60) == "1h")
        #expect(Format.shortDuration(minutes: 90) == "1h30m")
        #expect(Format.shortDuration(minutes: 135) == "2h15m")
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
            Issue.record("Should reject non-0.5 step temperature")
        } catch RemoteCommandError.rejected(let message) {
            #expect(message != nil, "local rejection must explain what was wrong")
        } catch {
            Issue.record("Unexpected error \(error): input must be rejected locally, before any network dispatch")
        }


        let invalidTargetCommand = RemoteCommand.setChargeTarget(30)
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(invalidTargetCommand, vin: "YSMTEST", accessToken: "token")
            Issue.record("Should reject SoC < 40")
        } catch RemoteCommandError.rejected(let message) {
            #expect(message != nil, "local rejection must explain what was wrong")
        } catch {
            Issue.record("Unexpected error \(error): input must be rejected locally, before any network dispatch")
        }


        let invalidAmpCommand = RemoteCommand.setAmpLimit(0)
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(invalidAmpCommand, vin: "YSMTEST", accessToken: "token")
            Issue.record("Should reject amps < 1")
        } catch RemoteCommandError.rejected(let message) {
            #expect(message != nil, "local rejection must explain what was wrong")
        } catch {
            Issue.record("Unexpected error \(error): input must be rejected locally, before any network dispatch")
        }
    }
}


