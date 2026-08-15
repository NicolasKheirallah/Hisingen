import Foundation

final class CarImageCache: @unchecked Sendable {
    static let shared = CarImageCache()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let lock = NSLock()
    private var memoryCache: [String: Data] = [:]

    init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = paths.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hisingen/CarImages", isDirectory: true)
        cacheDirectory = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for vin: String) -> Data? {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return nil }

        lock.lock()
        if let mem = memoryCache[cleanVIN] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(cleanVIN).jpg")
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }

        lock.lock()
        memoryCache[cleanVIN] = data
        lock.unlock()
        return data
    }

    func save(_ data: Data, for vin: String) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty, !data.isEmpty else { return }

        lock.lock()
        memoryCache[cleanVIN] = data
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(cleanVIN).jpg")
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear(for vin: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let vin {
            let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            memoryCache.removeValue(forKey: cleanVIN)
            let fileURL = cacheDirectory.appendingPathComponent("\(cleanVIN).jpg")
            try? fileManager.removeItem(at: fileURL)
        } else {
            memoryCache.removeAll()
            try? fileManager.removeItem(at: cacheDirectory)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}
