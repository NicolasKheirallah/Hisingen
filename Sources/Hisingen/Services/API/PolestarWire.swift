import Foundation

enum Protobuf {
    static func packedVarints(_ data: Data) -> [UInt64]? {
        var result: [UInt64] = []
        var value: UInt64 = 0
        var shift = 0
        for byte in data {
            guard shift < 64, shift != 63 || byte <= 1 else { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                result.append(value)
                value = 0
                shift = 0
            } else {
                shift += 7
            }
        }
        return shift == 0 ? result : nil
    }

    struct Field {
        let number: Int
        let wire: Int

        let varint: UInt64

        let data: Data
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }


    static func stringField(_ number: Int, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(bytes.count)))
        out.append(bytes)
        return out
    }

    static func intField(_ number: Int, _ value: Int) -> Data {
        var out = varint(UInt64(number << 3))
        out.append(varint(UInt64(bitPattern: Int64(value))))
        return out
    }

    static func floatField(_ number: Int, _ value: Float) -> Data {
        var out = varint(UInt64(number << 3 | 5))
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        return out
    }

    static func packedIntField(_ number: Int, _ values: [Int]) -> Data {
        var payload = Data()
        for value in values { payload.append(varint(UInt64(value))) }
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    static func messageField(_ number: Int, _ value: Data) -> Data {
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(value.count)))
        out.append(value)
        return out
    }


    static func grpcFrame(_ message: Data) -> Data {
        var out = Data([0])
        let n = UInt32(message.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(message)
        return out
    }


    /// Why a payload failed strict decoding. `offset` is the byte where the bad field starts.
    enum DecodeError: Error, Equatable {
        case truncated(offset: Int)
        case invalidFieldNumber(offset: Int)
        case unsupportedWireType(Int, offset: Int)
    }

    /// Strict decode of one message level: any truncated or malformed field throws. Use this
    /// wherever a partial result could be shown as a real vehicle state.
    static func decode(_ data: Data) throws -> [Field] {
        let (fields, failure) = scan(data)
        if let failure { throw failure }
        return fields
    }

    /// Nonthrowing compatibility decode. Malformed input yields no fields.
    static func fields(_ data: Data) -> [Field] {
        (try? decode(data)) ?? []
    }

    private static func scan(_ data: Data) -> (fields: [Field], failure: DecodeError?) {
        var fields: [Field] = []
        let base = data.startIndex
        let end = data.endIndex
        var i = base

        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < end, shift < 64 {
                let b = data[i]; i += 1
                if shift == 63 && b > 1 { return nil }
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < end {
            let start = i - base
            // Wire values are server-controlled: a tag or length varint beyond Int's range
            // must stop the parse, not trap.
            guard let tag = readVarint() else { return (fields, .truncated(offset: start)) }
            guard let number = Int(exactly: tag >> 3), number > 0, number <= 536_870_911 else {
                return (fields, .invalidFieldNumber(offset: start))
            }
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return (fields, .truncated(offset: start)) }
                fields.append(Field(number: number, wire: 0, varint: v, data: Data()))
            case 1, 5:
                let width = wire == 1 ? 8 : 4
                guard end - i >= width else { return (fields, .truncated(offset: start)) }
                fields.append(Field(number: number, wire: wire, varint: 0, data: Data(data[i..<i + width])))
                i += width
            case 2:
                guard let len = readVarint(), let length = Int(exactly: len), length <= end - i else {
                    return (fields, .truncated(offset: start))
                }
                fields.append(Field(number: number, wire: 2, varint: 0, data: Data(data[i..<i + length])))
                i += length
            default:
                // Groups (3, 4) are proto2-only and never seen from these services.
                return (fields, .unsupportedWireType(wire, offset: start))
            }
        }
        return (fields, nil)
    }

    static func double(from data: Data) -> Double? {
        guard data.count == 8 else { return nil }
        let bytes = [UInt8](data)
        var bits: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            bits |= UInt64(byte) << UInt64(index * 8)
        }
        return Double(bitPattern: bits)
    }

    static func float(from data: Data) -> Float? {
        guard data.count == 4 else { return nil }
        let bytes = [UInt8](data)
        var bits: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            bits |= UInt32(byte) << UInt32(index * 8)
        }
        return Float(bitPattern: bits)
    }
}



/// One strictly decoded message level with wire-type-checked accessors. A field read with the
/// wrong wire type is absent rather than misread, and repeated scalars resolve to the last
/// occurrence, as proto3 specifies.
struct ProtoMessage {
    let fields: [Protobuf.Field]

