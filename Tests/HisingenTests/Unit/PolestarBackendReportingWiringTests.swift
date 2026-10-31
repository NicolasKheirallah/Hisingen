import Foundation
import Testing
@testable import Hisingen

/// Wiring tests for the Backend Reporting group: the report-support booleans (Car 20, 22,
/// 26, 29, 53 and Charging 35.5, 35.7, 35.27), the notification-kind message (Car 51) and
/// the packed end-ownership enum (Car 55). The retained capture pins the real values; the
/// synthetic frames pin the presence semantics proto3 forces (absent stays unknown).
struct PolestarBackendReportingWiringTests {
    private func capture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "polestar-c3-undecoded-" + name,
                                                 withExtension: "protobuf"))
        return try Data(contentsOf: url)
    }

    /// Builds a `GetMyCars` response whose Car message carries one synthetic block.
    private func myCars(car: Data, vin: String) -> VehicleOTACapabilities? {
        PolestarGRPC.parseMyCars(
            Protobuf.messageField(1, Protobuf.messageField(1,
                Protobuf.stringField(1, vin) + car)), vin: vin)
    }

    private static let reportingTags: Set<String> = [
        "20", "22", "26", "29", "51", "53", "55", "35.5", "35.7", "35.27"
    ]

    @Test func retainedCaptureDecodesBackendReportingFields() throws {
        let result = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        let equipment = try #require(result.equipment)
        #expect(equipment.reportsAvgElectricConsumption == true)
        #expect(equipment.reportsAvgSpeed == true)
        #expect(equipment.reportsAvgSpeedLastTrip == true)
        #expect(equipment.supportsDrivingJournal == true)
        #expect(equipment.supportsStolenVehicleTracking == true)
        #expect(equipment.reportsChargeLevelWhileCharging == true)
        #expect(equipment.reportsElectricRange == true)
        #expect(equipment.supportsChargeLocationsDepartureTimeMinChargeLevelSetting == true)
        // Car 51 lists its five named kinds in subfield order.
        #expect(equipment.reportedNotificationKinds == ["Unlocked Reminder", "Charging Completed",
                                                        "Charging Interrupted", "Climate Interrupted", "Theft"])
        // Car 55 keeps the frame's packed order.
        #expect(equipment.reportedEndOwnershipActions == ["Remove App Access", "Revoke Internet Agreement",
                                                          "Remote Factory Reset", "Revokes Digital Keys"])
        let rows = equipment.reportingDetails
        #expect(rows.contains { $0.title == "Backend Notifications" })
        #expect(rows.contains { $0.title == "End of Ownership Actions" })
        #expect(rows.contains { $0.title == "Charge Level While Charging" && $0.value == "Reported supported" })
    }

    @Test func wiredReportingTagsLeaveTheRawRetainedSet() throws {
        let result = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        let raw = try #require(result.unknownWireFields)
        let actual = Set(raw.map { item in
            item.subfield.map { "\($0).\(item.field)" } ?? String(item.field)
        })
        #expect(actual.isDisjoint(with: Self.reportingTags))
    }

    @Test func absentReportingFieldsStayUnknownInsteadOfFalse() throws {
        // One positive control, no other reporting tags: everything absent stays nil so the
        // UI hides the row instead of reading proto3 omission as "no".
        let car = Protobuf.stringField(1, "VIN-ABSENT") + Protobuf.intField(20, 1)
        let caps = try #require(myCars(car: car, vin: "VIN-ABSENT"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.reportsAvgElectricConsumption == true)
        #expect(equipment.reportsAvgSpeed == nil)
        #expect(equipment.reportsAvgSpeedLastTrip == nil)
        #expect(equipment.supportsDrivingJournal == nil)
        #expect(equipment.supportsStolenVehicleTracking == nil)
        #expect(equipment.reportsChargeLevelWhileCharging == nil)
        #expect(equipment.reportsElectricRange == nil)
        #expect(equipment.supportsChargeLocationsDepartureTimeMinChargeLevelSetting == nil)
        #expect(equipment.reportedNotificationKinds == nil)
        #expect(equipment.reportedEndOwnershipActions == nil)
        // The positive control is the only row; the absent fields stay hidden.
        #expect(equipment.reportingDetails.map(\.title) == ["Avg Electric Consumption Reporting"])

        // An explicitly sent false is a reported answer, not an absent one.
        let explicit = try #require(myCars(car: Protobuf.stringField(1, "VIN-EXPLICIT")
            + Protobuf.intField(26, 0), vin: "VIN-EXPLICIT"))
        #expect(explicit.equipment?.supportsDrivingJournal == false)
        #expect(explicit.equipment?.reportingDetails.count == 1)
    }

    @Test func notificationKindsListOnlyNamedTrueSubfields() throws {
        var notification = Data()
        notification += Protobuf.intField(1, 1)
        notification += Protobuf.intField(2, 1)      // no verified name: stays out of the list
        notification += Protobuf.intField(9, 1)
        let car = Protobuf.stringField(1, "VIN-NOTE") + Protobuf.messageField(51, notification)
        let caps = try #require(myCars(car: car, vin: "VIN-NOTE"))
        #expect(caps.equipment?.reportedNotificationKinds == ["Unlocked Reminder", "Theft"])

        // A named subfield sent false does not become a kind either.
        var offNotification = Data()
        offNotification += Protobuf.intField(1, 0)
        let off = try #require(myCars(car: Protobuf.stringField(1, "VIN-NOTE-OFF")
            + Protobuf.messageField(51, offNotification), vin: "VIN-NOTE-OFF"))
        #expect(off.equipment?.reportedNotificationKinds == nil)
    }

    @Test func endOwnershipActionsDecodeFromBothEncodings() throws {
        // Packed (wire 2), the shape the retained frame carries.
        let packed = try #require(myCars(car: Protobuf.stringField(1, "VIN-ACTIONS-P")
            + Protobuf.packedIntField(55, [1, 3, 2, 6]), vin: "VIN-ACTIONS-P"))
        let packedActions = try #require(packed.equipment?.reportedEndOwnershipActions)
        #expect(packedActions == ["Remove App Access", "Revoke Internet Agreement",
                                  "Remote Factory Reset", "Revokes Digital Keys"])

        // Unpacked (wire 0), the encoding a short list may legally use; order still kept.
        var car = Protobuf.stringField(1, "VIN-ACTIONS-U")
        car += Protobuf.intField(55, 1)
        car += Protobuf.intField(55, 3)
        car += Protobuf.intField(55, 2)
        car += Protobuf.intField(55, 6)
        let unpacked = try #require(myCars(car: car, vin: "VIN-ACTIONS-U"))
        #expect(unpacked.equipment?.reportedEndOwnershipActions == packedActions)

        // A value with no verified name stays out of the list.
        let unknownValue = try #require(myCars(car: Protobuf.stringField(1, "VIN-ACTIONS-X")
            + Protobuf.packedIntField(55, [1, 9]), vin: "VIN-ACTIONS-X"))
        #expect(unknownValue.equipment?.reportedEndOwnershipActions == ["Remove App Access"])
    }
}
