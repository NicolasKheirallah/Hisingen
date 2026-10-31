import Foundation
import Testing
@testable import Hisingen

struct PolestarFieldWiringTests {
    @Test func milesFallbackPreservesKilometrePriorityAndZero() throws {
        let miles = Protobuf.intField(8, 100)
        #expect(try PolestarGRPC.parseBattery(miles).rangeKm == 161)
        #expect(try PolestarGRPC.parseBattery(miles + Protobuf.intField(4, 250)).rangeKm == 250)
        #expect(try PolestarGRPC.parseBattery(miles + Protobuf.intField(4, 0)).rangeKm == 0)
        #expect(try PolestarGRPC.parseBattery(Protobuf.intField(8, 0)).rangeKm == 0)
        let wrongWire = try PolestarGRPC.parseBattery(Protobuf.doubleField(8, 100))
        #expect(wrongWire.rangeKm == nil)
        #expect(wrongWire.unknownFields.map(\.field) == [8])
    }

    @Test func tripTotalsPersistWithoutBecomingCapacityOrSinceCharge() throws {
        let payload = Protobuf.doubleField(12, 78)
            + Protobuf.doubleField(14, 12_500)
            + Protobuf.doubleField(15, 0)
            + Protobuf.doubleField(16, 4_000)
            + Protobuf.messageField(20, Protobuf.doubleField(1, 100))
            + Protobuf.intField(99, 3)
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.reportedBatteryCapacityKwh == nil)
        #expect(battery.diagnostics.energyUsedManualTripWh == 12_500)
        #expect(battery.diagnostics.energyUsedAutomaticTripWh == 0)
        #expect(battery.diagnostics.energyUsedSinceChargeWh == 4_000)
        #expect(battery.diagnostics.averageConsumptionAutomatic == 78)
        #expect(battery.unknownFields.map(\.field) == [20, 99])

        var state = vehicle(vin: "TEST-VIN")
        state.applyLiveUpdate(.battery(battery))
        #expect(state.energy.diagnostics?.unknownWireFields.map(\.field) == [20, 99])
        let restored = try JSONDecoder().decode(VehicleState.self, from: JSONEncoder().encode(state))
        #expect(restored.energy.diagnostics?.energyUsedManualTripWh == 12_500)
        #expect(restored.energy.diagnostics?.energyUsedAutomaticTripWh == 0)

        let oldJSON = Data(#"{"chargerPowerState":"unknown"}"#.utf8)
        let old = try JSONDecoder().decode(BatteryDiagnostics.self, from: oldJSON)
        #expect(old.energyUsedManualTripWh == nil)
        #expect(old.energyUsedAutomaticTripWh == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1])
    func invalidTripEnergyRemainsRaw(value: Double) throws {
        let result = try PolestarGRPC.parseBattery(Protobuf.doubleField(14, value))
        #expect(result.diagnostics.energyUsedManualTripWh == nil)
        #expect(result.unknownFields.map(\.field) == [14])
    }

    @Test func tripTotalsRejectUnexpectedWireTypes() throws {
        let result = try PolestarGRPC.parseBattery(Protobuf.intField(14, 100) + Protobuf.stringField(15, "unknown"))
        #expect(result.diagnostics.energyUsedManualTripWh == nil)
        #expect(result.diagnostics.energyUsedAutomaticTripWh == nil)
        #expect(result.unknownFields.map(\.field) == [14, 15])
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7])
    func availabilityDecodesUsageIndependentlyOfReachability(raw: Int) {
        let payload = Protobuf.intField(3, 2) + Protobuf.intField(4, 2) + Protobuf.intField(5, raw)
        let result = PolestarGRPC.parseAvailabilityReport(Protobuf.messageField(3, payload))
        let expected = ["ABANDONED", "INACTIVE", "CONVENIENCE", "ACTIVE", "DRIVING", "ENGINE_ON", "ENGINE_OFF"]
        #expect(result.usageMode == expected[raw - 1])
        #expect(result.unknownFields.isEmpty)
        #expect(result.availability != .available)
    }

    @Test(arguments: [0, 8, 999])
    func unknownUsageModeRetainsRawNumber(raw: Int) {
        let payload = Protobuf.intField(3, 1) + Protobuf.intField(5, raw)
        let result = PolestarGRPC.parseAvailabilityReport(Protobuf.messageField(3, payload))
        #expect(result.availability == .available)
        #expect(result.usageMode == nil)
        #expect(result.unknownFields.first?.value == String(raw))
    }

    @Test @MainActor func portalTotalsAndDiagnosticRowsKeepTripScopesSeparate() throws {
        let json = Data(#"{"vin":"TEST-VIN","totalEnergyConsumptionWh":12500,"totalEnergyConsumptionWhAutomatic":2500}"#.utf8)
        let dto = try JSONDecoder().decode(PolestarBatteryDTO.self, from: json)
        let energy = dto.toEnergySnapshot()
        #expect(energy.diagnostics?.energyUsedSinceChargeWh == nil)
        #expect(energy.diagnostics?.energyUsedManualTripWh == 12_500)
        #expect(energy.diagnostics?.energyUsedAutomaticTripWh == 2_500)
        let rows = InfoTabView.batteryDiagnosticRows(energy: energy, energyUnit: .kwhPer100Km)
        #expect(rows.contains { $0.key.contains(L10n.text("Trip Meter (TM)")) })
        #expect(rows.contains { $0.key.contains(L10n.text("Automatic Trip (AT)")) })
        #expect(!rows.contains { $0.key == L10n.text("Energy Since Charge") })
    }
}
