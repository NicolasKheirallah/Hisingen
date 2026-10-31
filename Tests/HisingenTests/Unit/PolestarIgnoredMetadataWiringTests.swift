import Foundation
import Testing
@testable import Hisingen

/// Wiring for the sent-but-ignored metadata group from docs/api/polestar-unwired-fields.md:
/// the per-timer repeats-weekly flag readback, raw retention on the PCCS scalar reads, and
/// unknown-field retention on the air-quality payload.
struct PolestarIgnoredMetadataWiringTests {
    // MARK: Fixtures

    /// One climate-timer entry (response field 3) with the fields the writer sends:
    /// `1 id`, `2 index`, `3 time`, `4 active`, `5 repeats-weekly`, `6 packed weekdays`.
    private func timer(id: String,
                       active: Bool = true,
                       repeatsWeekly: Int? = nil,
                       weekdays: [Int] = []) -> Data {
        var timer = Protobuf.stringField(1, id)
        timer += Protobuf.intField(2, 0)
        timer += Protobuf.messageField(3, Protobuf.intField(1, 7) + Protobuf.intField(2, 30))
        timer += Protobuf.intField(4, active ? 1 : 0)
        if let repeatsWeekly { timer += Protobuf.intField(5, repeatsWeekly) }
        if !weekdays.isEmpty { timer += Protobuf.packedIntField(6, weekdays) }
        return Protobuf.messageField(3, timer)
    }

    /// A PCCS scalar-read body: the payload rides in envelope field 3.
    private func pccsBody(_ payload: Data) -> Data { Protobuf.messageField(3, payload) }

    // MARK: Timer field 5 readback

    @Test func timerDecodeReadsRepeatsWeeklyFlag() {
        let withFlag = PolestarGRPC.parseClimateTimers(timer(id: "t1", repeatsWeekly: 1))
        #expect(withFlag.first?.repeatsWeekly == true)

        let withZero = PolestarGRPC.parseClimateTimers(timer(id: "t1", repeatsWeekly: 0))
        #expect(withZero.first?.repeatsWeekly == false)

        let withoutFlag = PolestarGRPC.parseClimateTimers(timer(id: "t1"))
        #expect(withoutFlag.first?.repeatsWeekly == nil)
    }

    @Test func repeatsWeeklySurvivesWithEmptyWeekdays() throws {
        // The writer sends field 5 precisely so the readback carries the flag independently
        // of the weekday list; a one-shot timer must not lose it.
        let timers = PolestarGRPC.parseClimateTimers(timer(id: "t1", repeatsWeekly: 1, weekdays: []))
        let timer = try #require(timers.first)
        #expect(timer.repeatsWeekly == true)
        #expect(timer.weekdays.isEmpty)
        // The known fields decode alongside it.
        #expect(timer.startHour == 7)
        #expect(timer.startMinute == 30)
        #expect(timer.isActive)
    }

