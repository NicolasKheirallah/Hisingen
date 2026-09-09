import Foundation
import Testing
@testable import Hisingen

struct VehicleEquipmentTests {
    private func response(_ fields: Data) -> Data {
        Protobuf.messageField(1, Protobuf.messageField(1, Protobuf.stringField(1, "VIN-A") + fields))
    }

    @Test func honkModesKeepIndependentActionsSeparate() throws {
        let expected = [[false, false, false], [true, false, false], [true, true, true],
                        [false, true, false], [false, false, true]]
        let commands: [RemoteCommand] = [.honkAndFlash, .flashLights, .honkHorn]
        for raw in 1...5 {
            let caps = try #require(PolestarGRPC.parseMyCars(response(Protobuf.intField(16, raw)), vin: "VIN-A"))
            for (index, command) in commands.enumerated() {
                #expect(caps.honkFlashMode?.permits(command) == expected[raw - 1][index])
            }
        }
        for raw in [0, 99] {
            let caps = try #require(PolestarGRPC.parseMyCars(response(Protobuf.intField(16, raw)), vin: "VIN-A"))
            #expect(caps.honkFlashMode?.permits(.honkHorn) == nil)
        }
    }

    @Test func unsupportedHornRejectsBeforeNetwork() async throws {
        let grpc = PolestarGRPC()
        var caps = VehicleOTACapabilities()
        caps.honkFlashMode = .flashOnly
        await grpc.setCapabilityLimitsForTesting(vin: "VIN-A", caps)
        do {
            _ = try await grpc.executeRemoteCommand(.honkHorn, vin: "VIN-A", accessToken: "test", commandToken: "test")
            Issue.record("Expected unsupported command rejection")
        } catch RemoteCommandError.unsupported { }
    }

    @Test func equipmentFlowsIntoDetailsPresetsAndCapacity() throws {
        let target = Protobuf.intField(1, 1) + Protobuf.intField(2, 40)
            + Protobuf.intField(5, 85) + Protobuf.intField(6, 1)
        let charging = Protobuf.intField(2, 2) + Protobuf.stringField(3, "TEST-PACK")
            + Protobuf.messageField(8, target) + Protobuf.intField(36, 1)
        let propulsion = Protobuf.intField(1, 1) + Protobuf.floatField(5, 78) + Protobuf.intField(6, 1)
        let air = Protobuf.intField(2, 1) + Protobuf.intField(3, 0) + Protobuf.intField(7, 1) + Protobuf.intField(8, 5)
        let fields = Protobuf.messageField(35, charging) + Protobuf.messageField(40, propulsion)
            + Protobuf.messageField(34, air) + Protobuf.intField(43, 4) + Protobuf.intField(46, 1)
            + Protobuf.messageField(73, Data([1, 2, 21]))
        let caps = try #require(PolestarGRPC.parseMyCars(response(fields), vin: "VIN-A"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.chargePort == "Left")
        #expect(equipment.batterySerial == "TEST-PACK")
        #expect(equipment.airCleaningRuntimeMinutes == 5)
        #expect(equipment.internalAirMeasurement == true)
        #expect(equipment.externalAirMeasurement == false)
        #expect(equipment.doorCount == 4)
        #expect(equipment.supportedLightWarnings?.count == 3)
        #expect(equipment.details.contains { $0.title == "DC Charge Port" && $0.value == L10n.text("Left") })
        let bounds = VehicleChargeBounds(capabilities: caps)
        #expect(bounds.dailyTarget == 85)
        #expect(bounds.targetPresets().contains(85))
        #expect(PolestarAPI.resolvedBatteryCapacity(graphQL: nil, batteryService: nil, equipment: equipment) == 78)
        #expect(PolestarAPI.resolvedBatteryCapacity(graphQL: 80, batteryService: 79, equipment: equipment) == 80)
        #expect(PolestarAPI.resolvedBatteryCapacity(graphQL: .nan, batteryService: 79, equipment: equipment) == 79)
        let decoded = try JSONDecoder().decode(VehicleOTACapabilities.self, from: JSONEncoder().encode(caps))
        #expect(decoded == caps)
    }

    @Test func absentMetadataStaysUnknownAndMalformedPackedValuesAreRejected() throws {
        let caps = try #require(PolestarGRPC.parseMyCars(response(Data()), vin: "VIN-A"))
        #expect(caps.equipment?.details.isEmpty == true)
        #expect(caps.equipment?.supportedLightWarnings == nil)
        #expect(Protobuf.packedVarints(Data([128])) == nil)
        #expect(Protobuf.packedVarints(Data(repeating: 255, count: 10)) == nil)
        #expect(Protobuf.packedVarints(Protobuf.varint(UInt64.max)) == [UInt64.max])
        var equipment = VehicleEquipment()
        #expect(!equipment.softwareVersionDisagrees(with: "5.1"))
        equipment.restrictedSoftwareVersion = "5.2"
        #expect(equipment.softwareVersionDisagrees(with: "5.1"))
    }
}
