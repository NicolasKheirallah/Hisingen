import Foundation
import Testing
@testable import Hisingen

/// Wire-level coverage for the request builders and result decoders in `PolestarGRPCRemote`
/// that the existing remote-command suites do not already pin: the lock, tailgate, window, honk,
/// pre-cleaning and charging-timer layouts, the Chronos envelope, and the status tables for
/// invocation and Chronos responses. Everything here is pure encoding or decoding; no transport.
struct PolestarGRPCRemoteTests {
    private let vin = "YSMREMOTE0000001"

    /// Every invocation builder wraps `InvocationRequest { vin }` in field 1, so the VIN sits at
    /// `1 -> 1` of the request.
    private func invocationVIN(_ data: Data) -> String? {
        guard let envelope = Protobuf.fields(data).first(where: { $0.number == 1 && $0.wire == 2 }) else {
            return nil
        }
        guard let vinField = Protobuf.fields(envelope.data).first(where: { $0.number == 1 }) else {
            return nil
        }
        return String(data: vinField.data, encoding: .utf8)
    }

    private func varintField(_ data: Data, _ number: Int) -> UInt64? {
        Protobuf.fields(data).first(where: { $0.number == number && $0.wire == 0 })?.varint
    }

    /// A flat InvocationResponse: status on field 3, message on field 4.
    private func invocation(status: Int, message: String?) -> Data {
        var data = Protobuf.intField(3, status)
        if let message { data.append(Protobuf.stringField(4, message)) }
        return data
    }

    // MARK: - Invocation request layouts

    @Test
    func lockAndUnlockRequestsCarryTheVINAndTheirModeFlag() {
        let lock = PolestarGRPC.lockRequest(vin)
        #expect(invocationVIN(lock) == vin)
        #expect(varintField(lock, 2) == 0)

        let unlock = PolestarGRPC.unlockRequest(vin)
        #expect(invocationVIN(unlock) == vin)
        #expect(varintField(unlock, 2) == 0, "A full unlock is mode 0")

        let trunk = PolestarGRPC.unlockRequest(vin, trunkOnly: true)
        #expect(varintField(trunk, 2) == 1, "A trunk-only unlock is mode 1")
    }

    @Test
    func tailgateMapsOpenAndCloseToTheProtoEnumValues() {
        // TailgateControlType: 1 = OPEN_TAILGATE, 2 = CLOSE_TAILGATE. Never 0 (UNSPECIFIED).
        let open = PolestarGRPC.tailgateRequest(vin, open: true)
        #expect(invocationVIN(open) == vin)
        #expect(varintField(open, 2) == 1)

        let close = PolestarGRPC.tailgateRequest(vin, open: false)
        #expect(varintField(close, 2) == 2)
    }

    @Test
    func windowAndHonkRequestsPassTheActionThrough() {
        let window = PolestarGRPC.windowRequest(vin, action: 3)
        #expect(invocationVIN(window) == vin)
        #expect(varintField(window, 2) == 3)

        let honk = PolestarGRPC.honkFlashRequest(vin, action: 2)
        #expect(invocationVIN(honk) == vin)
        #expect(varintField(honk, 2) == 2)
    }

    @Test
    func preCleaningEncodesStartAsOneAndStopAsZero() {
        let start = PolestarGRPC.preCleaningRequest(vin: vin, start: true)
        #expect(invocationVIN(start) == vin)
        #expect(varintField(start, 2) == 1)

        let stop = PolestarGRPC.preCleaningRequest(vin: vin, start: false)
        #expect(varintField(stop, 2) == 0)
    }

    @Test
    func climateStartUsesTheComfortSetpointWhenTemperatureIsAutomatic() {
        // Temperature 0 means vehicle-managed; the wire still needs field 3, set to 22 °C.
        let automatic = PolestarGRPC.climateStartRequest(
            vin: vin, temperature: 0,
            frontLeft: .unspecified, frontRight: .unspecified,
            rearLeft: .unspecified, rearRight: .unspecified, steeringWheel: .unspecified
        )
        #expect(automatic.range(of: Protobuf.floatField(3, 22)) != nil)

        // An explicit setpoint is sent as given, and unspecified seats/wheel are omitted.
        let explicit = PolestarGRPC.climateStartRequest(
            vin: vin, temperature: 21,
            frontLeft: .unspecified, frontRight: .unspecified,
            rearLeft: .unspecified, rearRight: .unspecified, steeringWheel: .unspecified
        )
        #expect(explicit.range(of: Protobuf.floatField(3, 21)) != nil)
        #expect(Protobuf.fields(explicit).map(\.number).sorted() == [1, 2, 3])
    }

    // MARK: - Chronos envelope and time encoding

