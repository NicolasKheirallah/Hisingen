import Foundation

struct SnapshotFreshness: Codable, Equatable, Sendable {
    var isCached: Bool
    var fetchedAt: Date
    var vehicleReportedAt: Date?
    var readingDates: [VehicleReading: Date]
    var dataWarnings: [String]
    var unavailableFeatures: [AppFeature]
    var retainedDataCategories: [AppFeature]
    var retainedDataAt: Date?

    init(
        isCached: Bool = false,
        fetchedAt: Date,
        vehicleReportedAt: Date? = nil,
        readingDates: [VehicleReading: Date] = [:],
        dataWarnings: [String] = [],
        unavailableFeatures: [AppFeature] = [],
        retainedDataCategories: [AppFeature] = [],
        retainedDataAt: Date? = nil
    ) {
        self.isCached = isCached
        self.fetchedAt = fetchedAt
        self.vehicleReportedAt = vehicleReportedAt
        self.readingDates = readingDates
        self.dataWarnings = dataWarnings
        self.unavailableFeatures = unavailableFeatures
        self.retainedDataCategories = retainedDataCategories
        self.retainedDataAt = retainedDataAt
    }
}
