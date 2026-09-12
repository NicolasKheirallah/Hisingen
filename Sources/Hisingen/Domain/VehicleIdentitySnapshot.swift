import Foundation

struct VehicleIdentitySnapshot: Codable, Equatable, Sendable {
    var availability: VehicleAvailability
    /// When the availability frame was reported by the vehicle (wire field 1). `nil` when
    /// absent or in snapshots persisted before retention existed.
    var availabilityReportedAt: Date? = nil
    /// Undecoded availability wire fields, captured raw for future classification.
    var availabilityUnknownWireFields: [PolestarRawWireField]? = nil
    var modelName: String?
    var modelYear: String?
    var registrationNo: String?
    var vin: String
    var ownerFirstName: String?
    var externalColour: String?
    var gearbox: String?
    var structureWeek: String?
    var internalVehicleIdentifier: String?
    var pno34: String?
    var accountMarket: String?
    var upholstery: String?
    var steeringOrientation: String?
    var imageData: Data?
    var interiorImageData: Data?

    init(
        availability: VehicleAvailability,
        availabilityReportedAt: Date? = nil,
        availabilityUnknownWireFields: [PolestarRawWireField]? = nil,
        modelName: String? = nil,
        modelYear: String? = nil,
        registrationNo: String? = nil,
        vin: String,
        ownerFirstName: String? = nil,
        externalColour: String? = nil,
        gearbox: String? = nil,
        structureWeek: String? = nil,
        internalVehicleIdentifier: String? = nil,
        pno34: String? = nil,
        accountMarket: String? = nil,
        upholstery: String? = nil,
        steeringOrientation: String? = nil,
        imageData: Data? = nil,
        interiorImageData: Data? = nil
    ) {
        self.availability = availability
        self.availabilityReportedAt = availabilityReportedAt
        self.availabilityUnknownWireFields = availabilityUnknownWireFields
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
        self.vin = vin
        self.ownerFirstName = ownerFirstName
        self.externalColour = externalColour
        self.gearbox = gearbox
        self.structureWeek = structureWeek
        self.internalVehicleIdentifier = internalVehicleIdentifier
        self.pno34 = pno34
        self.accountMarket = accountMarket
        self.upholstery = upholstery
        self.steeringOrientation = steeringOrientation
        self.imageData = imageData
        self.interiorImageData = interiorImageData
    }
}
