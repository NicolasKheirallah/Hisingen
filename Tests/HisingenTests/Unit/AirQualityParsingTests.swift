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
        let air = try XCTUnwrap(PolestarGRPC.parseAirQuality(fullPayload()))
        XCTAssertEqual(air.cleaningState, .on)
        XCTAssertEqual(air.airQualityIndex, 12)
        XCTAssertEqual(air.particulateMatter25, 3)
        XCTAssertEqual(air.particulateMatter10, 8)
        XCTAssertEqual(air.externalParticulateMatter25, 21)
        XCTAssertEqual(air.filterRemainingPercent, 74)
        XCTAssertEqual(air.runtimeRemainingMinutes, 17)
        XCTAssertFalse(air.hasError)
        // Explicit `AirCleaningError.none`, not the bare `.none` shorthand — on an Optional
        // that shorthand resolves to `Optional.none` (nil), which would make this pass even if
        // `errorKind` came back unset instead of the wire value 0 ("no error") it's testing for.
        XCTAssertEqual(air.errorKind, AirCleaningError.none)
        XCTAssertEqual(air.startReason, .remote)
        XCTAssertEqual(air.lastCycleValid, true)
        XCTAssertEqual(air.reportedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(air.startedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(air.endingAt, Date(timeIntervalSince1970: 1_700_001_900))
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
        XCTAssertEqual(generic?.errorKind, .generic)
        XCTAssertEqual(generic?.hasError, true)

        let interrupted = PolestarGRPC.parseAirQuality(payload(error: 2))
        XCTAssertEqual(interrupted?.errorKind, .interrupted)
        // An interrupted cycle is not a hardware fault.
        XCTAssertEqual(interrupted?.hasError, true)

        let none = PolestarGRPC.parseAirQuality(payload(error: 0))
        XCTAssertEqual(none?.errorKind, AirCleaningError.none)
        XCTAssertEqual(none?.hasError, false)
    }

    @Test
    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(PolestarGRPC.parseAirQuality(Data()))
    }

    @Test
    func testUnknownEnumValuesFallBackSafely() {
        var payload = Data()
        payload.append(Protobuf.intField(6, 99))   // unmapped running status
        payload.append(Protobuf.intField(7, 42))   // unmapped start reason
        payload.append(Protobuf.intField(9, 30))
        let air = PolestarGRPC.parseAirQuality(payload)
        XCTAssertNotNil(air)
        XCTAssertEqual(air?.cleaningState, .unknown)
        XCTAssertEqual(air?.startReason, nil)
        XCTAssertEqual(air?.airQualityIndex, 30)
    }

    @Test
    func testLegacyCachedSnapshotStillDecodes() throws {
        // JSON written by versions before the extended fields existed must keep decoding.
        let legacyJSON = """
        {"cleaningState":"on","airQualityIndex":14,"particulateMatter25":4,
         "particulateMatter10":9,"externalParticulateMatter25":18,
         "filterRemainingPercent":66,"runtimeRemainingMinutes":9,"hasError":false}
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let air = try JSONDecoder().decode(VehicleAirQuality.self, from: data)
        XCTAssertEqual(air.cleaningState, .on)
        XCTAssertEqual(air.airQualityIndex, 14)
        XCTAssertNil(air.reportedAt)
        XCTAssertNil(air.startReason)
        XCTAssertNil(air.errorKind)
        XCTAssertFalse(air.hasError)
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
        XCTAssertEqual(decoded, original)
    }
}
