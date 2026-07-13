import Foundation

/// Builds little-endian synthetic byte blobs for parser tests.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func i8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        u16(UInt16(v & 0xFFFF))
        u16(UInt16(v >> 16))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourCC(_ s: String) {
        precondition(s.utf8.count == 4)
        data.append(contentsOf: s.utf8)
    }
    mutating func fixedString(_ s: String, length: Int) {
        let bytes = Array(s.utf8)
        precondition(bytes.count <= length)
        data.append(contentsOf: bytes)
        data.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
    }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func append(_ other: ByteWriter) { data.append(other.data) }
    /// RIFF sub-chunk: fourCC + u32 size + body.
    mutating func chunk(_ id: String, _ body: ByteWriter) {
        fourCC(id)
        u32(UInt32(body.data.count))
        append(body)
    }
    /// LIST chunk wrapping a body that starts with its form fourCC.
    mutating func list(_ body: ByteWriter) {
        chunk("LIST", body)
    }
}