    init(_ data: Data) throws {
        fields = try Protobuf.decode(data)
    }

    func field(_ number: Int, wire: Int) -> Protobuf.Field? {
        fields.last { $0.number == number && $0.wire == wire }
    }

    func uint(_ number: Int) -> UInt64? { field(number, wire: 0)?.varint }

    func int(_ number: Int) -> Int? { uint(number).flatMap { Int(exactly: $0) } }

    func double(_ number: Int) -> Double? {
        field(number, wire: 1).flatMap { Protobuf.double(from: $0.data) }
    }

    func bytes(_ number: Int) -> Data? { field(number, wire: 2)?.data }

    func message(_ number: Int) throws -> ProtoMessage? {
        try bytes(number).map(ProtoMessage.init)
    }

    /// Seconds of a nested `google.protobuf.Timestamp` (field 1 of the sub-message), nil when
    /// absent or zero.
    func timestamp(_ number: Int) throws -> Date? {
        guard let seconds = try message(number)?.uint(1), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}


/// Splits a gRPC response body into its length-prefixed messages: a flag byte, a 4-byte
/// big-endian length, then the message.
struct GRPCFrameReader {
    static let maxFrameBytes = 2_000_000
    /// Largest run of bytes staged before it is handed to the reader. Bounds the staging
    /// buffer, not the size of a message.
    static let stagingBytes = 16 * 1_024

    /// Names the call in errors: "compressed \(context) frame".
    let context: String
    private var header: [UInt8] = []
    private var body: [UInt8] = []
    private var expected: Int?

    init(context: String) {
        self.context = context
        header.reserveCapacity(5)
    }

    /// True when any header or body bytes remain incomplete.
    var isReadingBody: Bool { expected != nil || !header.isEmpty }

    /// Bytes still needed to finish the header or body in progress.
    private var bytesNeeded: Int {
        if let size = expected { return size - body.count }
        return 5 - header.count
    }

    /// Reads messages from `bytes`, calling `onMessage` as soon as each one's last byte
    /// arrives. Returns early when `onMessage` returns false.
    ///
    /// Bytes are staged in one reusable buffer and handed over in runs that never reach past
    /// the message in progress, so a run completes a message on its final byte instead of
    /// waiting for the buffer to fill. Cancellation is checked before each run, which means at
    /// least once per message.
    mutating func readMessages<Stream: AsyncSequence>(
        from bytes: Stream,
        isolation: isolated (any Actor)? = #isolation,
        onMessage: (Data) throws -> Bool
    ) async throws where Stream.Element == UInt8 {
        var staged: [UInt8] = []
        staged.reserveCapacity(Self.stagingBytes)
        var runLength = min(bytesNeeded, Self.stagingBytes)
        do {
            for try await byte in bytes {
                staged.append(byte)
                guard staged.count == runLength else { continue }
                try Task.checkCancellation()
                let message = try feed(staged)
                staged.removeAll(keepingCapacity: true)
                runLength = min(bytesNeeded, Self.stagingBytes)
                if let message {
                    guard try onMessage(message) else { return }
                }
            }
        } catch {
            if !staged.isEmpty, staged.count < runLength { _ = try feed(staged) }
            throw error
        }
        // A partial run cannot complete a message, but the reader still needs it so that
        // `isReadingBody` reflects the bytes that arrived.
        if !staged.isEmpty { _ = try feed(staged) }
    }

    /// Returns a message when `byte` completes one, including an empty message.
    mutating func consume(_ byte: UInt8) throws -> Data? {
        try feed([byte])
    }

    /// Takes a run that ends no later than the message in progress, so at most one message
    /// completes per run.
    private mutating func feed(_ run: [UInt8]) throws -> Data? {
        if let size = expected {
            body.append(contentsOf: run)
            return body.count == size ? finishFrame() : nil
        }
        header.append(contentsOf: run)
        guard header.count == 5 else { return nil }
        // Requests advertise `grpc-accept-encoding: identity`, so a compressed frame means
        // the server ignored it.
        guard header[0] == 0 else {
            throw PolestarError.incompatibleAPI(operation: "compressed \(context) frame")
        }
        let size = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
        guard size <= Self.maxFrameBytes else {
            throw PolestarError.invalidResponse(operation: "oversized \(context) frame")
        }
        if size == 0 { return finishFrame() }
        expected = size
        body.reserveCapacity(size)
        return nil
    }

    private mutating func finishFrame() -> Data {
        let frame = Data(body)
        header.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        expected = nil
        return frame
    }
}
