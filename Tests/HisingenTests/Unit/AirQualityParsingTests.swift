import Foundation
import Testing
@testable import Hisingen

struct AirQualityParsingTests {

    /// Builds a C3 `PreCleaningInfo` payload with every documented field populated.
    private func fullPayload() -> Data {
        var payload = Data()
        payload.append(Protobuf.messageField(1, Protobuf.intField(1, 1_700_000_000)))
        payload.append(Protobuf.messageField(4, Protobuf.intField(1, 1_700_000_100)))
        payload.append(Protobuf.messageField(5, Protobuf.intField(1, 1_700_001_900)))
        payload.append(Protobuf.intField(6, 1))   // running_status = ON
        payload.append(Protobuf.intField(7, 1))   // start_reason = REMOTE
        payload.append(Protobuf.intField(8, 1))   // last_cycle_valid = true
        payload.append(Protobuf.intField(9, 12))  // AQI
        payload.append(Protobuf.intField(10, 3))  // cabin PM2.5
        payload.append(Protobuf.intField(11, 17)) // runtime left (min)
        payload.append(Protobuf.intField(13, 0))  // error = none
        payload.append(Protobuf.intField(14, 8))  // cabin PM10
        payload.append(Protobuf.intField(15, 21)) // outdoor PM2.5
        payload.append(Protobuf.intField(16, 74)) // filter remaining %
        return payload
    }

    @Test
    func testFullPreCleaningPayloadDecodesEveryField() throws {
        let air = try #require(PolestarGRPC.parseAirQuality(fullPayload()))
        #expect(air.cleaningState == .on)
        #expect(air.airQualityIndex == 12)
        #expect(air.particulateMatter25 == 3)
        #expect(air.particulateMatter10 == 8)
        #expect(air.externalParticulateMatter25 == 21)
        #expect(air.filterRemainingPercent == 74)
        #expect(air.runtimeRemainingMinutes == 17)
        #expect(!(air.hasError))
        // Explicit `AirCleaningError.none`, not the bare `.none` shorthand – on an Optional
        // that shorthand resolves to `Optional.none` (nil), which would make this pass even if
        // `errorKind` came back unset instead of the wire value 0 ("no error") it's testing for.
        #expect(air.errorKind == AirCleaningError.none)
        #expect(air.startReason == .remote)
        #expect(air.lastCycleValid == true)
        #expect(air.reportedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(air.startedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(air.endingAt == Date(timeIntervalSince1970: 1_700_001_900))
    }

    @Test
    func testErrorEnumDistinguishesGenericFromInterrupted() {
        func payload(error: Int) -> Data {
            var data = Data()
            data.append(Protobuf.intField(6, 2))
            data.append(Protobuf.intField(13, error))
            return data
        }
        let generic = PolestarGRPC.parseAirQuality(payload(error: 1))
        #expect(generic?.errorKind == .generic)
        #expect(generic?.hasError == true)

        let interrupted = PolestarGRPC.parseAirQuality(payload(error: 2))
        #expect(interrupted?.errorKind == .interrupted)
        // An interrupted cycle is not a hardware fault.
        #expect(interrupted?.hasError == true)

        let none = PolestarGRPC.parseAirQuality(payload(error: 0))
        #expect(none?.errorKind == AirCleaningError.none)
        #expect(none?.hasError == false)
    }

    @Test
    func testEmptyPayloadReturnsNil() {
        #expect(PolestarGRPC.parseAirQuality(Data()) == nil)
    }

    @Test
    func testUnknownEnumValuesFallBackSafely() {
        var payload = Data()
        payload.append(Protobuf.intField(6, 99))   // unmapped running status
        payload.append(Protobuf.intField(7, 42))   // unmapped start reason
        payload.append(Protobuf.intField(9, 30))
        let air = PolestarGRPC.parseAirQuality(payload)
        #expect(air != nil)
        #expect(air?.cleaningState == .unknown)
        #expect(air?.startReason == nil)
        #expect(air?.airQualityIndex == 30)
    }

    @Test
    func testLegacyCachedSnapshotStillDecodes() throws {
        // JSON written by versions before the extended fields existed must keep decoding.
        let legacyJSON = """
        {"cleaningState":"on","airQualityIndex":14,"particulateMatter25":4,
         "particulateMatter10":9,"externalParticulateMatter25":18,
         "filterRemainingPercent":66,"runtimeRemainingMinutes":9,"hasError":false}
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let air = try JSONDecoder().decode(VehicleAirQuality.self, from: data)
        #expect(air.cleaningState == .on)
        #expect(air.airQualityIndex == 14)
        #expect(air.reportedAt == nil)
        #expect(air.startReason == nil)
        #expect(air.errorKind == nil)
        #expect(!(air.hasError))
    }

    @Test
    func testRoundTripKeepsExtendedFields() throws {
        let original = VehicleAirQuality(
            cleaningState: .pending,
            airQualityIndex: 22,
            particulateMatter25: 6,
            particulateMatter10: 11,
            externalParticulateMatter25: 33,
            filterRemainingPercent: 41,
            runtimeRemainingMinutes: 5,
            reportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_050),
            endingAt: Date(timeIntervalSince1970: 1_700_001_650),
            startReason: .manuallyFromCar,
            lastCycleValid: false,
            errorKind: .interrupted
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleAirQuality.self, from: data)
        #expect(decoded == original)
    }
}
