import Foundation

/// One undecoded protobuf field from a provider response, preserved so nothing on the wire
/// disappears silently. Semantics are intentionally unknown – values are shown raw in the
/// diagnostics surfaces and reclassified as they are identified by live probing. The type is
/// brand-neutral on purpose: the Polestar gRPC engine produces these today, and the domain
/// carries them through persisted snapshots and Codable round-trips regardless of producer.
struct VehicleRawWireField: Codable, Equatable, Sendable {
    let field: Int
    /// Parent message number when the field lives inside a known sub-message (e.g. `35` for
    /// the `GetMyCars` charging settings), `nil` for top-level fields.
    var subfield: Int? = nil
    let wire: Int
    let value: String
    /// True when `value` is a hex dump of the bytes rather than a decoded scalar.
    let isBinary: Bool
}
