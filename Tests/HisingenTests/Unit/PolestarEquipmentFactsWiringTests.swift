import Foundation
import Testing
@testable import Hisingen

/// Wiring tests for the equipment/configuration facts decoded out of the retained raw set:
/// Car 17 (parking assistance), 38 (in-car account linking), 63 (trip reporting),
/// 79 (device pairing), Charging 35.40 (bidirectional charging) and 35.41 (fast-charge
/// preconditioning duration), ParkingClimatization 37.2 (heating type) and 37.12 (automatic
/// seat and steering-wheel heating).
struct PolestarEquipmentFactsWiringTests {
    private func capture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "polestar-c3-undecoded-" + name,
                                                 withExtension: "protobuf"))
        return try Data(contentsOf: url)
    }

    /// Builds a `GetMyCars` response whose Car message carries one capability block.
    private func myCars(car: Data, vin: String) -> VehicleOTACapabilities? {
        PolestarGRPC.parseMyCars(
            Protobuf.messageField(1, Protobuf.messageField(1,
                Protobuf.stringField(1, vin) + car)), vin: vin)
    }

    private func row(_ equipment: VehicleEquipment, _ title: String) -> VehicleEquipment.Detail? {
        equipment.details.first { $0.title == title }
    }

    // MARK: Retained capture

    @Test func equipmentFactsDecodeFromTheRetainedCapture() throws {
        let caps = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        let equipment = try #require(caps.equipment)
        // Car 17 = 1 (RemoteParkingAssistanceType NONE)
        #expect(row(equipment, "Parking Assistance")?.value == "None")
        // Car 38 {2: 1} (InCarAccountLinkingType NONE); the support boolean is absent
        #expect(row(equipment, "In-Car Account Linking")?.value == "None")
        // Car 63 {1: 1, 2: 1}: electric consumption and regeneration, fuel absent
        #expect(row(equipment, "Trip Reporting")?.value == "Electric Consumption, Regeneration")
        // Car 79 = 1
        #expect(row(equipment, "Device Pairing")?.value == "Reported supported")
        // Charging 35.40 {4: empty}: advertised, transfer_limit_settings present but empty
        #expect(row(equipment, "Bidirectional Charging")?.value
            == "Advertised · No transfer limits configured")
        // Charging 35.41 is an empty Duration = zero, and zero still earns its row
        #expect(row(equipment, "Fast-Charge Preconditioning Duration")?.value == "0 min")
    }

    @Test func wiredTagsLeaveTheRawRetainedSet() throws {
        let caps = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        let raw = try #require(caps.unknownWireFields)
        let paths = Set(raw.map { item in
            item.subfield.map { "\($0).\(item.field)" } ?? String(item.field)
        })
        for tag in ["17", "38", "63", "79", "35.40", "35.41", "37.12"] {
            #expect(!paths.contains(tag), "\(tag) is decoded and must not stay in the raw set")
        }
        // The one unnamed tag keeps its place: there is nothing to decode it into yet.
        #expect(paths.contains("35.43"))
    }

    @Test func climateBehaviorDecodesFromTheRetainedCapture() throws {
        let caps = try #require(PolestarGRPC.parseMyCars(capture("capabilities"), vin: "TEST-VIN"))
        // 37.2 = 3 (electrical), 37.12 = true
        #expect(caps.climatizationHeatingType == .electrical)
        #expect(caps.supportsAutomaticSeatAndWheelHeating == true)
    }

    // MARK: Presence vs absence

    @Test func absentEquipmentFieldsStayAbsent() throws {
        let caps = try #require(myCars(car: Data(), vin: "VIN-EMPTY"))
        let equipment = try #require(caps.equipment)
        for title in ["Parking Assistance", "In-Car Account Linking", "Trip Reporting",
                      "Device Pairing", "Bidirectional Charging",
                      "Fast-Charge Preconditioning Duration"] {
            #expect(row(equipment, title) == nil, "\(title) rendered from an absent field")
        }
        #expect(caps.climatizationHeatingType == nil)
        #expect(caps.supportsAutomaticSeatAndWheelHeating == nil)
        #expect(equipment.parkingAssistance == nil)
        #expect(equipment.inCarAccountLinking == nil)
        #expect(equipment.tripReporting == nil)
        #expect(equipment.supportsDevicePairing == nil)
        #expect(equipment.bidirectionalCharging == nil)
        #expect(equipment.bidirectionalTransferLimitsConfigured == nil)
        #expect(equipment.fastChargePreconditioningMinutes == nil)
    }

    // MARK: Enum tables and ordinals

    @Test func parkingAssistanceUnknownOrdinalStaysVisible() throws {
        let unknown = try #require(myCars(car: Protobuf.intField(17, 7), vin: "VIN-PARK"))
        #expect(try #require(unknown.equipment).parkingAssistance == "Unknown (7)")
        // Ordinal 0 is unspecified and hides, like every other label() table.
        let unspecified = try #require(myCars(car: Protobuf.intField(17, 0), vin: "VIN-PARK"))
        #expect(try #require(unspecified.equipment).parkingAssistance == nil)
    }

    @Test func inCarAccountLinkingMapsTheKnownTable() throws {
        func linking(_ type: Int) -> VehicleOTACapabilities? {
            myCars(car: Protobuf.messageField(38, Protobuf.intField(2, type)), vin: "VIN-LINK")
        }
        let androidLogin = try #require(linking(5))
        #expect(try #require(androidLogin.equipment).inCarAccountLinking == "SPA2 Android login")
        let unknown = try #require(linking(42))
        #expect(try #require(unknown.equipment).inCarAccountLinking == "Unknown (42)")
    }

    @Test func tripReportingListsOnlyReportedKinds() throws {
        let trips = Protobuf.messageField(63, Protobuf.intField(1, 1) + Protobuf.intField(3, 1))
        let caps = try #require(myCars(car: trips, vin: "VIN-TRIPS"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.tripReporting == ["Electric Consumption", "Fuel"])
        #expect(row(equipment, "Trip Reporting")?.value == "Electric Consumption, Fuel")
    }

    // MARK: Bidirectional charging and duration

    @Test func bidirectionalChargingRowNotesMissingTransferLimits() throws {
        let withLimits = Protobuf.messageField(35,
            Protobuf.messageField(40, Protobuf.messageField(4, Data())))
        let caps = try #require(myCars(car: withLimits, vin: "VIN-BIDI"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.bidirectionalCharging == true)
        #expect(equipment.bidirectionalTransferLimitsConfigured == false)
        #expect(row(equipment, "Bidirectional Charging")?.value
            == "Advertised · No transfer limits configured")

        // An empty 35.40 advertises without saying anything about limits.
        let bare = try #require(myCars(car: Protobuf.messageField(35, Protobuf.messageField(40, Data())),
                                       vin: "VIN-BIDI"))
        let bareEquipment = try #require(bare.equipment)
        #expect(bareEquipment.bidirectionalTransferLimitsConfigured == nil)
        #expect(row(bareEquipment, "Bidirectional Charging")?.value == "Advertised")
    }

    @Test func fastChargePreconditioningDurationFormatsMinutes() throws {
        // {1: 120 seconds} renders as 2 min.
        let duration = Protobuf.messageField(41, Protobuf.intField(1, 120))
        let caps = try #require(myCars(car: Protobuf.messageField(35, duration), vin: "VIN-DUR"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.fastChargePreconditioningMinutes == 2)
        #expect(row(equipment, "Fast-Charge Preconditioning Duration")?.value == "2 min")
    }

    // MARK: Climate behavior

    @Test func climateHeatingTypeAndAutomaticSeatHeatingDecode() throws {
        let both = try #require(myCars(car: Protobuf.messageField(37,
            Protobuf.intField(2, 3) + Protobuf.intField(12, 1)), vin: "VIN-HEAT"))
        #expect(both.climatizationHeatingType == .electrical)
        #expect(both.supportsAutomaticSeatAndWheelHeating == true)

        let fuel = try #require(myCars(car: Protobuf.messageField(37, Protobuf.intField(2, 2)),
                                       vin: "VIN-HEAT"))
        #expect(fuel.climatizationHeatingType == .fuel)
        #expect(fuel.supportsAutomaticSeatAndWheelHeating == nil)

        // An ordinal outside the known table decodes to nil, so the card claims no heater.
        let unknown = try #require(myCars(car: Protobuf.messageField(37, Protobuf.intField(2, 9)),
                                          vin: "VIN-HEAT"))
        #expect(unknown.climatizationHeatingType == nil)
    }
}
