import Foundation
import Testing
@testable import Hisingen

struct PolestarClimateDescriptorTests {
    private func twin(_ fields: Data) -> VehicleClimateStatus {
        PolestarGRPC.parseClimate(Protobuf.messageField(1, Protobuf.intField(1, 1)) + fields)
    }

    @Test func requestedHeatingUsesDescriptorPositionsAndLevels() {
        var fields = Data()
        for (tag, value) in [(9, 1), (10, 2), (11, 3), (12, 4), (13, 0)] {
            fields += Protobuf.intField(tag, value)
        }
        let result = twin(fields)
        #expect(result.driverSeatHeatingLevel == 0)
        #expect(result.passengerSeatHeatingLevel == 1)
        #expect(result.rearLeftSeatHeatingLevel == 2)
        #expect(result.rearRightSeatHeatingLevel == 3)
        #expect(result.steeringWheelHeatingLevel == nil)
        let wheel = twin(Protobuf.intField(13, 4) + Protobuf.intField(9, 0))
        #expect(wheel.steeringWheelHeatingLevel == 3)
        #expect(wheel.driverSeatHeatingLevel == nil)
    }

    @Test func ventilationRespectsRunningState() {
        let heat = twin(Protobuf.intField(2, 1) + Protobuf.intField(6, 2))
        #expect(heat.activity == .heating && heat.ventilation == "VENTILATION_HEATING")
        let cool = twin(Protobuf.intField(2, 1) + Protobuf.intField(6, 1))
        #expect(cool.activity == .cooling && cool.ventilation == "VENTILATION_COOLING")
        let neutral = twin(Protobuf.intField(2, 1) + Protobuf.intField(6, 3))
        #expect(neutral.activity == .active && neutral.ventilation == "VENTILATION_NEUTRAL")
        #expect(twin(Protobuf.intField(2, 2) + Protobuf.intField(6, 2)).activity == .idle)
        #expect(twin(Protobuf.intField(2, 3) + Protobuf.intField(6, 1)).activity == .starting)
    }

    @Test func unknownAndWrongWireValuesRemainRaw() {
        var fields = Protobuf.intField(2, 1)
        fields += Protobuf.intField(6, 99)
        fields += Protobuf.intField(9, 99)
        fields += Protobuf.stringField(10, "x")
        fields += Protobuf.intField(4, 2)
        fields += Protobuf.intField(5, 1)
        let result = twin(fields)
        #expect(result.activity == .active && result.ventilation == nil)
        #expect(result.driverSeatHeatingLevel == nil && result.passengerSeatHeatingLevel == nil)
        #expect(result.errors == [L10n.text("Battery level low")])
        #expect(result.climateWarnings == ["BATTERY_LOW"])
        #expect(Set((result.unknownWireFields ?? []).map(\.field)) == Set([6, 9, 10]))
        let wrongVentilation = twin(Protobuf.intField(2, 1) + Protobuf.stringField(6, "x"))
        #expect(wrongVentilation.ventilation == nil)
        #expect(wrongVentilation.unknownWireFields?.first?.field == 6)
    }

    @Test func legacyClimateKeepsItsOwnShape() {
        let result = PolestarGRPC.parseClimate(Protobuf.intField(1, 5) + Protobuf.intField(4, 2) + Protobuf.intField(9, 4))
        #expect(result.activity == .heating)
        #expect(result.driverSeatHeatingLevel == nil && result.ventilation == nil)
        #expect(result.unknownWireFields?.first?.field == 9)
    }
}
