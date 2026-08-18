import AppKit
import ImageIO

/// Decoded, display-sized vehicle artwork.
///
/// `CarImageCache` hands out the raw bytes, and the studio renders behind them
/// are around 4900 × 2750 px. Decoding one costs ~65 ms and ~54 MB, and PNG
/// cannot be sub-sampled during decode, so this has to happen once per picture —
/// off the main thread — and be kept. The alternative is what the hero card used
/// to do: hand `NSImage(data:)` to SwiftUI on every body evaluation and let the
/// decode land in the render pass of whichever telemetry refresh got there first.
@MainActor
final class VehicleArtworkStore {
    private let imageCache: CarImageCache

    init(imageCache: CarImageCache = CarImageCache()) {
        self.imageCache = imageCache
    }

    struct Artwork {
        /// Decoded at display resolution rather than at source resolution.
        let image: CGImage
        /// True pixel dimensions of the source, which is what the aspect ratio
        /// has to come from — the thumbnail's own size is rounded.
        let sourcePixelSize: CGSize
    }

    /// Identifies a decode. `byteCount` stands in for the bytes themselves so a
    /// replaced image invalidates the entry without comparing megabytes.
    private struct Key: Hashable {
        let source: String
        let byteCount: Int
        let pixelBudget: Int
    }

    /// Six exterior angles plus the cabin, at ~2.4 MB each once decoded.
    private let capacity = 8

    private var cache: [Key: Artwork] = [:]
    private var recency: [Key] = []
    private var pending: [Key: [(Artwork?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.hisingen.artwork-decode", qos: .userInitiated)

    /// Rounds a required pixel size up to a coarse step, so a one-point layout
    /// change does not throw away a perfectly good decode.
    ///
    /// The step is small deliberately: decoding much larger than the drawn size
    /// means the render is downscaled twice — once by ImageIO, once by the
    /// compositor — and detail like grille slats and wheel spokes softens.
    static func pixelBudget(pointSize: CGSize, scale: CGFloat) -> Int {
        let longest = max(pointSize.width, pointSize.height) * max(scale, 1)
        guard longest > 0 else { return 256 }
        return max(256, Int((longest / 64).rounded(.up)) * 64)
    }

    /// The source's true pixel dimensions, read from its header without decoding
    /// any pixels — around 0.2 ms for a 3 MB PNG. Cheap enough to ask before
    /// deciding how big a decode to order.
    nonisolated static func sourcePixelSize(of data: Data) -> CGSize? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    func cached(source: String, data: Data, pixelBudget: Int) -> Artwork? {
        let key = Key(source: source, byteCount: data.count, pixelBudget: pixelBudget)
        guard let artwork = cache[key] else { return nil }
        touch(key)
        return artwork
    }

    /// Decodes off the main thread, calling back on the main actor. Concurrent
    /// requests for the same picture share a single decode.
    func load(
        source: String,
        data: Data,
        pixelBudget: Int,
        completion: @escaping (Artwork?) -> Void
    ) {
        let key = Key(source: source, byteCount: data.count, pixelBudget: pixelBudget)
        if let artwork = cache[key] {
            touch(key)
            completion(artwork)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        queue.async {
            let artwork = Self.decode(data: data, pixelBudget: pixelBudget)
            Task { @MainActor in
                self.finish(key: key, artwork: artwork)
            }
        }
    }

    /// `load` for callers that can await it.
    func artwork(source: String, data: Data, pixelBudget: Int) async -> Artwork? {
        await withCheckedContinuation { continuation in
            load(source: source, data: data, pixelBudget: pixelBudget) { continuation.resume(returning: $0) }
        }
    }

    /// Decodes every exterior angle this car has cached, at low priority, so
    /// changing angle does not wait on a decode. Runs entirely off the main
    /// thread: `CarImageCache` is lock-guarded and safe to read from here.
    func warmExteriorAngles(vin: String, pixelBudget: Int) {
        let known = Set(cache.keys.map(\.source))
        let sources = CarRenderAngle.allCases.map { (angle: $0.rawValue, source: Self.source(vin: vin, angle: $0.rawValue)) }
            .filter { !known.contains($0.source) }
        guard !sources.isEmpty else { return }

        queue.async(qos: .utility) {
            for entry in sources {
                guard let data = self.imageCache.image(for: vin, angle: entry.angle) else { continue }
                let key = Key(source: entry.source, byteCount: data.count, pixelBudget: pixelBudget)
                let artwork = Self.decode(data: data, pixelBudget: pixelBudget)
                Task { @MainActor in
                    guard let artwork, self.cache[key] == nil, self.pending[key] == nil else { return }
                    self.insert(artwork, for: key)
                }
            }
        }
    }

    /// Cache key for a picture of a car. Angle `-1` is the cabin photo.
    static func source(vin: String, angle: Int) -> String {
        "\(vin.uppercased())#\(angle)"
    }

    func reset() {
        cache.removeAll()
        recency.removeAll()
    }

    // MARK: - Private

    private func finish(key: Key, artwork: Artwork?) {
        let waiting = pending.removeValue(forKey: key) ?? []
        if let artwork {
            insert(artwork, for: key)
        }
        for completion in waiting {
            completion(artwork)
        }
    }

    private func insert(_ artwork: Artwork, for key: Key) {
        cache[key] = artwork
        touch(key)
        while recency.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private nonisolated static func decode(data: Data, pixelBudget: Int) -> Artwork? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Force the decode onto this queue instead of deferring it to the
            // first draw, which would happen on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelBudget
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
        guard width > 0, height > 0 else { return nil }

        return Artwork(image: image, sourcePixelSize: CGSize(width: width, height: height))
    }
}
