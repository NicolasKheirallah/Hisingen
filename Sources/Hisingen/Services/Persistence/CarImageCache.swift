import Foundation
import OSLog

final class CarImageCache: @unchecked Sendable {
    static let shared = CarImageCache()

    // Deliberately NOT recorded in APIDiagnosticLogStore: CDN image fetches are
    // high-volume, low-diagnostic-value traffic, and failures already surface as a
    // missing render plus a unified-log entry here.

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let lock = NSLock()
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

    init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = paths.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hisingen/CarImages", isDirectory: true)
        cacheDirectory = dir
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
        defer { lock.unlock() }
        if memoryCache[key] != nil { return true }
        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        return fileManager.fileExists(atPath: fileURL.path)
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
        defer { lock.unlock() }
        if let mem = cachedBytes(forKey: key) {
            return mem
        }

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            store(data, forKey: key)
            return data
        }

        // Try SQLite database storage
        if let parts = parseKey(key) {
            if let dbImage = VehicleDatabase.shared.loadVehicleImage(for: parts.vin, angle: parts.angle) {
                store(dbImage.data, forKey: key)
                return dbImage.data
            }
        }

        return nil
    }

    private func write(_ data: Data, key: String) {
        guard !data.isEmpty else { return }

        lock.lock()
        store(data, forKey: key)
        lock.unlock()

        if let parts = parseKey(key) {
            VehicleDatabase.shared.saveVehicleImage(vin: parts.vin, angle: parts.angle, data: data)
        }

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Could not write cached vehicle image: \(error, privacy: .public)")
        }
    }

    /// Drops the in-memory bytes for one VIN (primary, all angles, interior); a nil VIN
    /// clears the whole tier. Called from the sign-out/clear path so a signed-out vehicle's
    /// renders stop pinning memory; the disk and SQLite tiers remain as the durable cache.
    func dropMemoryCache(for vin: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let cleanVIN = vin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !cleanVIN.isEmpty else {
            memoryCache.removeAll()
            memoryCacheRecency.removeAll()
            memoryCacheBytes = 0
            return
        }
        let stale = memoryCache.keys.filter { $0 == cleanVIN || $0.hasPrefix("\(cleanVIN)_") }
        guard !stale.isEmpty else { return }
        for key in stale {
            memoryCacheBytes -= memoryCache[key]?.count ?? 0
            memoryCache.removeValue(forKey: key)
        }
        memoryCacheRecency.removeAll { stale.contains($0) }
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
