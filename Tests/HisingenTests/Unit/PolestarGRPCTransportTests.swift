import Foundation
import Testing
@testable import Hisingen

struct ProtobufDecodeTests {

    @Test func strictDecodeReadsEveryWireType() throws {
        let payload = Protobuf.intField(1, 42)
            + Protobuf.doubleField(2, 81.5)
            + Protobuf.stringField(3, "VIN")
            + Protobuf.floatField(4, 1.5)
        let fields = try Protobuf.decode(payload)
        #expect(fields.map(\.number) == [1, 2, 3, 4])
        #expect(fields.map(\.wire) == [0, 1, 2, 5])
        #expect(fields[0].varint == 42)
        #expect(String(decoding: fields[2].data, as: UTF8.self) == "VIN")
    }

    @Test func truncatedLengthDelimitedFieldThrows() {
        let full = Protobuf.intField(1, 7) + Protobuf.stringField(2, "complete")
        let cut = full.prefix(full.count - 3)
        #expect(throws: Protobuf.DecodeError.truncated(offset: 2)) { try Protobuf.decode(cut) }
        // The lenient path keeps what it read before the damage.
        #expect(Protobuf.fields(cut).map(\.number) == [1])
    }

    @Test func truncatedVarintThrows() {
        #expect(throws: Protobuf.DecodeError.truncated(offset: 0)) {
            try Protobuf.decode(Data([0x08, 0x80]))
        }
    }

    @Test func groupWireTypeThrows() {
        // Field 1, wire type 3 (start group).
        #expect(throws: Protobuf.DecodeError.unsupportedWireType(3, offset: 0)) {
            try Protobuf.decode(Data([0x0B]))
        }
    }

    @Test func fieldNumberZeroThrows() {
        #expect(throws: Protobuf.DecodeError.invalidFieldNumber(offset: 0)) {
            try Protobuf.decode(Data([0x00, 0x01]))
        }
    }

    @Test func decodesASliceWithANonZeroStartIndex() throws {
        let buffer = Data([0xFF, 0xFF]) + Protobuf.intField(5, 9)
        let slice = buffer.dropFirst(2)
        #expect(slice.startIndex == 2)
        let fields = try Protobuf.decode(slice)
        #expect(fields.count == 1)
        #expect(fields[0].number == 5)
        #expect(fields[0].varint == 9)
    }
}

struct ProtoMessageTests {

    @Test func accessorsCheckWireTypeAndTakeTheLastOccurrence() throws {
        let payload = Protobuf.intField(1, 3)
            + Protobuf.intField(1, 4)
            + Protobuf.stringField(2, "not a number")
        let message = try ProtoMessage(payload)
        #expect(message.uint(1) == 4)
        #expect(message.uint(2) == nil)
        #expect(message.bytes(2) != nil)
        #expect(message.double(1) == nil)
    }

    @Test func timestampReadsNestedSecondsAndIgnoresZero() throws {
        let stamped = try ProtoMessage(Protobuf.messageField(1, Protobuf.intField(1, 1_700_000_000)))
        #expect(try stamped.timestamp(1) == Date(timeIntervalSince1970: 1_700_000_000))
        let zero = try ProtoMessage(Protobuf.messageField(1, Protobuf.intField(1, 0)))
        #expect(try zero.timestamp(1) == nil)
    }
}

struct GRPCFrameReaderTests {

    private func frames(_ bytes: Data, context: String = "gRPC") throws -> [Data] {
        var reader = GRPCFrameReader(context: context)
        return try bytes.compactMap { try reader.consume($0) }
    }

    @Test func splitsConsecutiveFramesIncludingEmptyOnes() throws {
        let stream = Protobuf.grpcFrame(Data([1, 2, 3])) + Protobuf.grpcFrame(Data()) + Protobuf.grpcFrame(Data([9]))
        #expect(try frames(stream) == [Data([1, 2, 3]), Data(), Data([9])])
    }

