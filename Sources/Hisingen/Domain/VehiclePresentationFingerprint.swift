import Foundation

/// Equality key for deciding whether SwiftUI needs a fresh vehicle presentation. Artwork bytes
/// are represented by size, matching the image presentation layer, so duplicate multi-megabyte
/// buffers never participate in a state comparison.
struct VehiclePresentationFingerprint: Equatable, Sendable {
    private let comparableState: VehicleState
    private let exteriorImageByteCount: Int?
    private let interiorImageByteCount: Int?

    init(_ state: VehicleState) {
        exteriorImageByteCount = state.identity.imageData?.count
        interiorImageByteCount = state.identity.interiorImageData?.count
        var comparable = state
        comparable.freshness.fetchedAt = .distantPast
        comparable.identity.imageData = nil
        comparable.identity.interiorImageData = nil
        comparableState = comparable
    }
}
