import Foundation

struct SnapshotFreshness: Codable, Equatable, Sendable {
    var isCached: Bool
    var fetchedAt: Date
    var vehicleReportedAt: Date?
    var readingDates: [VehicleReading: Date]
    /// When the portal's delivery pipeline accepted each reading (`metaReceivedAt`). The gap
    /// to `readingDates` is queue time on the backend side, the reason one domain can be
    /// minutes fresher than another from the same refresh. Optional so snapshots persisted
    /// before retention existed still decode; `nil` when nothing was retained.
    var metaReceivedDates: [VehicleReading: Date]? = nil
    var dataWarnings: [String]
    var unavailableFeatures: [AppFeature]
    var retainedDataCategories: [AppFeature]
    var retainedDataAt: Date?

    init(
        isCached: Bool = false,
        fetchedAt: Date,
        vehicleReportedAt: Date? = nil,
        readingDates: [VehicleReading: Date] = [:],
        metaReceivedDates: [VehicleReading: Date]? = nil,
        dataWarnings: [String] = [],
        unavailableFeatures: [AppFeature] = [],
        retainedDataCategories: [AppFeature] = [],
        retainedDataAt: Date? = nil
    ) {
        self.isCached = isCached
        self.fetchedAt = fetchedAt
        self.vehicleReportedAt = vehicleReportedAt
        self.readingDates = readingDates
        self.metaReceivedDates = metaReceivedDates
        self.dataWarnings = dataWarnings
        self.unavailableFeatures = unavailableFeatures
        self.retainedDataCategories = retainedDataCategories
        self.retainedDataAt = retainedDataAt
    }
}
