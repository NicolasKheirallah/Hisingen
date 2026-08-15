import Foundation
import Testing
@testable import Hisingen

struct RequestConstructionTests {

    @Test
    func testLockAndUnlockRequests() throws {
        let lockData = PolestarGRPC.lockRequest("YSMTESTVIN0000001")
        let lockFields = Protobuf.fields(lockData)
        guard let lockEnvelope = lockFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(lockEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(lockFields.first { $0.number == 2 }?.varint, 0)

        let unlockData = PolestarGRPC.unlockRequest("YSMTESTVIN0000001", trunkOnly: false)
        let unlockFields = Protobuf.fields(unlockData)
        guard let unlockEnvelope = unlockFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(unlockEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(unlockFields.first { $0.number == 2 }?.varint, 0)

        let trunkData = PolestarGRPC.unlockRequest("YSMTESTVIN0000001", trunkOnly: true)
        let trunkFields = Protobuf.fields(trunkData)
        guard let trunkEnvelope = trunkFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(trunkEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(trunkFields.first { $0.number == 2 }?.varint, 1)
    }

    @Test
    func testWindowControlRequests() throws {
        let openData = PolestarGRPC.windowRequest("YSMTESTVIN0000001", action: 1)
        let openFields = Protobuf.fields(openData)
        guard let openEnvelope = openFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(openEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(openFields.first { $0.number == 2 }?.varint, 1)

        let closeData = PolestarGRPC.windowRequest("YSMTESTVIN0000001", action: 2)
        let closeFields = Protobuf.fields(closeData)
        guard let closeEnvelope = closeFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(closeEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(closeFields.first { $0.number == 2 }?.varint, 2)
    }

    @Test
    func testHonkAndFlashRequests() throws {
        let flashData = PolestarGRPC.honkFlashRequest("YSMTESTVIN0000001", action: 2)
        let flashFields = Protobuf.fields(flashData)
        guard let flashEnvelope = flashFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(flashEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(flashFields.first { $0.number == 2 }?.varint, 2)

        let honkData = PolestarGRPC.honkFlashRequest("YSMTESTVIN0000001", action: 0)
        let honkFields = Protobuf.fields(honkData)
        guard let honkEnvelope = honkFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(honkEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(honkFields.first { $0.number == 2 }?.varint, 0)
    }

    @Test
    func testPreCleaningRequests() throws {
        let start = PolestarGRPC.preCleaningRequest(vin: "YSMTESTVIN0000001", start: true)
        let startFields = Protobuf.fields(start)
        guard let startEnvelope = startFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(startEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(startFields.first { $0.number == 2 }?.varint, 1)

        let stop = PolestarGRPC.preCleaningRequest(vin: "YSMTESTVIN0000001", start: false)
        let stopFields = Protobuf.fields(stop)
        guard let stopEnvelope = stopFields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        XCTAssertEqual(string(stopEnvelope.data, field: 1), "YSMTESTVIN0000001")
        XCTAssertEqual(stopFields.first { $0.number == 2 }?.varint, 0)
    }

    @Test
    func testChronosRequestEnvelope() throws {
        var payload = Data()
        payload.append(Protobuf.intField(2, 90))
        let data = PolestarGRPC.chronosRequest("YSMTESTVIN0000001", payload: payload)
        let fields = Protobuf.fields(data)
        guard let envelope = fields.first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return XCTFail("Missing envelope field 1")
        }
        let envFields = Protobuf.fields(envelope.data)
        XCTAssertEqual(string(envelope.data, field: 2), "YSMTESTVIN0000001")
        XCTAssertEqual(envFields.first { $0.number == 3 }?.data, Data("RCS".utf8))
        XCTAssertEqual(fields.first { $0.number == 2 }?.varint, 90)
    }

    private func string(_ data: Data, field: Int) -> String? {
        guard let bytes = Protobuf.fields(data).first(where: { $0.number == field })?.data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