    @Test func repeatsWeeklyRoundTripsThroughCodable() throws {
        let original = VehicleSchedule(kind: .climate, startHour: 7, startMinute: 30,
                                       endHour: nil, endMinute: nil, isActive: true,
                                       repeatsWeekly: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleSchedule.self, from: data)
        #expect(decoded.repeatsWeekly == true)

        // A snapshot persisted before the flag existed decodes as nil.
        let legacy = try JSONDecoder().decode(VehicleSchedule.self, from: Data(
            #"{"kind":"climate","isActive":true}"#.utf8))
        #expect(legacy.repeatsWeekly == nil)
    }

    // MARK: PCCS scalar-read retention

    @Test func targetSocReadRetainsExtraPayloadFields() throws {
        let read = PolestarGRPC.parseTargetSocRead(pccsBody(Protobuf.intField(1, 80) + Protobuf.intField(3, 3)))
        #expect(read.value == 80)
        let raw = try #require(read.unknownFields.first)
        #expect(read.unknownFields.count == 1)
        #expect(raw.field == 3)
        #expect(raw.wire == 0)
        #expect(raw.value == "3")
        #expect(raw.isBinary == false)
    }

    @Test func ampLimitReadRetainsExtraPayloadFields() throws {
        let read = PolestarGRPC.parseAmpLimitRead(pccsBody(Protobuf.intField(1, 32) + Protobuf.intField(3, 3)))
        #expect(read.value == 32)
        #expect(read.unknownFields.map(\.field) == [3])
        #expect(read.unknownFields.map(\.value) == ["3"])
    }

    @Test func pccsReadsWithoutExtrasRetainNothing() {
        // Only field 1 on the wire: nothing retained, so the diagnostics rows disappear.
        #expect(PolestarGRPC.parseTargetSocRead(pccsBody(Protobuf.intField(1, 80))).unknownFields.isEmpty)
        #expect(PolestarGRPC.parseAmpLimitRead(pccsBody(Protobuf.intField(1, 32))).unknownFields.isEmpty)
        // A malformed payload retains nothing either: no partial frame shown as data.
        #expect(PolestarGRPC.parseTargetSocRead(Data([0xFF])).value == nil)
        #expect(PolestarGRPC.parseTargetSocRead(Data([0xFF])).unknownFields.isEmpty)
        #expect(PolestarGRPC.parseAmpLimitRead(Data([0xFF])).value == nil)
        #expect(PolestarGRPC.parseAmpLimitRead(Data([0xFF])).unknownFields.isEmpty)
    }

    // MARK: Air-quality unknown-field retention

    @Test func airQualityRetainsUnknownFieldNumbers() throws {
        let payload = Protobuf.intField(6, 2)          // running status: off
            + Protobuf.intField(9, 42)                 // air-quality index
            + Protobuf.intField(3, 123)                // known duplicate of field 1: not raw
            + Protobuf.intField(17, 7)                 // not decoded by this build
        let air = try #require(PolestarGRPC.parseAirQuality(payload))
        #expect(air.cleaningState == .off)
        #expect(air.airQualityIndex == 42)
        let raw = try #require(air.unknownWireFields)
        #expect(raw.map(\.field) == [17])
        #expect(raw.map(\.value) == ["7"])
    }

    @Test func airQualityWithoutUnknownsRetainsNothing() throws {
        let air = try #require(PolestarGRPC.parseAirQuality(Protobuf.intField(6, 1) + Protobuf.intField(10, 9)))
        #expect(air.unknownWireFields == nil)
        #expect(air.particulateMatter25 == 9)
    }

    @Test func airQualityUnknownWireFieldsRoundTripThroughCodable() throws {
        let air = VehicleAirQuality(cleaningState: .off,
                                    unknownWireFields: [VehicleRawWireField(field: 17, wire: 0,
                                                                            value: "7", isBinary: false)])
        let data = try JSONEncoder().encode(air)
        let decoded = try JSONDecoder().decode(VehicleAirQuality.self, from: data)
        #expect(decoded.unknownWireFields == air.unknownWireFields)

        // A snapshot persisted before retention existed decodes as nil.
        let legacy = try JSONDecoder().decode(VehicleAirQuality.self, from: Data(
            #"{"cleaningState":"off"}"#.utf8))
        #expect(legacy.unknownWireFields == nil)
    }

    // MARK: Reader surfaces

    @Test @MainActor func pccsReadRowsRenderOnlyWhenRetained() {
        var empty = EnergyAndChargingSnapshot()
        #expect(InfoTabView.pccsReadRows(energy: empty).isEmpty)

        empty.targetSocUnknownFields = [VehicleRawWireField(field: 3, wire: 0, value: "3", isBinary: false)]
        empty.ampLimitUnknownFields = [VehicleRawWireField(field: 4, wire: 0, value: "2", isBinary: true)]
        let rows = InfoTabView.pccsReadRows(energy: empty)
        #expect(rows.count == 2)
        #expect(rows.map(\.key) == [L10n.format("Field %d", 3), L10n.format("Field %d (raw)", 4)])
        #expect(rows.map(\.value) == ["3", "2"])
        #expect(rows[0].info == L10n.text("Field the charge-target read returned beyond the decoded value. Write probes proved this service carries a payload status enum; shown raw so new backend data is visible and reported unchanged in support exports."))
        #expect(rows[1].info == L10n.text("Field the current-limit read returned beyond the decoded value. Write probes proved this service carries a payload status enum; shown raw so new backend data is visible and reported unchanged in support exports."))

        // The rows ride the same diagnostics surface the battery raw fields use.
        var energy = EnergyAndChargingSnapshot()
        energy.diagnostics = BatteryDiagnostics(timeToTargetMinutes: nil, timeToMinimumSOCMinutes: nil,
                                                chargerPowerState: .unknown, averageConsumption: nil,
                                                averageConsumptionSinceCharge: nil,
                                                energyUsedSinceChargeWh: nil)
        #expect(InfoTabView.batteryDiagnosticRows(energy: energy, energyUnit: .kwhPer100Km).isEmpty)
        energy.targetSocUnknownFields = [VehicleRawWireField(field: 3, wire: 0, value: "3", isBinary: false)]
        let withRaw = InfoTabView.batteryDiagnosticRows(energy: energy, energyUnit: .kwhPer100Km)
        #expect(withRaw.map(\.key) == [L10n.format("Field %d", 3)])
    }
}
