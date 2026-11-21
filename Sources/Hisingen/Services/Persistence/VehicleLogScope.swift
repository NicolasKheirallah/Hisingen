import CryptoKit
import Foundation

/// The partition of the API diagnostic log an exchange belongs to.
///
/// A vehicle request names its VIN; an account-level flow (sign-in, token, discovery) says
/// `.account` rather than inheriting the wrong log by omission. Every caller declares its
/// scope explicitly at the transport seam so the diagnostic log can group entries by the
/// account or by one vehicle without either side guessing from the URL.
enum VehicleLogScope: Sendable, Equatable {
    case account
    case vehicle(String)

    /// The log-safe label for the partition. A vehicle is named by a digest, never by the VIN
    /// itself: the diagnostic log deliberately scrubs VINs from bodies and URLs, and the
    /// partition key must not become a second place the identifier leaks into a support
    /// export. Account-level flows say `account`.
    var logPartition: String {
        switch self {
        case .account:
            return "account"
        case .vehicle(let vin):
            let digest = SHA256.hash(data: Data(vin.normalizedVIN.utf8))
            let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "vehicle-" + hex
        }
    }
}
