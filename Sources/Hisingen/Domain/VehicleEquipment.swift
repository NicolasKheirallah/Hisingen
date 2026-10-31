import Foundation

/// Specifications and reporting support, separate from live vehicle state.
struct VehicleEquipment: Codable, Equatable, Sendable {
    var brand: String?
    var vehicleTypeCode: String?
    var drivetrain: String?
    var engine: String?
    var driverSide: String?
    var infotainment: String?
    var doorCount: Int?
    var chargePort: String?
    var batterySerial: String?
    var batteryCapacityKwh: Double?
    /// Gross vehicle weight rating in kilograms (`Car.grossVehicleWeightRating`, wire field 44,
    /// a fixed32 float).
    var grossVehicleWeightRatingKg: Double?
    var digitalKey: String?
    var nfcReader: String?
    var compatiblePhones: [String]?
    var dailyChargeTarget: Int?
    var automaticBatteryPreconditioning: Bool?
    var airCleaningRuntimeMinutes: Int?
    var internalAirMeasurement: Bool?
    var externalAirMeasurement: Bool?
    var supportedLightWarnings: [String]?
    var restrictedSoftwareVersion: String?
    /// Factory option groups from the `GetMyCars` visual-identity string (wire field 47). The
    /// captured 16-group string carries the vehicle type at position 1, the front grille variant at
    /// 12 and the model year at 16; the groups between them stay positional.
    var contentCodes: [String]?

    /// Backend report-support statements. `nil` when the wire field is absent: proto3 omits
    /// false, so absence cannot separate "not reported" from "reported false" and the UI must
    /// hide the row instead of guessing.
    var reportsAvgElectricConsumption: Bool?
    var reportsAvgSpeed: Bool?
    var reportsAvgSpeedLastTrip: Bool?
    var supportsDrivingJournal: Bool?
    var supportsStolenVehicleTracking: Bool?
    /// `Charging` 35.5: the vehicle reports its charge level during an active session.
    var reportsChargeLevelWhileCharging: Bool?
    /// `Charging` 35.7: the vehicle reports an electric range figure.
    var reportsElectricRange: Bool?
    /// `Charging` 35.27
    /// (`supports_charge_locations_departure_time_min_charge_level_setting`): departure times
    /// at charge locations can carry a minimum charge level.
    var supportsChargeLocationsDepartureTimeMinChargeLevelSetting: Bool?
    /// Notification kinds the backend says it sends for this vehicle (`Car` wire field 51,
    /// `notification`). Only the subfields with a verified name are listed, in subfield order;
    /// `nil` when the message is absent or no named kind is set.
    var reportedNotificationKinds: [String]?
    /// End-of-ownership actions the backend says it can perform (`Car` wire field 55,
    /// `end_ownership_actions`), kept in the order the frame lists them; `nil` when absent.
    var reportedEndOwnershipActions: [String]?
    /// `Car.parking_assistance_type` (wire field 17, enum `RemoteParkingAssistanceType`),
    /// stored as the decoded label. `nil` when the field is absent, unspecified or holds an
    /// ordinal this build cannot name.
    var parkingAssistance: String?
    /// `Car.account_linking.in_car_account_linking_type` (wire field 38.2), stored as the
    /// decoded label. `nil` when the enum is absent, unspecified or unknown. The message's
    /// support boolean (38.1) is not decoded; it is absent on the captured frame.
    var inCarAccountLinking: String?
    /// Trip kinds the car reports (`Car.trips`, wire field 63), as raw label keys. `nil` when
    /// the message is absent; empty when it carries no supported kind.
    var tripReporting: [String]?
    /// `Car.supports_device_pairing` (wire field 79). `nil` when the field is absent.
    var supportsDevicePairing: Bool?
    /// Whether the backend advertises bidirectional charging (`Charging.bidirectional_charging`,
    /// wire field 35.40). `nil` when the message is absent.
    var bidirectionalCharging: Bool?
    /// Whether `Charging.bidirectional_charging.transfer_limit_settings` (35.40.4) carries
    /// configured limits. `false` when the submessage is present but empty; `nil` when absent
    /// or holding a layout this build cannot read.
    var bidirectionalTransferLimitsConfigured: Bool?
    /// `Charging.remote_manual_fast_charging_battery_preconditioning_duration` (wire field
    /// 35.41, a `google.protobuf.Duration`) in minutes. An empty duration decodes to 0, which
    /// still earns its row; `nil` when the field is absent or unreadable.
    var fastChargePreconditioningMinutes: Int?

    /// One group of `contentCodes`, named only when the group's meaning is verified. A different
    /// platform can order its groups differently, so the value must also have the shape that
    /// position carries on the captured frame; otherwise the group keeps its position number.
    struct ContentCode: Identifiable, Equatable, Sendable {
        /// 1-based position in `contentCodes`.
        let index: Int
        let code: String
        let label: String?
        var id: Int { index }
    }

    var contentCodeEntries: [ContentCode] {
        guard let contentCodes else { return [] }
        return contentCodes.enumerated().map { offset, code in
            let index = offset + 1
            return ContentCode(index: index, code: code, label: Self.contentCodeLabel(index, code))
        }
    }

