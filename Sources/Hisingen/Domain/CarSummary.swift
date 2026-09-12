import Foundation

struct CarSummary: Codable, Equatable, Sendable {
    let vin: String
    let title: String
    var modelName: String?
    var modelYear: String?
    var registrationNo: String?

    init(
        vin: String,
        title: String,
        modelName: String? = nil,
        modelYear: String? = nil,
        registrationNo: String? = nil
    ) {
        self.vin = vin
        self.title = title
        self.modelName = modelName
        self.modelYear = modelYear
        self.registrationNo = registrationNo
    }

    @MainActor
    func displayTitle(format: VehicleLabelFormat? = nil, preferences: PreferencesStore? = nil) -> String {
        // The store is created inside the isolated body: Swift 6 rejects actor-isolated
        // default-argument expressions, which are evaluated in the caller's context.
        let resolvedPreferences = preferences ?? PreferencesStore()
        return resolvedPreferences.formattedVehicleTitle(
            vin: vin,
            modelName: modelName ?? (title.contains(" · ") ? title.components(separatedBy: " · ").first : title),
            modelYear: modelYear ?? (title.contains(" · ") ? title.components(separatedBy: " · ").last : nil),
            registrationNo: registrationNo,
            format: format
        )
    }
}
