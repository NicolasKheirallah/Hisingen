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
    private var memoryCache: [String: Data] = [:]

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
        if let mem = memoryCache[key] {
            return mem
        }

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            memoryCache[key] = data
            return data
        }

        return nil
    }

    private func write(_ data: Data, key: String) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        memoryCache[key] = data

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Could not write cached vehicle image: \(error, privacy: .public)")
        }
    }

    func clear(for vin: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let vin {
            let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            memoryCache = memoryCache.filter { !$0.key.hasPrefix(cleanVIN) }
            if let items = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                for fileURL in items where fileURL.lastPathComponent.hasPrefix(cleanVIN) {
                    do {
                        try fileManager.removeItem(at: fileURL)
                    } catch {
                        logger.error("Could not remove cached vehicle image: \(error, privacy: .public)")
                    }
                }
            }
        } else {
            memoryCache.removeAll()
            do {
                try fileManager.removeItem(at: cacheDirectory)
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            } catch {
                logger.error("Could not clear image cache: \(error, privacy: .public)")
            }
        }
    }
}