    @Test func reportsAFrameStillBeingRead() throws {
        var reader = GRPCFrameReader(context: "gRPC")
        let partial = Protobuf.grpcFrame(Data([1, 2, 3])).prefix(6)
        for byte in partial { #expect(try reader.consume(byte) == nil) }
        #expect(reader.isReadingBody)
    }

    @Test func rejectsCompressedFrames() {
        do {
            _ = try frames(Data([1, 0, 0, 0, 1, 0xAA]), context: "gRPC command")
            Issue.record("a compressed frame was accepted")
        } catch PolestarError.incompatibleAPI(let operation) {
            #expect(operation == "compressed gRPC command frame")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func rejectsOversizedFrames() {
        let size = UInt32(GRPCFrameReader.maxFrameBytes + 1).bigEndian
        var header = Data([0])
        withUnsafeBytes(of: size) { header.append(contentsOf: $0) }
        do {
            _ = try frames(header, context: "live gRPC")
            Issue.record("an oversized frame was accepted")
        } catch PolestarError.invalidResponse(let operation) {
            #expect(operation == "oversized live gRPC frame")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

struct PolestarGRPCRequestTests {

    @Test func requestCarriesTheGRPCHeadersAndAFramedBody() {
        let message = Protobuf.stringField(2, "VIN123")
        let request = PolestarGRPC.grpcRequest(
            base: URL(string: "https://c3.example.com:443")!,
            path: "/services.vehiclestates.battery.BatteryService/GetLatestBattery",
            message: message, vin: "VIN123", accessToken: "token")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/services.vehiclestates.battery.BatteryService/GetLatestBattery")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/grpc")
        #expect(request.value(forHTTPHeaderField: "TE") == "trailers")
        #expect(request.value(forHTTPHeaderField: "grpc-accept-encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "vin") == "VIN123")
        #expect(request.httpBody == Protobuf.grpcFrame(message))
    }
}

struct C3DiscoveryParsingTests {

    private func url(_ json: String) -> URL? {
        PolestarGRPC.c3URL(fromDiscovery: Data(json.utf8))
    }

    @Test func readsHostAndPort() {
        #expect(url(#"{"c3":{"grpcHost":"c3.example.volvocars.com","grpcPort":443}}"#)?.absoluteString
            == "https://c3.example.volvocars.com:443")
    }

    @Test func rejectsHostsThatAreNotBareDNSNames() {
        #expect(url(#"{"c3":{"grpcHost":"evil.com/path","grpcPort":443}}"#) == nil)
        #expect(url(#"{"c3":{"grpcHost":"user@evil.com","grpcPort":443}}"#) == nil)
        #expect(url(#"{"c3":{"grpcHost":"","grpcPort":443}}"#) == nil)
    }

    @Test func rejectsPortsOutOfRangeAndMissingFields() {
        #expect(url(#"{"c3":{"grpcHost":"c3.example.com","grpcPort":0}}"#) == nil)
        #expect(url(#"{"c3":{"grpcHost":"c3.example.com","grpcPort":70000}}"#) == nil)
        #expect(url(#"{"c3":{"grpcHost":"c3.example.com"}}"#) == nil)
        #expect(url("not json") == nil)
    }
}

struct PolestarMalformedReplyTests {

    private let malformed = Data([0x1A, 0x10, 0x08])  // field 3 claims 16 bytes, carries 1

    @Test func malformedBatteryThrowsInsteadOfReturningAPartialState() {
        let truncated = Protobuf.intField(6, 1) + Data([0x10])
        #expect(throws: Protobuf.DecodeError.self) { try PolestarGRPC.parseBattery(truncated) }
    }

    @Test func batteryEnumsDecodeThroughTheirTables() throws {
        let battery = try PolestarGRPC.parseBattery(
            Protobuf.intField(6, 1) + Protobuf.intField(17, 3) + Protobuf.intField(26, 4)
                + Protobuf.intField(7, 99))
        #expect(battery.chargerConnection == .connected)
        #expect(battery.chargingType == .dc)
        #expect(battery.diagnostics.chargerPowerState == .providingPower)
        #expect(battery.chargingState == ChargingState(apiValue: "99"))
    }

    @Test func malformedAvailabilityReadsAsUnknown() {
        #expect(PolestarGRPC.parseAvailabilityReport(malformed).availability == .unknown)
    }

    @Test func availabilityWithoutATimestampStillDecodes() {
        let body = Protobuf.messageField(3, Protobuf.intField(3, 1))
        let report = PolestarGRPC.parseAvailabilityReport(body)
        #expect(report.availability == .available)
        #expect(report.reportedAt == nil)
    }

    @Test func malformedChronosReadsAreUnknown() {
        #expect(PolestarGRPC.parseTargetSoc(malformed) == nil)
        #expect(PolestarGRPC.fetchAmpLimitResponse(malformed) == nil)
        #expect(PolestarGRPC.parseTargetSoc(Protobuf.messageField(3, Protobuf.intField(1, 80))) == 80)
    }
}

struct ResumePathValidationTests {

    @Test func skipsAnUnrelatedURLBeforeTheResumePath() {
        let html = #"<script>cfg = { url: "/static/app.js" }; form = { action: "/as/q1/resume/as/authorization.ping" };</script>"#
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/q1/resume/as/authorization.ping")
    }

    @Test func rejectsProtocolRelativeTraversalAndNonResumePaths() {
        #expect(!PolestarAPI.isPlausibleResumePath("//evil.example/as/x/resume"))
        #expect(!PolestarAPI.isPlausibleResumePath("/as/../resume"))
        #expect(!PolestarAPI.isPlausibleResumePath("/as/authorization.oauth2"))
        #expect(!PolestarAPI.isPlausibleResumePath("/as/x/resume\" onload=\"x"))
        #expect(PolestarAPI.isPlausibleResumePath("/idp/abc/resume"))
    }
}

struct CarImageSelectionTests {

    private let transparent = [CarImageDTO(url: "https://cdn.example/0.png", angle: 0),
                               CarImageDTO(url: "https://cdn.example/1.png", angle: 1),
                               CarImageDTO(url: "https://cdn.example/3.png", angle: 3)]

    @Test func prefersTransparentRendersAndTheRequestedAngle() {
        let images = CarImagesDTO(transparent: transparent, opaque: [CarImageDTO(url: "https://cdn.example/o.png", angle: 3)])
        #expect(CarImagesDTO.preferred(in: images.pool, angle: 3)?.url == "https://cdn.example/3.png")
    }

    @Test func fallsBackToFrontThreeQuarterThenSide() {
        #expect(CarImagesDTO.preferred(in: transparent, angle: 5)?.angle == 1)
        #expect(CarImagesDTO.preferred(in: [transparent[0]], angle: 5)?.angle == 0)
    }

    @Test func usesOpaqueWhenThereAreNoTransparentRenders() {
        let images = CarImagesDTO(transparent: [], opaque: [CarImageDTO(url: "https://cdn.example/o.png", angle: 2)])
        #expect(images.pool.map(\.angle) == [2])
    }

    @Test func onlyHTTPSURLsAreFetched() {
        #expect(CarImageDTO(url: "http://cdn.example/0.png", angle: 0).httpsURL == nil)
        #expect(CarImageDTO(url: "https://cdn.example/0.png", angle: 0).httpsURL != nil)
    }

    @Test func oneOddRenderDoesNotDropTheList() throws {
        let json = #"{"data":{"getCarImages":{"transparent":[{"url":"https://cdn.example/1.png","angle":"one"},{"url":"https://cdn.example/0.png","angle":0}]}}}"#
        let images = try JSONDecoder().decode(GraphQLResponse<CarImagesPayloadDTO>.self, from: Data(json.utf8))
            .data?.getCarImages
        #expect(images?.pool.count == 2)
        #expect(images?.pool.first?.angle == nil)
    }
}
