import Foundation
import Testing
@testable import Hisingen

struct PolestarWireHardeningTests {
    @Test func rejectsOverflowingVarintsAtEveryPosition() {
        let overflow = Data(repeating: 0x80, count: 9) + Data([0x02])
        for payload in [overflow, Data([0x08]) + overflow, Data([0x0a]) + overflow] {
            #expect(throws: Protobuf.DecodeError.self) { try Protobuf.decode(payload) }
        }
    }

    @Test func rejectsIllegalFieldNumbers() {
        #expect(throws: Protobuf.DecodeError.self) { try Protobuf.decode(Data([0])) }
        let tag = Protobuf.varint(UInt64(536_870_912) << 3)
        #expect(throws: Protobuf.DecodeError.self) { try Protobuf.decode(tag + Data([0])) }
    }

    @Test func commandResultRejectsMalformedSuffix() {
        let valid = Protobuf.intField(3, 6)
        #expect(throws: PolestarError.self) {
            try PolestarGRPC.parseInvocationResult(valid + Data([0x80]))
        }
        #expect(throws: PolestarError.self) {
            try PolestarGRPC.chronosResult(Protobuf.intField(1, 3) + Data([0x80]), statusField: 1)
        }
    }
}

extension PolestarWireHardeningTests {
    @Test func vehicleEnvelopeRejectsWrongIdentityAndAllowsMissingIdentity() throws {
        let payload = Protobuf.intField(1, 50)
        let wrong = Protobuf.stringField(2, "VIN-B") + Protobuf.messageField(3, payload)
        #expect(throws: PolestarError.self) {
            try PolestarGRPC.responsePayload(wrong, expectedVIN: "VIN-A")
        }
        #expect(try PolestarGRPC.responsePayload(Protobuf.messageField(3, payload), expectedVIN: "VIN-A") == payload)
    }

    @Test func rejectsMalformedNestedCapabilityInsteadOfKeepingPartialState() {
        let charging = Protobuf.intField(1, 1) + Data([0x80])
        let car = Protobuf.stringField(1, "VIN-A") + Protobuf.messageField(35, charging)
        let body = Protobuf.messageField(1, Protobuf.messageField(1, car))
        #expect(throws: Protobuf.DecodeError.self) {
            try PolestarGRPC.validateResponse(body, path: "/car_information.CarInformation/GetMyCars")
        }
    }
}

extension PolestarWireHardeningTests {
    @Test func flatCommandResultAllowsRequestID() throws {
        let body = Protobuf.stringField(1, "request-id") + Protobuf.intField(3, 6)
        let result = try PolestarGRPC.parseInvocationResult(body)
        #expect(result.outcome == .completed)
    }
}

extension PolestarWireHardeningTests {
    @Test func trailingPartialHeaderRemainsIncompleteAfterACompleteFrame() throws {
        for count in 1...4 {
            var reader = GRPCFrameReader(context: "command")
            let complete = Protobuf.grpcFrame(Protobuf.intField(3, 6))
            for byte in complete { _ = try reader.consume(byte) }
            #expect(!reader.isReadingBody)
            for byte in Protobuf.grpcFrame(Data([1])).prefix(count) { _ = try reader.consume(byte) }
            #expect(reader.isReadingBody)
        }
    }
}

extension PolestarWireHardeningTests {
    @Test func timeoutPreservesTrailingPartialHeader() async throws {
        let bytes = Protobuf.grpcFrame(Protobuf.intField(3, 6)) + Data([0, 0])
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish(throwing: URLError(.timedOut))
        }
        var reader = GRPCFrameReader(context: "command")
        var frames = 0
        do {
            try await reader.readMessages(from: stream) { _ in frames += 1; return true }
            Issue.record("Expected timeout")
        } catch is URLError {}
        #expect(frames == 1)
        #expect(reader.isReadingBody)
    }
}
