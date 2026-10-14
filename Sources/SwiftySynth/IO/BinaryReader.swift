import Foundation

/// Errors surfaced while loading a SoundFont or validating synthesis settings.
///
/// A malformed font (or an out-of-range setting) must never trap the host
/// app: every out-of-bounds read (the Swift analogue of .NET's
/// `EndOfStreamException`) is reported as `.unexpectedEndOfData`, structural
/// violations as `.invalidSoundFont`, settings-range violations (C#'s
/// `ArgumentOutOfRangeException`) as `.invalidSettings`, and structural SMF
/// violations as `.invalidMidiFile`.
public enum SwiftySynthError: Error, CustomStringConvertible {
    case unexpectedEndOfData
    case invalidSoundFont(String)
    case invalidSettings(String)
    case invalidMidiFile(String)

    public var description: String {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of data."
        case .invalidSoundFont(let message):
            return message
        case .invalidSettings(let message):
            return message
        case .invalidMidiFile(let message):
            return message
        }
    }
}

/// A little-endian byte cursor over `Data`, or over a mapped file.
///
/// Ported from `BinaryReaderEx.cs` (MeltySynth, MIT License — see NOTICE),
/// plus the implicit little-endian primitives of .NET `System.IO.BinaryReader`
/// that `BinaryReaderEx`'s extension methods build on.
final class BinaryReader {
    /// Keeps `bytes` alive: the `ByteBuffer` copied from `Data`, or the `MappedFile` read in place. A sample pool
    /// read with `readWaveData` holds on to it too.
    private let owner: AnyObject
    private let bytes: UnsafeRawBufferPointer
    private(set) var position: Int

    init(data: Data) {
        let buffer = ByteBuffer(copying: data)
        self.owner = buffer
        self.bytes = buffer.bytes
        self.position = 0
    }

    /// Reads `file` in place: nothing is copied, so a sample pool read from it stays a view of the file.
    init(mappedFile file: MappedFile) {
        self.owner = file
        self.bytes = file.bytes
        self.position = 0
    }

    /// Bytes remaining between the cursor and the end of the data. Chunk
    /// parsers clamp `reserveCapacity` against this so a lying chunk size
    /// cannot force a huge up-front allocation — the read loops themselves
    /// are already EOF-safe and throw before reading past the end.
    var bytesRemaining: Int { bytes.count - position }

    /// Ensures `count` more bytes are available, throwing otherwise.
    private func requireAvailable(_ count: Int) throws {
        if count < 0 || position + count > bytes.count {
            throw SwiftySynthError.unexpectedEndOfData
        }
    }

    func readUInt8() throws -> UInt8 {
        try requireAvailable(1)
        let value = bytes[position]
        position += 1
        return value
    }

    func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    /// Little-endian, matching .NET `BinaryReader.ReadUInt16`.
    func readUInt16() throws -> UInt16 {
        try requireAvailable(2)
        let b0 = UInt16(bytes[position])
        let b1 = UInt16(bytes[position + 1])
        position += 2
        return b0 | (b1 << 8)
    }

    func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    /// Reads `count` little-endian `Int16` values — a SoundFont's `smpl` chunk, one contiguous block of
    /// little-endian PCM — as a view of the bytes under the cursor, with nothing copied. On a little-endian host (every
    /// Apple and Android target) those bytes already ARE the `Int16` values, so the pool is read in place: out of the
    /// file mapping for a font loaded from a file, out of the reader's own buffer for one loaded from `Data`. A chunk at
    /// an odd offset (a malformed font; RIFF pads every chunk to an even size) or a big-endian host gets an aligned,
    /// host-order copy instead, so the result stays correct where C#'s host-endian-sensitive `MemoryMarshal.Cast`
    /// would not. Still EOF-safe: a lying, over-claimed `count` throws rather than trapping, preserving the
    /// never-trap-the-host invariant.
    func readWaveData(count: Int) throws -> WaveData {
        guard count >= 0 else { throw SwiftySynthError.unexpectedEndOfData }
        let byteCount = count * 2
        try requireAvailable(byteCount)
        let chunk = UnsafeRawBufferPointer(rebasing: bytes[position ..< (position + byteCount)])
        position += byteCount
        guard count > 0, let start = chunk.baseAddress else { return .empty }
        #if _endian(little)
        if Int(bitPattern: start) % MemoryLayout<Int16>.alignment == 0 {
            return WaveData(owner: owner, base: start.bindMemory(to: Int16.self, capacity: count), count: count)
        }
        #endif
        let copy = ByteBuffer(copying: chunk)
        let values = UnsafeMutableRawPointer(mutating: copy.bytes.baseAddress.unsafelyUnwrapped)
            .bindMemory(to: Int16.self, capacity: count)
        #if _endian(big)
        for index in 0 ..< count {
            values[index] = Int16(littleEndian: values[index])
        }
        #endif
        return WaveData(owner: copy, base: UnsafePointer(values), count: count)
    }

