import Foundation
import Testing
@testable import Hisingen

struct PolestarUndecodedCaptureTests {
    private func capture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "polestar-c3-undecoded-" + name,
                                                 withExtension: "protobuf"))
        return try Data(contentsOf: url)
    }

    @Test func capabilityCaptureRetainsRemainingUnidentifiedFields() throws {
        let result = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        let raw = try #require(result.unknownWireFields)
        // Every tag the 5.14.0 client names is decoded now; 35.43 is the one field the
        // client build itself does not know, so it stays raw until a newer schema names it.
        let expected = Set(["35.43"])
        let actual = Set(raw.map { item in
            item.subfield.map { "\($0).\(item.field)" } ?? String(item.field)
        })
        #expect(actual == expected)
        #expect(raw.count == expected.count)
        // The tags decoded from the recovered app schema now decode from this same capture.
        #expect(result.equipment?.grossVehicleWeightRatingKg == 2600)
        #expect(result.advertisedCapabilities?[.locks] == true)
        #expect(result.advertisedCapabilities?[.reducedGuardLock] == true)
        #expect(result.advertisedCapabilities?[.climateStartStop] == true)
        #expect(result.advertisedCapabilities?[.remoteUnlock] == true)
        #expect(result.climatizationType == .heatingAndCooling)
        #expect(result.climatizationMaximumRuntimeMinutes == 30)
        #expect(result.controlSettings?.timersPerLocationMaximum == 1)
        #expect(result.controlSettings?.departureTimesPerLocationMaximum == 1)
        #expect(result.controlSettings?.locationDepartureTimes == true)
        // This frame carries neither 35.29 nor 35.20, so the pair stays absent rather than
        // invented; the wiring test covers the flag-and-identifier combination.
        #expect(!result.supportsPlugAndCharge)
        #expect(result.plugAndChargeIdentifier == nil)
    }

    @Test func batteryCaptureKeepsProviderKilometresAndDecodesV2Charging() throws {
        let result = try PolestarGRPC.parseBattery(capture("battery"))
        #expect(result.rangeKm == 140)
        #expect(result.unknownFields.isEmpty)
        #expect(result.chargingState == .charging)
        #expect(result.reportedBatteryCapacityKwh == nil)
    }

    @Test func idleClimateCaptureDoesNotInventHeatingOrSeatLevels() throws {
        var payload = Protobuf.messageField(1, Protobuf.intField(1, 1))
        payload += try capture("climate")
        let result = PolestarGRPC.parseClimate(payload)
        #expect(result.activity == .idle)
        #expect(result.driverSeatHeatingLevel == nil)
        #expect(result.passengerSeatHeatingLevel == nil)
        #expect(result.steeringWheelHeatingLevel == nil)
        #expect(result.unknownWireFields == nil)
        #expect(result.ventilation == "VENTILATION_NEUTRAL")
    }

    @Test func activeClimateCaptureDoesNotInventAutomaticHeaterLevels() throws {
        var payload = Protobuf.messageField(1, Protobuf.intField(1, 1))
        payload += try capture("climate-active")
        let result = PolestarGRPC.parseClimate(payload)
        #expect(result.activity == .heating)
        #expect(result.requestedTemperatureCelsius == 22)
        #expect(result.timeRemainingMinutes == 30)
        #expect(result.driverSeatHeatingLevel == nil)
        #expect(result.passengerSeatHeatingLevel == nil)
        #expect(result.steeringWheelHeatingLevel == nil)
        #expect(result.ventilation == "VENTILATION_HEATING")
        #expect(result.unknownWireFields == nil)
    }
}
