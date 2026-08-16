import Foundation
import Testing
@testable import Hisingen

struct RemoteCommandTests {
    @Test
    func testRemoteFeaturesAreDisabledByDefault() {
        XCTAssertTrue(FeatureSelection.default.enabled.intersection(AppFeature.remoteFeatures).isEmpty)
        XCTAssertEqual(RemoteCommand.unlock.feature, .remoteLocks)
        XCTAssertEqual(RemoteCommand.openWindows.risk, .securitySensitive)
        XCTAssertEqual(RemoteCommand.installOTANow.risk, .destructive)
    }

    @Test
    func testRemoteCommandRequiresContextAndAuthentication() async {
        do {
            _ = try await PolestarAPI().executeRemoteCommand(.lock, vin: "YSMTEST")
            XCTFail("Remote commands must require selected vehicle and authenticated session")
        } catch RemoteCommandError.missingContext {

        } catch PolestarError.authenticationRequired {

        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @Test
    func testClimateStartWireRequest() throws {
        let data = PolestarGRPC.climateStartRequest(
            vin: "TESTVIN", temperature: 21,
            frontLeft: .level2, frontRight: .level1,
            rearLeft: .off, rearRight: .level3, steeringWheel: .off
        )
        let fields = Protobuf.fields(data)
        let envelope = try XCTUnwrap(fields.first { $0.number == 1 && $0.wire == 2 })
        XCTAssertEqual(string(envelope.data, field: 1), "TESTVIN")
        XCTAssertEqual(fields.first { $0.number == 2 }?.varint, 1)
        XCTAssertEqual(float(fields.first { $0.number == 3 }?.data), 21)
        XCTAssertEqual(fields.first { $0.number == 4 }?.varint, UInt64(HeatingLevel.level1.rawValue))
        XCTAssertEqual(fields.first { $0.number == 5 }?.varint, UInt64(HeatingLevel.level2.rawValue))
        XCTAssertEqual(fields.first { $0.number == 6 }?.varint, UInt64(HeatingLevel.level3.rawValue))
        XCTAssertEqual(fields.first { $0.number == 7 }?.varint, UInt64(HeatingLevel.off.rawValue))
        XCTAssertEqual(fields.first { $0.number == 8 }?.varint, UInt64(HeatingLevel.off.rawValue))
    }

    @Test
    func testInvocationLifecycleStatuses() throws {
        let accepted = try PolestarGRPC.parseInvocationResult(invocation(status: 1))
        let delivered = try PolestarGRPC.parseInvocationResult(invocation(status: 4))
        let completed = try PolestarGRPC.parseInvocationResult(invocation(status: 6))
        XCTAssertEqual(accepted.outcome, .accepted)
        XCTAssertEqual(delivered.outcome, .delivered)
        XCTAssertEqual(completed.outcome, .completed)
        var flat = Data()
        flat.append(Protobuf.stringField(1, "request-id"))
        flat.append(Protobuf.intField(3, 6))
        let flatResult = try PolestarGRPC.parseInvocationResult(flat)
        XCTAssertEqual(flatResult.outcome, .completed)
        do {
            _ = try PolestarGRPC.parseInvocationResult(invocation(status: 9))
            XCTFail("Expected the privacy rejection")
        } catch {
            guard case RemoteCommandError.rejected(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertNotNil(message)
        }
    }

    @Test
    func testGlobalChargeScheduleWireRequest() throws {
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 22, startMinute: 30,
            endHour: 6, endMinute: 15, weekdays: [], isActive: true
        )
        let timer = try PolestarGRPC.globalChargeTimer(schedule)
        let fields = Protobuf.fields(timer)
        XCTAssertEqual(fields.first { $0.number == 3 }?.varint, 1)
        let start = try XCTUnwrap(fields.first { $0.number == 1 }?.data)
        let end = try XCTUnwrap(fields.first { $0.number == 2 }?.data)
        XCTAssertEqual(Protobuf.fields(start).first { $0.number == 1 }?.varint, 22)
        XCTAssertEqual(Protobuf.fields(start).first { $0.number == 2 }?.varint, 30)
        XCTAssertEqual(Protobuf.fields(end).first { $0.number == 1 }?.varint, 6)
        XCTAssertEqual(Protobuf.fields(end).first { $0.number == 2 }?.varint, 15)
    }

    @Test
    func testClimateTimerPreservesBackendIdentityAndWeekdays() throws {
        let schedule = VehicleSchedule(
            backendID: "timer-id", index: 2, kind: .climate,
            startHour: 7, startMinute: 45, endHour: nil, endMinute: nil,
            weekdays: [.monday, .wednesday, .friday], isActive: true
        )
        let timer = try PolestarGRPC.climateTimer(schedule)
        let fields = Protobuf.fields(timer)
        XCTAssertEqual(string(timer, field: 1), "timer-id")
        XCTAssertEqual(fields.first { $0.number == 2 }?.varint, 2)
        XCTAssertEqual(fields.first { $0.number == 4 }?.varint, 1)
        XCTAssertEqual(fields.first { $0.number == 5 }?.varint, 1)
        XCTAssertEqual(fields.first { $0.number == 6 }?.data, Data([1, 3, 5]))
    }

    @Test
    func testInvalidScheduleIsRejectedBeforeNetworkUse() {
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 30, startMinute: 0,
            endHour: 6, endMinute: 0, weekdays: [], isActive: true
        )
        do {
            _ = try PolestarGRPC.globalChargeTimer(schedule)
            XCTFail("Expected invalid schedule rejection")
        } catch {
            XCTAssertTrue(error is RemoteCommandError)
        }
    }

    @Test
    func testHonkHornCommandProperties() {
        let honk = RemoteCommand.honkHorn
        XCTAssertEqual(honk.feature, .remoteHonkFlash)
        XCTAssertEqual(honk.requiredCapability, .honkAndFlash)
        XCTAssertEqual(honk.risk, .routine)
        XCTAssertEqual(honk.identifier, "honk-horn")
        XCTAssertFalse(honk.title.isEmpty)
    }

    @Test
    func testHonkFlashWireRequests() {
        let honkAndFlash = PolestarGRPC.honkFlashRequest("VIN123", action: 0)
        let honkOnly = PolestarGRPC.honkFlashRequest("VIN123", action: 1)
        let flashOnly = PolestarGRPC.honkFlashRequest("VIN123", action: 2)

        let hfFields = Protobuf.fields(honkAndFlash)
        let hoFields = Protobuf.fields(honkOnly)
        let foFields = Protobuf.fields(flashOnly)

        XCTAssertEqual(hfFields.first { $0.number == 2 }?.varint, 0)
        XCTAssertEqual(hoFields.first { $0.number == 2 }?.varint, 1)
        XCTAssertEqual(foFields.first { $0.number == 2 }?.varint, 2)
    }

    private func invocation(status: Int) -> Data {
        var response = Data()
        response.append(Protobuf.intField(3, status))
        return Protobuf.messageField(1, response)
    }

    private func string(_ data: Data, field: Int) -> String? {
        guard let bytes = Protobuf.fields(data).first(where: { $0.number == field })?.data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private func float(_ data: Data?) -> Float? {
        guard let data, data.count == 4 else { return nil }
        let bits = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        return Float(bitPattern: bits)
    }
}