    /// The Chronos envelope lives in field 1; its fields are the request id (1), VIN (2), and
    /// the service name (3).
    private func chronosEnvelopeFields(_ request: Data) throws -> [Protobuf.Field] {
        let envelope = try #require(Protobuf.fields(request).first { $0.number == 1 && $0.wire == 2 }?.data)
        return Protobuf.fields(envelope)
    }

    @Test
    func chronosRequestWrapsTheVINInItsEnvelopeAndAppendsThePayload() throws {
        let request = PolestarGRPC.chronosRequest(vin, payload: Protobuf.intField(9, 7))

        let envelope = try chronosEnvelopeFields(request)
        #expect(envelope.first { $0.number == 2 }?.data == Data(vin.utf8))
        #expect(envelope.first { $0.number == 3 }?.data == Data("RCS".utf8))
        // The payload rides after the envelope, untouched.
        #expect(varintField(request, 9) == 7)
    }

    @Test
    func chronosRequestIdIsFreshForEachRequest() throws {
        let first = try chronosEnvelopeFields(PolestarGRPC.chronosRequest(vin))
        let second = try chronosEnvelopeFields(PolestarGRPC.chronosRequest(vin))
        let firstID = try #require(first.first { $0.number == 1 }?.data)
        let secondID = try #require(second.first { $0.number == 1 }?.data)
        #expect(firstID != secondID, "Each Chronos call needs its own request id")
    }

    @Test
    func dailyTimeCarriesTheLocalUTCOffsetInMinutes() {
        let time = PolestarGRPC.dailyTime(hour: 7, minute: 5)
        #expect(varintField(time, 1) == 7)
        #expect(varintField(time, 2) == 5)

        let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
        let zone = Protobuf.fields(time).first { $0.number == 3 }?.data ?? Data()
        #expect(varintField(zone, 1) == UInt64(bitPattern: Int64(offsetMinutes)))
    }

    @Test
    func climateTimerWithoutWeekdaysSendsNoWeekdayField() throws {
        let schedule = VehicleSchedule(
            kind: .climate, startHour: 6, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [], isActive: false
        )
        let timer = try PolestarGRPC.climateTimer(schedule)
        #expect(varintField(timer, 2) == 0, "A schedule without an index is written as index 0")
        #expect(varintField(timer, 4) == 0, "An inactive timer is written as inactive")
        #expect(varintField(timer, 5) == 0, "No weekdays means the timer is not repeating")
        #expect(Protobuf.fields(timer).contains { $0.number == 6 } == false)
    }

    @Test
    func globalChargeTimerRejectsAnOutOfRangeStartHourBeforeSending() {
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 25, startMinute: 0,
            endHour: 6, endMinute: 0, weekdays: [], isActive: true
        )
        #expect(throws: RemoteCommandError.self) {
            _ = try PolestarGRPC.globalChargeTimer(schedule)
        }
    }

    // MARK: - Result decoding

    @Test
    func invocationStatusesCarryTheirMessageIntoTheResult() throws {
        let queued = try PolestarGRPC.parseInvocationResult(invocation(status: 1, message: "queued"))
        #expect(queued.outcome == .accepted)
        #expect(queued.message == "queued")

        let silent = try PolestarGRPC.parseInvocationResult(invocation(status: 6, message: nil))
        #expect(silent.outcome == .completed)
        #expect(silent.message == nil)
    }

    @Test(arguments: [10, 12])
    func modeAndConflictStatusesRejectWithAReason(status: Int) {
        #expect(throws: RemoteCommandError.self) {
            _ = try PolestarGRPC.parseInvocationResult(invocation(status: status, message: nil))
        }
    }

    @Test
    func unknownInvocationStatusRejectsWithTheVehicleMessage() {
        do {
            _ = try PolestarGRPC.parseInvocationResult(invocation(status: 77, message: "No such command"))
            Issue.record("Expected an unknown status to be rejected")
        } catch RemoteCommandError.rejected(let message) {
            #expect(message == "No such command")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func chronosStatusTableMapsEachCodeToItsOutcome() throws {
        func chronos(_ status: Int) -> Data {
            Protobuf.intField(1, status)
        }

        #expect(try PolestarGRPC.chronosResult(chronos(2), statusField: 1).outcome == .delivered)
        for status in [3, 4, 8] {
            #expect(try PolestarGRPC.chronosResult(chronos(status), statusField: 1).outcome == .completed,
                    "Chronos status \(status) should complete")
        }
        for status in [0, 5, 6, 7, 99] {
            do {
                _ = try PolestarGRPC.chronosResult(chronos(status), statusField: 1)
                Issue.record("Chronos status \(status) should be rejected")
            } catch RemoteCommandError.rejected {
                // Expected: a refused status carries the vehicle's reason.
            } catch {
                Issue.record("Unexpected error for status \(status): \(error)")
            }
        }
    }
}