    /// `visual_id` group meanings verified against the retained C3 frame: `534` is the Polestar 2
    /// vehicle type, `GR04` the body-coloured front grille variant and `2023` the model year.
    static func contentCodeLabel(_ index: Int, _ code: String) -> String? {
        switch index {
        case 1 where code.count == 3 && code.allSatisfy(\.isNumber):
            return L10n.text("Vehicle Type")
        case 12 where code.count == 4
            && code.prefix(2).allSatisfy(\.isUppercase)
            && code.suffix(2).allSatisfy(\.isNumber):
            return L10n.text("Grille Variant")
        case 16 where code.count == 4 && code.allSatisfy(\.isNumber):
            guard let year = Int(code), (1950...2100).contains(year) else { return nil }
            return L10n.text("Model Year")
        default:
            return nil
        }
    }

    struct Detail: Identifiable, Equatable, Sendable {
        let title: String
        let value: String
        var id: String { title }
    }

    var details: [Detail] {
        var rows: [Detail] = []
        func text(_ title: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(Detail(title: title, value: value))
        }
        func flag(_ title: String, _ value: Bool?) {
            text(title, value.map { L10n.text($0 ? "Reported supported" : "Not supported") })
        }
        text("Brand", brand)
        text("Vehicle Type Code", vehicleTypeCode)
        text("Drivetrain", drivetrain.map(L10n.text))
        text("Engine Type", engine.map(L10n.text))
        text("Steering Orientation", driverSide.map(L10n.text))
        text("Infotainment", infotainment.map(L10n.text))
        text("Door Count", doorCount.map(String.init))
        text("DC Charge Port", chargePort.map(L10n.text))
        text("Battery Pack Serial", batterySerial)
        text("Reported Battery Capacity", batteryCapacityKwh.map { String(format: "%.2f kWh", $0) })
        text("Gross Vehicle Weight",
             grossVehicleWeightRatingKg.map { String(format: "%.0f kg", $0) })
        text("Digital Key Type", digitalKey.map(L10n.text))
        text("NFC Reader Location", nfcReader.map(L10n.text))
        text("Compatible Phones", compatiblePhones?.joined(separator: ", "))
        text("Parking Assistance", parkingAssistance.map(L10n.text))
        text("In-Car Account Linking", inCarAccountLinking.map(L10n.text))
        flag("Device Pairing", supportsDevicePairing)
        text("Daily Charge Target", dailyChargeTarget.map { Format.percent(Double($0)) })
        if bidirectionalCharging == true {
            var bidirectionalValue = L10n.text("Advertised")
            if bidirectionalTransferLimitsConfigured == false {
                bidirectionalValue = L10n.format("%@ · %@", bidirectionalValue,
                                                 L10n.text("No transfer limits configured"))
            }
            text("Bidirectional Charging", bidirectionalValue)
        }
        flag("Automatic Battery Preconditioning", automaticBatteryPreconditioning)
        text("Fast-Charge Preconditioning Duration",
             fastChargePreconditioningMinutes.map { L10n.format("%d min", $0) })
        text("Pre-clean Runtime", airCleaningRuntimeMinutes.map { L10n.format("%d min", $0) })
        flag("Internal Air Measurement", internalAirMeasurement)
        flag("External Air Measurement", externalAirMeasurement)
        text("Trip Reporting", tripReporting.map { $0.map(L10n.text).joined(separator: ", ") })
        text("Factory Content Codes", contentCodes?.joined(separator: " "))
        return rows
    }

    /// Rows for the Backend Reporting disclosure: what the backend states about this vehicle.
    /// Separate from `details` because these are the backend's own statements, not equipment
    /// facts, and copy must never read as if a control exists. A `nil` field contributes no
    /// row, so an absent answer stays hidden instead of reading as "no".
    var reportingDetails: [Detail] {
        var rows: [Detail] = []
        func report(_ title: String, _ value: Bool?) {
            guard let value else { return }
            rows.append(Detail(title: title, value: L10n.text(value ? "Reported supported" : "Not reported")))
        }
        func list(_ title: String, _ value: [String]?) {
            guard let value, !value.isEmpty else { return }
            rows.append(Detail(title: title, value: value.joined(separator: ", ")))
        }
        report("Avg Electric Consumption Reporting", reportsAvgElectricConsumption)
        report("Avg Speed Reporting", reportsAvgSpeed)
        report("Avg Speed Last Trip Reporting", reportsAvgSpeedLastTrip)
        report("Driving Journal", supportsDrivingJournal)
        report("Stolen Vehicle Tracking", supportsStolenVehicleTracking)
        report("Charge Level While Charging", reportsChargeLevelWhileCharging)
        report("Electric Range Reporting", reportsElectricRange)
        report("Departure Time Min Charge Level Setting",
               supportsChargeLocationsDepartureTimeMinChargeLevelSetting)
        list("Backend Notifications", reportedNotificationKinds)
        list("End of Ownership Actions", reportedEndOwnershipActions)
        return rows
    }

    func softwareVersionDisagrees(with installed: String?) -> Bool {
        guard let installed, !installed.isEmpty,
              let restrictedSoftwareVersion, !restrictedSoftwareVersion.isEmpty else { return false }
        return installed != restrictedSoftwareVersion
    }
}
