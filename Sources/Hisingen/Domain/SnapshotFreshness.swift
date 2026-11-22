import Foundation

enum VehicleReadingSource: String, Codable, Sendable {
    case polestarGraphQL, polestarGRPC, polestarPortal, liveStream, weather, volvo

    /// What the reader is shown when a reading's provenance is displayed. The names are the
    /// services the app actually talks to, not internal module names.
    var displayName: String {
        switch self {
        case .polestarGraphQL: return L10n.text("Polestar GraphQL")
        case .polestarGRPC: return L10n.text("Polestar cloud")
        case .polestarPortal: return L10n.text("Polestar portal")
        case .liveStream: return L10n.text("Live stream")
        case .weather: return L10n.text("Weather service")
        case .volvo: return L10n.text("Volvo cloud")
        }
    }
}

extension VehicleReadingSource {
    /// The word the Reading Freshness rows use for the transport that answered. Short on
    /// purpose: the row already carries the age and the portal queue time.
    var readoutWord: String {
        switch self {
        case .polestarGraphQL: return L10n.text("App")
        case .polestarGRPC: return "gRPC"
        case .polestarPortal: return L10n.text("Portal")
        case .liveStream: return L10n.text("Live")
        case .weather: return L10n.text("Weather")
        case .volvo: return L10n.text("Volvo")
        }
    }
}

struct VehicleReadingObservation: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let source: VehicleReadingSource
    var isCached: Bool = false
}

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
    /// True when this snapshot was served by the fallback credential (the consumer Polestar ID
    /// session) rather than the configured primary (the Developer Portal). `nil` when the
    /// primary served it or the snapshot predates the marker, so old persisted snapshots
    /// decode without migration.
    var servedByFallback: Bool? = nil
    var readingObservations: [VehicleReading: VehicleReadingObservation]? = nil
    var commandObservations: [CommandDisplayField: VehicleReadingObservation]? = nil

    init(
        isCached: Bool = false,
        fetchedAt: Date,
        vehicleReportedAt: Date? = nil,
        readingDates: [VehicleReading: Date] = [:],
        metaReceivedDates: [VehicleReading: Date]? = nil,
        dataWarnings: [String] = [],
        unavailableFeatures: [AppFeature] = [],
        retainedDataCategories: [AppFeature] = [],
        retainedDataAt: Date? = nil,
        servedByFallback: Bool? = nil,
        readingObservations: [VehicleReading: VehicleReadingObservation]? = nil,
        commandObservations: [CommandDisplayField: VehicleReadingObservation]? = nil
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
        self.servedByFallback = servedByFallback
        self.readingObservations = readingObservations
        self.commandObservations = commandObservations
    }

    /// Records which service produced each reading in this snapshot. Call sites are the
    /// assemblers, which know their own producer. A reading that already carries an observation
    /// keeps it: a live-stream merge mid-refresh is more specific than the refresh around it.
    mutating func recordSource(_ source: VehicleReadingSource) {
        var observations = readingObservations ?? [:]
        let fetched = fetchedAt
        for (reading, reportedAt) in readingDates where observations[reading] == nil {
            observations[reading] = VehicleReadingObservation(fetchedAt: fetched, source: source)
            _ = reportedAt
        }
        readingObservations = observations
    }

    /// `recordSource` for a value position, so an assembler can stamp the snapshot it just built
    /// without giving up `let`.
    func recordedSource(_ source: VehicleReadingSource) -> SnapshotFreshness {
        var copy = self
        copy.recordSource(source)
        return copy
    }

    /// The service behind one reading, when the app recorded it. nil means unknown, and the UI
    /// says nothing rather than naming a guess.
    func source(for reading: VehicleReading) -> VehicleReadingSource? {
        readingObservations?[reading]?.source
    }
}
