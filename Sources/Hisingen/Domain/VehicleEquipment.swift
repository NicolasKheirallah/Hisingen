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
    /// Factory option groups from the `GetMyCars` content-code string (wire field 47, e.g.
    /// paint, wheels, trim groups). Shown as-is until each group's label is verified.
    var contentCodes: [String]?

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
        text("Digital Key Type", digitalKey.map(L10n.text))
        text("NFC Reader Location", nfcReader.map(L10n.text))
        text("Compatible Phones", compatiblePhones?.joined(separator: ", "))
        text("Daily Charge Target", dailyChargeTarget.map { Format.percent(Double($0)) })
        flag("Automatic Battery Preconditioning", automaticBatteryPreconditioning)
        text("Pre-clean Runtime", airCleaningRuntimeMinutes.map { L10n.format("%d min", $0) })
        flag("Internal Air Measurement", internalAirMeasurement)
        flag("External Air Measurement", externalAirMeasurement)
        text("Factory Content Codes", contentCodes?.joined(separator: " "))
        return rows
    }

    func softwareVersionDisagrees(with installed: String?) -> Bool {
        guard let installed, !installed.isEmpty,
              let restrictedSoftwareVersion, !restrictedSoftwareVersion.isEmpty else { return false }
        return installed != restrictedSoftwareVersion
    }
}
