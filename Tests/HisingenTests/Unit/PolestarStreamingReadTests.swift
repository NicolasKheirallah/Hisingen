import Foundation
import Testing
@testable import Hisingen

/// Chronos and OTA reads answer and then hold the stream open until the client deadline, the
/// same shape `PolestarCommandDeadlineTests` covers for commands. Logged on 2.0.12: GetTargetSoc,
/// GetAmpLimit and GetSoftwareInfo each received a reply and still failed with status 4 on every
/// call, and GetTimers was rejected outright because its packed weekday list was validated as a
/// nested message.
struct PolestarStreamingReadTests {
    private static let vin = "LPSVSEDEKML000001"

    private static func grpc(_ parts: [PolestarGRPCResponsePart]) -> (PolestarGRPC, String) {
        let suite = "HisingenPolestarStreamingRead.\(UUID().uuidString)"
        let grpc = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: APIDiagnosticLogStore(),
                                transport: ReplyThenDeadlineTransport(parts: parts))
        return (grpc, suite)
    }

    private static func replyThenDeadline(_ body: Data) -> [PolestarGRPCResponsePart] {
        [.headers(.init(httpStatus: 200, metadata: [:])), .message(body),
         .status(.init(code: PolestarGRPC.deadlineExceededStatus, message: "deadline exceeded", metadata: [:]))]
    }

    private static func timer(weekdays: [Int]) -> Data {
        var timer = Protobuf.stringField(1, "t1")
        timer += Protobuf.intField(2, 0)
        timer += Protobuf.messageField(3, Protobuf.intField(1, 7) + Protobuf.intField(2, 30))
        timer += Protobuf.intField(4, 1)
        timer += Protobuf.packedIntField(6, weekdays)
        return Protobuf.messageField(3, timer)
    }

    @Test
    func timerReplyWithPackedWeekdaysPassesValidation() throws {
        let body = Self.timer(weekdays: [1, 3, 5])
        try PolestarGRPC.validateResponse(body, path: "/pccs.chronos.services.v1.ParkingClimateTimerService/GetTimers")
        let timers = PolestarGRPC.parseClimateTimers(body)
        #expect(timers.first?.weekdays == [.monday, .wednesday, .friday])
    }

    @Test
    func climateTimersSurviveAStreamThatStaysOpen() async throws {
        let (grpc, suite) = Self.grpc(Self.replyThenDeadline(Self.timer(weekdays: [1, 2])))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let timers = try await grpc.fetchClimateTimers(vin: Self.vin, accessToken: "token")
        #expect(timers.count == 1)
        #expect(timers.first?.weekdays == [.monday, .tuesday])
    }

    @Test
    func targetSocReplyIsKeptWhenTheDeadlineFollowsIt() async throws {
        let (grpc, suite) = Self.grpc(Self.replyThenDeadline(Protobuf.messageField(3, Protobuf.intField(1, 80))))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let read = try await grpc.fetchTargetSoc(vin: Self.vin, accessToken: "token")
        #expect(read.value == 80)
    }

    @Test
    func deadlineWithoutAReplyStillFailsTheRead() async {
        let (grpc, suite) = Self.grpc([
            .headers(.init(httpStatus: 200, metadata: [:])),
            .status(.init(code: PolestarGRPC.deadlineExceededStatus, message: "deadline exceeded", metadata: [:]))
        ])
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await #expect(throws: (any Error).self) {
            _ = try await grpc.fetchTargetSoc(vin: Self.vin, accessToken: "token")
        }
    }
}

/// Plays a scripted exchange and stops as soon as the reader declines more parts, the way the
/// HTTP/2 transport does.
private struct ReplyThenDeadlineTransport: PolestarGRPCTransport {
    let supportsTrailers = true
    let parts: [PolestarGRPCResponsePart]

    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws {
        for part in parts {
            if try await !onPart(part) { return }
        }
    }
}
