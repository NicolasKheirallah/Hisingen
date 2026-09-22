import Foundation
@testable import Hisingen

// Fixture-side encoders for wire types production code only decodes. Requests the app
// builds never carry doubles, so `Protobuf.doubleField` lives here with the tests that
// use it to assemble canned gRPC payloads.
extension Protobuf {
    static func doubleField(_ number: Int, _ value: Double) -> Data {
        var out = varint(UInt64(number << 3 | 1))
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        return out
    }
}
