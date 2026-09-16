import Foundation
import OSLog

final class CarImageCache: @unchecked Sendable {
    static let shared = CarImageCache()

    // Deliberately NOT recorded in APIDiagnosticLogStore: CDN image fetches are
    // high-volume, low-diagnostic-value traffic, and failures already surface as a
    // missing render plus a unified-log entry here.

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let database: VehicleDatabase
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.hisingen.image-cache-io", qos: .utility)
    private let logger = AppLog.logger("image-cache")
    // Raw source bytes are capped so a long session switching vehicles/angles cannot pin
    // hundreds of MB (each entry is up to the 5 MB download cap); entries evict
    // least-recently-used past the budget, mirroring VehicleArtworkStore's bounded tier.
    private static let memoryCacheByteBudget = 32 * 1024 * 1024
    private var memoryCache: [String: Data] = [:]
    private var memoryCacheRecency: [String] = []
    private var memoryCacheBytes = 0

    /// Sentinel SQLite angle for the bare primary image (no `_angle` suffix). Angle 0 is a
    /// real `CarRenderAngle.sideProfile` row; aliasing it made SQLite fallback reads return
    /// the wrong-angle render as the side profile. -1 is already the interior sentinel.
    private static let primaryImageSQLiteAngle = -2

    init(cacheDirectory: URL? = nil, database: VehicleDatabase = .shared) {
        self.database = database
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = paths.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cacheDirectory ?? base.appendingPathComponent("Hisingen/CarImages", isDirectory: true)
        self.cacheDirectory = dir
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create image cache directory: \(error, privacy: .public)")
        }
    }

    func hasImage(for vin: String, angle: Int? = nil) -> Bool {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return false }
        let key = angle.map { "\(cleanVIN)_angle\($0)" } ?? cleanVIN
        lock.lock()
        let inMemory = memoryCache[key] != nil
        lock.unlock()
        if inMemory { return true }
        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if fileManager.fileExists(atPath: fileURL.path) { return true }
        guard let parts = parseKey(key) else { return false }
        return database.hasVehicleImage(for: parts.vin, angle: parts.angle)
    }

    func image(for vin: String, angle: Int? = nil) -> Data? {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return nil }
        let key = angle.map { "\(cleanVIN)_angle\($0)" } ?? cleanVIN
        return read(key: key)
    }

    func save(_ data: Data, for vin: String, angle: Int? = nil) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return }
        let key = angle.map { "\(cleanVIN)_angle\($0)" } ?? cleanVIN
        write(data, key: key)
    }

    func interiorImage(for vin: String) -> Data? {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return nil }
        return read(key: "\(cleanVIN)_interior")
    }

    func saveInterior(_ data: Data, for vin: String) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return }
        write(data, key: "\(cleanVIN)_interior")
    }

    private func read(key: String) -> Data? {
        lock.lock()
        if let mem = cachedBytes(forKey: key) {
            lock.unlock()
            return mem
        }
        lock.unlock()

        if let parts = parseKey(key) {
            if let dbImage = database.loadVehicleImage(for: parts.vin, angle: parts.angle) {
                lock.lock()
                store(dbImage.data, forKey: key)
                lock.unlock()
                return dbImage.data
            }
        }

        // Files are a legacy tier. Migrate a hit into the single SQLite durable store and
        // remove the duplicate only after the database write has completed.
        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            lock.lock()
            store(data, forKey: key)
            lock.unlock()
            persist(data, key: key, legacyFileURL: fileURL)
            return data
        }

        return nil
    }

    private func write(_ data: Data, key: String) {
        guard !data.isEmpty else { return }

        lock.lock()
        store(data, forKey: key)
        lock.unlock()

        persist(data, key: key, legacyFileURL: nil)
    }

    private func persist(_ data: Data, key: String, legacyFileURL: URL?) {
        guard let parts = parseKey(key) else { return }
        let database = self.database
        ioQueue.async { [logger] in
            let saved = database.saveVehicleImage(vin: parts.vin, angle: parts.angle, data: data)
            if saved, let legacyFileURL {
                do { try FileManager.default.removeItem(at: legacyFileURL) }
                catch { logger.debug("Could not remove migrated image cache file: \(error, privacy: .public)") }
            }
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume() }
        }
    }

    /// Drops the in-memory bytes for one VIN (primary, all angles, interior). Called from the
    /// sign-out/clear path so a signed-out vehicle's renders stop pinning memory; the disk and
    /// SQLite tiers remain as the durable cache.
    ///
    /// An empty VIN names no vehicle and drops nothing: the fleet-wide drop is
    /// `dropAllMemoryCaches()`, so a blank identifier can never mean "every vehicle" one tier
    /// away from a database delete that reads it as a scoped no-op.
    func dropMemoryCache(for vin: String) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let stale = memoryCache.keys.filter { $0 == cleanVIN || $0.hasPrefix("\(cleanVIN)_") }
        guard !stale.isEmpty else { return }
        for key in stale {
            memoryCacheBytes -= memoryCache[key]?.count ?? 0
            memoryCache.removeValue(forKey: key)
        }
        memoryCacheRecency.removeAll { stale.contains($0) }
    }

    /// The fleet-wide counterpart, named so that dropping every vehicle's renders is always a
    /// deliberate call.
    func dropAllMemoryCaches() {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeAll()
        memoryCacheRecency.removeAll()
        memoryCacheBytes = 0
    }

    // Callers hold `lock`.
    private func cachedBytes(forKey key: String) -> Data? {
        guard let data = memoryCache[key] else { return nil }
        memoryCacheRecency.removeAll { $0 == key }
        memoryCacheRecency.append(key)
        return data
    }

    // Callers hold `lock`. Evicts least-recently-used entries until the byte budget holds.
    private func store(_ data: Data, forKey key: String) {
        if let existing = memoryCache[key] {
            memoryCacheBytes -= existing.count
            memoryCacheRecency.removeAll { $0 == key }
        }
        memoryCache[key] = data
        memoryCacheBytes += data.count
        memoryCacheRecency.append(key)
        while memoryCacheBytes > Self.memoryCacheByteBudget, let oldest = memoryCacheRecency.first {
            memoryCacheRecency.removeFirst()
            if let evicted = memoryCache.removeValue(forKey: oldest) {
                memoryCacheBytes -= evicted.count
            }
        }
    }

    private func parseKey(_ key: String) -> (vin: String, angle: Int)? {
        if key.hasSuffix("_interior") {
            let vin = String(key.dropLast("_interior".count))
            return (vin, -1)
        } else if let range = key.range(of: "_angle") {
            let vin = String(key[..<range.lowerBound])
            let angleStr = String(key[range.upperBound...])
            if let angle = Int(angleStr) {
                return (vin, angle)
            }
            return (vin, 0)
        } else {
            return (key, Self.primaryImageSQLiteAngle)
        }
    }

}
