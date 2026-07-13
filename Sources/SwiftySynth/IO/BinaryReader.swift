import Foundation

/// Errors surfaced while loading a SoundFont or validating synthesis settings.
///
/// A malformed font (or an out-of-range setting) must never trap the host
/// app: every out-of-bounds read (the Swift analogue of .NET's
/// `EndOfStreamException`) is reported as `.unexpectedEndOfData`, structural
/// violations as `.invalidSoundFont`, and settings-range violations (C#'s
/// `ArgumentOutOfRangeException`) as `.invalidSettings`.
public enum SwiftySynthError: Error, CustomStringConvertible {
    case unexpectedEndOfData
    case invalidSoundFont(String)
    case invalidSettings(String)

    public var description: String {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of data."
        case .invalidSoundFont(let message):
            return message
        case .invalidSettings(let message):
            return message
        }
    }
}

/// A little-endian byte cursor over `Data`.
///
/// Ported from `BinaryReaderEx.cs` (MeltySynth, MIT License — see NOTICE),
/// plus the implicit little-endian primitives of .NET `System.IO.BinaryReader`
/// that `BinaryReaderEx`'s extension methods build on.
final class BinaryReader {
    private let bytes: [UInt8]
    private(set) var position: Int

    init(data: Data) {
        self.bytes = [UInt8](data)
        self.position = 0
    }

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
