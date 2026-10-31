import Foundation

struct PolestarArtworkLoader {
    private(set) var displayed: [String: Data] = [:]
    private var angles: [String: Int] = [:]
    private var requests: [String: UUID] = [:]

    mutating func begin(vin: String) -> UUID {
        let id = UUID()
        requests[vin] = id
        return id
    }

    mutating func select(vin: String, angle: Int, request: UUID, cached: Data?) -> Bool {
        guard requests[vin] == request else { return false }
        if angles[vin] != angle { displayed[vin] = nil }
        if let cached {
            displayed[vin] = cached
            angles[vin] = angle
        }
        return true
    }

    func needsImage(vin: String, angle: Int) -> Bool {
        angles[vin] != angle || displayed[vin] == nil
    }

    mutating func adopt(_ data: Data, vin: String, angle: Int, request: UUID) -> Bool {
        guard requests[vin] == request else { return false }
        displayed[vin] = data
        angles[vin] = angle
        return true
    }

    mutating func reset() {
        displayed.removeAll()
        angles.removeAll()
        requests.removeAll()
    }
}
