import Foundation

/// Which log a recorded API exchange belongs to.
///
/// The transport seams build this from the vehicle the request is for. Account-level traffic
/// (sign-in, token grants, discovery) carries `.account`, so a per-vehicle view never claims
/// it. Both cases collapse into an `APILogPartitionKey`, which is what storage, the inspector
/// and the support export name parts of the log by.
enum VehicleLogScope: Hashable, Sendable {
    /// Traffic that belongs to the signed-in account rather than one car: token grants,
    /// sign-in windows, vehicle discovery, update checks.
    case account
    case vehicle(String)

    /// The storage identity of the scope. The VIN is normalized and hashed here and never
    /// reaches the archive; an empty VIN is not a vehicle and falls back to the account.
    var partitionKey: APILogPartitionKey {
        guard case .vehicle(let vin) = self else { return .account }
        return .vehicle(vin)
    }
}

/// Stable identity of one partition of the API diagnostic log.
///
/// The raw value is stored on disk and appears in support exports, so it must not identify a
/// vehicle. `account` and `legacy` are fixed; a vehicle is `vehicle-` plus a truncated SHA-256
/// digest of its VIN. The digest is unsalted on purpose: a per-install salt would make every
/// partition key change at launch, and the archive has to survive relaunches.
struct APILogPartitionKey: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let account = APILogPartitionKey(rawValue: "account")
    /// Rows written by the single-log format that predates per-vehicle partitions. They carry
    /// no vehicle, so they are neither guessed at nor merged into a car; the 24-hour window
    /// retires them.
    static let legacy = APILogPartitionKey(rawValue: "legacy")

    /// Sixty-four bits of SHA-256. Collision risk across a garage is negligible, and a shorter
    /// digest would let two cars silently share a partition.
    static func vehicle(_ vin: String) -> APILogPartitionKey {
        let normalized = vin.normalizedVIN
        guard !normalized.isEmpty else { return .account }
        return APILogPartitionKey(rawValue: VehicleOpaqueIdentifier.value(for: normalized, byteCount: 8))
    }

    var isAccount: Bool { rawValue == Self.account.rawValue }
    var isLegacy: Bool { rawValue == Self.legacy.rawValue }
    var isVehicle: Bool { rawValue.hasPrefix("vehicle-") }
}

/// One vehicle's slice of the diagnostic log, oldest entry first.
struct APILogPartition: Identifiable, Sendable {
    let key: APILogPartitionKey
    let entries: [APILogEntry]

    var id: String { key.rawValue }
    var newestEntryDate: Date? { entries.last?.timestamp }
    var oldestEntryDate: Date? { entries.first?.timestamp }
    var requestCount: Int { entries.count }
}
