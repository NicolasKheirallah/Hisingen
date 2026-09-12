import Foundation

struct ServiceSnapshot: Codable, Equatable, Sendable {
    var daysToService: Int?
    var distanceToServiceKm: Int?
    var serviceWarning: Bool
    var fluidWarnings: [String]
    var engineHoursToService: Int?
    /// Raw provider service-trigger code (e.g. "TIME", "MILEAGE").
    var trigger: String?
    var preferredWorkshopID: String?
    var preferredWorkshopName: String?

    init(daysToService: Int? = nil, distanceToServiceKm: Int? = nil,
         serviceWarning: Bool = false, fluidWarnings: [String] = [],
         engineHoursToService: Int? = nil, trigger: String? = nil,
         preferredWorkshopID: String? = nil, preferredWorkshopName: String? = nil) {
        self.daysToService = daysToService
        self.distanceToServiceKm = distanceToServiceKm
        self.serviceWarning = serviceWarning
        self.fluidWarnings = fluidWarnings
        self.engineHoursToService = engineHoursToService
        self.trigger = trigger
        self.preferredWorkshopID = preferredWorkshopID
        self.preferredWorkshopName = preferredWorkshopName
    }
}


struct MaintenanceAndHealthSnapshot: Codable, Equatable, Sendable {
    var odometerKm: Int?
    var details: VehicleHealthDetails?
    var service: ServiceSnapshot
    var warranty: VehicleWarrantyInfo?
    var frontBrakePadStatus: String?
    var rearBrakePadStatus: String?

    init(
        odometerKm: Int? = nil,
        details: VehicleHealthDetails? = nil,
        service: ServiceSnapshot = .init(),
        warranty: VehicleWarrantyInfo? = nil,
        frontBrakePadStatus: String? = nil,
        rearBrakePadStatus: String? = nil
    ) {
        self.odometerKm = odometerKm
        self.details = details
        self.service = service
        self.warranty = warranty
        self.frontBrakePadStatus = frontBrakePadStatus
        self.rearBrakePadStatus = rearBrakePadStatus
    }
}
