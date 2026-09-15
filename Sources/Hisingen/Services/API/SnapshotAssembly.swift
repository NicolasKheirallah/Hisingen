import Foundation

/// Shared bookkeeping for assembling a `VehicleState` from a provider's parallel readings.
/// Both adapters (Polestar gRPC, Volvo REST) report which requested features a failed
/// reading marks unavailable through this one builder, so the "keep the first report,
/// drop repeats when two readings serve the same feature" rule is written – and tested –
/// exactly once. The degradation matrix ("request-level failure throws, provider-specific
/// failure degrades") is where silently-swallowed provider errors used to hide.
enum SnapshotAssembly {
    struct UnavailableFeatures {
        private(set) var features: [AppFeature] = []
        private var seen = Set<AppFeature>()

        mutating func mark(_ feature: AppFeature, when failed: Bool) {
            guard failed, seen.insert(feature).inserted else { return }
            features.append(feature)
        }

        /// One reading can serve several features; a failure marks them all.
        mutating func mark(_ batch: [AppFeature], when failed: Bool) {
            guard failed else { return }
            for feature in batch { mark(feature, when: true) }
        }
    }
}