    /// Little-endian, matching .NET `BinaryReader.ReadUInt32`.
    func readUInt32() throws -> UInt32 {
        try requireAvailable(4)
        let b0 = UInt32(bytes[position])
        let b1 = UInt32(bytes[position + 1])
        let b2 = UInt32(bytes[position + 2])
        let b3 = UInt32(bytes[position + 3])
        position += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// Big-endian, mirroring `BinaryReaderEx.ReadInt16BigEndian`.
    func readInt16BigEndian() throws -> Int16 {
        let b0 = try readUInt8()
        let b1 = try readUInt8()
        return Int16(bitPattern: (UInt16(b0) << 8) | UInt16(b1))
    }

    /// Big-endian, mirroring `BinaryReaderEx.ReadInt32BigEndian`.
    func readInt32BigEndian() throws -> Int32 {
        let b0 = try readUInt8()
        let b1 = try readUInt8()
        let b2 = try readUInt8()
        let b3 = try readUInt8()
        return Int32(bitPattern: (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3))
    }

    /// MIDI variable-length quantity, mirroring
    /// `BinaryReaderEx.ReadIntVariableLength`: 7 data bits per byte,
    /// high bit = continuation, at most 4 bytes (so the result fits in
    /// 28 bits and the shift below cannot overflow).
    func readIntVariableLength() throws -> Int32 {
        var acc: Int32 = 0
        var count = 0
        while true {
            let value = try readUInt8()
            acc = (acc << 7) | Int32(value & 127)
            if (value & 128) == 0 {
                break
            }
            count += 1
            if count == 4 {
                throw SwiftySynthError.invalidMidiFile(
                    "The length of the value must be equal to or less than 4.")
            }
        }
        return acc
    }

    /// Decodes ASCII bytes the way .NET's `Encoding.ASCII.GetString` does:
    /// each byte in `0...127` maps to the matching code point, and any byte
    /// `>= 0x80` (not representable in 7-bit ASCII) becomes `?`.
    private func asciiString<C: Collection>(_ raw: C) -> String where C.Element == UInt8 {
        String(decoding: raw.map { $0 <= 0x7F ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    /// Reads a 4-byte RIFF chunk/form identifier as ASCII, replacing any
    /// non-printable byte with `?`, mirroring `BinaryReaderEx.ReadFourCC`.
    func readFourCC() throws -> String {
        try requireAvailable(4)
        var data = Array(bytes[position..<(position + 4)])
        position += 4
        for i in 0..<data.count {
            let value = data[i]
            if !(32 <= value && value <= 126) {
                data[i] = UInt8(ascii: "?")
            }
        }
        return asciiString(data)
    }

    /// Reads exactly `length` bytes as ASCII, cutting at the first NUL byte,
    /// mirroring `BinaryReaderEx.ReadFixedLengthString`.
    func readFixedLengthString(_ length: Int) throws -> String {
        try requireAvailable(length)
        let data = Array(bytes[position..<(position + length)])
        position += length
        var actualLength = 0
        while actualLength < data.count && data[actualLength] != 0 {
            actualLength += 1
        }
        return asciiString(data[0..<actualLength])
    }

    /// Advances the cursor by `count` bytes without returning them, throwing
    /// if that would move past the end of the data.
    func skip(_ count: Int) throws {
        try requireAvailable(count)
        position += count
    }
}
