import Foundation
import Testing
@testable import Hisingen

struct PolestarBatteryDescriptorTests {
    @Test(arguments: zip(1...16, [ChargingState.charging, .complete, .charging, .charging, .idle,
        .scheduled, .scheduled, .scheduled, .discharging, .discharging, .discharging,
        .smartCharging, .paused, .smartCharging, .fault, .complete]).map { ($0, $1) })
    func v2StatesTakePriority(value: Int, expected: ChargingState) throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.intField(7, 2) + Protobuf.intField(28, value))
        #expect(battery.chargingState == expected)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test func legacyFallbackAndUnknownV2() throws {
        #expect(try PolestarGRPC.parseBattery(Protobuf.intField(7, 7)).chargingState == .paused)
        #expect(try PolestarGRPC.parseBattery(Protobuf.intField(7, 8)).chargingState == .complete)
        #expect(try PolestarGRPC.parseBattery(Protobuf.intField(7, 2) + Protobuf.intField(28, 0)).chargingState == .idle)
        let unknown = try PolestarGRPC.parseBattery(Protobuf.intField(7, 2) + Protobuf.intField(28, 99))
        #expect(unknown.chargingState == .unknown("99"))
        #expect(unknown.unknownFields.map(\.field) == [28])
        let wrong = try PolestarGRPC.parseBattery(Protobuf.intField(7, 2) + Protobuf.doubleField(28, 1))
        #expect(wrong.chargingState == .idle)
        #expect(wrong.unknownFields.map(\.field) == [28])
    }

    @Test func automaticConsumptionAndDistanceAreSeparate() throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.doubleField(12, 23.8) + Protobuf.intField(9, 45))
        #expect(battery.diagnostics.averageConsumptionAutomatic == 23.8)
        #expect(battery.reportedBatteryCapacityKwh == nil)
        #expect(battery.diagnostics.timeToTargetDistanceMinutes == 45)
        #expect(battery.diagnostics.timeToTargetMinutes == nil)
        #expect(try PolestarGRPC.parseBattery(Protobuf.doubleField(12, 0)).diagnostics.averageConsumptionAutomatic == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -1])
    func invalidAutomaticConsumptionRemainsRaw(value: Double) throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.doubleField(12, value))
        #expect(battery.diagnostics.averageConsumptionAutomatic == nil)
        #expect(battery.unknownFields.map(\.field) == [12])
    }

    @Test func unsupportedFieldsStayRaw() throws {
        let data = Protobuf.intField(12, 1) + Protobuf.messageField(20, Data())
            + Protobuf.messageField(27, Data()) + Protobuf.intField(99, 1)
        let battery = try PolestarGRPC.parseBattery(data)
        #expect(battery.diagnostics.averageConsumptionAutomatic == nil)
        #expect(battery.unknownFields.map(\.field) == [12, 20, 27, 99])
    }
}
