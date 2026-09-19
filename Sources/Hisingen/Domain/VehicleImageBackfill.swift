import Foundation

/// Stored-image fallback a merge caller contributes as data. Domain does not know where
/// persisted images live; the caller that owns that tier resolves the VIN to bytes first and
/// hands the values over, so the merge stays a pure value-in/value-out computation.
struct VehicleImageBackfill: Sendable, Equatable {
    var exterior: Data?
    var interior: Data?

    static let empty = VehicleImageBackfill(exterior: nil, interior: nil)
}
