import Foundation
import Testing
@testable import Hisingen

struct VolvoDecodingGapTests {

    @Test
    func testInitializationStatusMapsToInitializing() {
        #expect(ChargerPowerState(volvoPowerStatus: "INITIALIZATION") == .initializing)
        #expect(ChargerPowerState(volvoPowerStatus: "INITIALIZING") == .initializing)
    }

    @Test
    func testPowerAvailableButNotActivatedIsDistinct() throws {
        let state = ChargerPowerState(volvoPowerStatus: "POWER_AVAILABLE_BUT_NOT_ACTIVATED")
        #expect(state == .powerAvailableNotActivated)
        #expect(state.displayName == L10n.text("Power available, not charging"))
        #expect(ChargerPowerState(volvoPowerStatus: "POWER_AVAILABLE") == .providingPower)

        let encoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ChargerPowerState.self, from: encoded) == state)
    }

    @Test
    func testOTAInstallationReasonHasReadableLabel() throws {
        let json = #"{"data":{"availabilityStatus":{"value":"UNAVAILABLE","unavailableReason":"OTA_INSTALLATION_IN_PROGRESS"}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoCommandAccessibilityDTO>.self, from: Data(json.utf8))
        let dto = try #require(envelope.data)
        #expect(dto.reason == L10n.text("Software update in progress"))
    }

    @Test
    func testLampNameReadsVolvoLabelWithoutRawValue() {
        #expect(VehicleLampFailureName.name(for: "Left brake light: BULB_FAILURE") == "Left brake light")
        #expect(VehicleLampFailureName.name(for: "Turn indicator front left: FAILURE") == "Turn indicator front left")
    }

    @Test
    func testLampNameKeepsPlainLabels() {
        #expect(VehicleLampFailureName.name(for: "Brake light left") == "Brake light left")
    }

    @Test
    func testLampNameSplitsFieldKeysIntoWords() {
        #expect(VehicleLampFailureName.name(for: "brakeLightLeft") == "Brake light left")
        #expect(VehicleLampFailureName.name(for: "brakeLightLeftWarning: BULB_FAILURE") == "Brake light left")
        #expect(VehicleLampFailureName.name(for: "turn_indication_rear_right") == "Turn indication rear right")
    }

    @Test
    func testWarningsEntriesFeedOneLampNamePerBulb() throws {
        let json = """
        {"data":{"brakeLightLeftWarning":{"value":"BULB_FAILURE"},"hazardLightsWarning":{"value":"FAULT"}}}
        """
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoWarningsDTO>.self, from: Data(json.utf8))
        let names = try #require(envelope.data).activeWarnings.map(VehicleLampFailureName.name(for:))
        #expect(names == [L10n.text("Left brake light"), L10n.text("Hazard warning lights")])
    }

    @Test
    func testLocationSpeedDecodesBesideData() throws {
        let json = #"{"data":{"position":{"latitude":57.71,"longitude":11.97},"speed":{"value":42}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoLocationDTO>.self, from: Data(json.utf8))
        #expect(try #require(envelope.data).speedKmH == 42)
    }

    @Test
    func testLocationSpeedZeroIsAReading() throws {
        let json = #"{"data":{"speed":{"value":0,"unit":"kilometers/hour"}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoLocationDTO>.self, from: Data(json.utf8))
        #expect(try #require(envelope.data).speedKmH == 0)
    }

    @Test
    func testLocationSpeedConvertsMilesPerHour() throws {
        let json = #"{"data":{"speed":{"value":10,"unit":"mph"}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoLocationDTO>.self, from: Data(json.utf8))
        let dto = try #require(envelope.data)
        let speed = try #require(dto.speedKmH)
        #expect(abs(speed - 16.09344) < 0.0001)
    }

    @Test
    func testLocationWithoutSpeedLeavesItAbsent() throws {
        let json = #"{"data":{"geometry":{"coordinates":[11.97,57.71]}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoLocationDTO>.self, from: Data(json.utf8))
        #expect(try #require(envelope.data).speedKmH == nil)
    }

    @Test
    func testNoneFuelTypeIsBatteryAndSkipsFuelRead() {
        #expect(VolvoPowertrain.classify(fuelType: "NONE") == .bev)
        #expect(!VolvoAPI.needsFuelRead(powertrain: VolvoPowertrain.classify(fuelType: "NONE"), fuelType: "NONE"))
    }

    @Test
    func testElectricFuelTypesSkipFuelRead() {
        for fuelType in ["ELECTRIC", "BATTERY_ELECTRIC_VEHICLE"] {
            let powertrain = VolvoPowertrain.classify(fuelType: fuelType)
            #expect(powertrain == .bev)
            #expect(!VolvoAPI.needsFuelRead(powertrain: powertrain, fuelType: fuelType))
        }
    }

    @Test
    func testCombustionAndHybridFuelTypesReadFuel() {
        for fuelType in ["DIESEL", "PETROL", "PETROL/ELECTRIC"] {
            let powertrain = VolvoPowertrain.classify(fuelType: fuelType)
            #expect(VolvoAPI.needsFuelRead(powertrain: powertrain, fuelType: fuelType))
        }
    }

    @Test
    func testUnrecognisedFuelTypeStillReadsFuel() {
        #expect(VolvoAPI.needsFuelRead(powertrain: .unknown, fuelType: "HYDROGEN"))
        #expect(!VolvoAPI.needsFuelRead(powertrain: .unknown, fuelType: nil))
    }
}
