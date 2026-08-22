import Foundation
import Testing
@testable import Hisingen

/// Wire-level coverage for Polestar Chronos `ChargeLocationService` support: read parsing,
/// per-location write request shapes, and status decoding.
struct ChargeLocationTests {

    private func locationPayload() -> Data {
        var coordinate = Data()
        coordinate.append(Protobuf.doubleField(1, 11.97))
        coordinate.append(Protobuf.doubleField(2, 57.71))

        var location = Data()
        location.append(Protobuf.stringField(2, "loc-123"))
        location.append(Protobuf.stringField(3, "Home"))
        location.append(Protobuf.messageField(4, coordinate))
        location.append(Protobuf.intField(5, 16))   // amp limit
        location.append(Protobuf.intField(6, 40))   // minimum SOC
        location.append(Protobuf.intField(7, 1))    // optimised charging on
        location.append(Protobuf.intField(12, 2))   // kind = saved
        return location
    }

    @Test("GetChargeLocations payload decodes every documented field")
    func parseDecodesAllFields() throws {
        var body = Data()
        body.append(Protobuf.messageField(3, locationPayload()))
        let locations = PolestarGRPC.parseChargeLocations(body)
        #expect(locations.count == 1)
        let loc = try #require(locations.first)
        #expect(loc.id == "loc-123")
        #expect(loc.alias == "Home")
        #expect(abs((loc.longitude ?? 0) - 11.97) < 0.0001)
        #expect(abs((loc.latitude ?? 0) - 57.71) < 0.0001)
        #expect(loc.ampLimit == 16)
        #expect(loc.minimumSoc == 40)
        #expect(loc.optimisedChargingEnabled)
        #expect(loc.kind == 2)
        #expect(loc.isSavedLocation)
    }

    @Test("Entries without an identifier are skipped")
    func parseSkipsEntriesWithoutID() {
        var body = Data()
        var anonymous = Data()
        anonymous.append(Protobuf.stringField(3, "No ID"))
        body.append(Protobuf.messageField(3, anonymous))
        #expect(PolestarGRPC.parseChargeLocations(body).isEmpty)
    }

    @Test("Per-location write requests carry location ID then value on fields 2 and 3")
    func updateRequestShape() throws {
        var request = Data()
        request.append(Protobuf.stringField(2, "loc-123"))
        request.append(Protobuf.intField(3, 12))
        let fields = Protobuf.fields(request)
        #expect(fields.first { $0.number == 2 }?.data == Data("loc-123".utf8))
        #expect(fields.first { $0.number == 3 }?.varint == 12)
    }

    @Test("Chronos status on field 1 maps to command outcomes")
    func chronosStatusOnFieldOneMapsToOutcomes() throws {
        var accepted = Data()
        accepted.append(Protobuf.intField(1, 1))
        #expect(try PolestarGRPC.chronosResult(accepted, statusField: 1).outcome == .accepted)

        var delivered = Data()
        delivered.append(Protobuf.intField(1, 2))
        #expect(try PolestarGRPC.chronosResult(delivered, statusField: 1).outcome == .delivered)

        var rejected = Data()
        rejected.append(Protobuf.intField(1, 0))
        #expect(throws: RemoteCommandError.self) {
            _ = try PolestarGRPC.chronosResult(rejected, statusField: 1)
        }
    }

    @Test("Create/update validation rejects bad input locally before any network dispatch")
    func localValidationRejectsBadInput() async throws {
        let grpc = PolestarGRPC()
        let commands: [RemoteCommand] = [
            .createChargeLocationAtCar(alias: "   ", ampLimit: 0, minimumSoc: 0, optimisedCharging: false),
            .createChargeLocationAtCar(alias: "Home", ampLimit: 99, minimumSoc: 0, optimisedCharging: false),
            .updateChargeLocationMinimumSoc(id: "loc-123", soc: 140),
            .deleteChargeLocation(id: ""),
        ]
        for command in commands {
            await #expect(throws: RemoteCommandError.self) {
                try await grpc.executeRemoteCommand(command, vin: "VIN", accessToken: "t")
            }
        }
    }
}
