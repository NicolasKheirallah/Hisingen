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
        if let mem = memoryCache[key] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            lock.lock()
            memoryCache[key] = data
            lock.unlock()
            return data
        }

        return nil
    }

    private func write(_ data: Data, key: String) {
        guard !data.isEmpty else { return }

        lock.lock()
        memoryCache[key] = data
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear(for vin: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let vin {
            let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            memoryCache = memoryCache.filter { !$0.key.hasPrefix(cleanVIN) }
            if let items = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                for fileURL in items where fileURL.lastPathComponent.hasPrefix(cleanVIN) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } else {
            memoryCache.removeAll()
            try? fileManager.removeItem(at: cacheDirectory)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}
