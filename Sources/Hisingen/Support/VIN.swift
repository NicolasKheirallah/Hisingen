import CryptoKit
import Foundation

extension String {
    /// The one spelling of a VIN used as a key, a SQL bind or a comparison: trimmed and uppercased.
    var normalizedVIN: String { trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}

/// Non-reversible identities derived from a VIN.
///
/// A VIN is a vehicle identifier the app promises never to write into a system index or a
/// support export. Anything that has to name a vehicle outside the app's own per-VIN storage
/// uses a digest instead: stable across launches (a salt would break every relaunch), useless
/// as a VIN.
enum VehicleOpaqueIdentifier {
    /// `vehicle-` followed by `byteCount` SHA-256 bytes in lower-case hex.
    static func value(for vin: String, byteCount: Int = 8) -> String {
        let digest = SHA256.hash(data: Data(vin.normalizedVIN.utf8))
        let hex = digest.prefix(max(1, byteCount)).map { String(format: "%02x", $0) }.joined()
        return "vehicle-" + hex
    }
}
