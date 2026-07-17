import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. The three BinaryReaderEx.cs primitives SMF parsing needs:
/// big-endian 16/32-bit words and the MIDI variable-length quantity
/// (≤ 4 bytes, high bit = continuation). The ByteWriter builders added
/// alongside are exercised by round-tripping through the reader.
struct BinaryReaderMidiTests {
    private func reader(_ build: (inout ByteWriter) -> Void) -> BinaryReader {
        var writer = ByteWriter()
        build(&writer)
        return BinaryReader(data: writer.data)
    }

    @Test func bigEndianWordsDecode() throws {
        let r = reader {
            $0.u16be(0x0001)
            $0.u16be(0x01E0)          // 480 — the fixture resolution
            $0.u32be(0x0000_0006)
            $0.u16be(0xFFFF)          // -1 as Int16 (sign carried through)
            $0.u32be(0xFFFF_FFFE)     // -2 as Int32
        }
        #expect(try r.readInt16BigEndian() == 1)
        #expect(try r.readInt16BigEndian() == 480)
        #expect(try r.readInt32BigEndian() == 6)
        #expect(try r.readInt16BigEndian() == -1)
        #expect(try r.readInt32BigEndian() == -2)
    }

    @Test func variableLengthQuantitiesDecode() throws {
        let r = reader {
            $0.vlq(0)            // 00
            $0.vlq(127)          // 7F
            $0.vlq(128)          // 81 00
            $0.vlq(960)          // 87 40 — the fixture's common delta
            $0.vlq(0x0FFF_FFFF)  // FF FF FF 7F — the 4-byte maximum
        }
        #expect(try r.readIntVariableLength() == 0)
        #expect(try r.readIntVariableLength() == 127)
        #expect(try r.readIntVariableLength() == 128)
        #expect(try r.readIntVariableLength() == 960)
        #expect(try r.readIntVariableLength() == 0x0FFF_FFFF)
    }

    /// C# ReadIntVariableLength throws once a 5th byte would be needed:
    /// "The length of the value must be equal to or less than 4."
    @Test func variableLengthQuantityOverFourBytesThrows() {
        let r = BinaryReader(data: Data([0x81, 0x81, 0x81, 0x81, 0x01]))
        #expect(throws: SwiftySynthError.self) {
            _ = try r.readIntVariableLength()
        }
    }

    @Test func truncatedReadsThrowUnexpectedEndOfData() {
        let r = BinaryReader(data: Data([0x01]))
        #expect(throws: SwiftySynthError.self) {
            _ = try r.readInt16BigEndian()
        }
        let r2 = BinaryReader(data: Data([0x81]))   // continuation bit, then EOF
        #expect(throws: SwiftySynthError.self) {
            _ = try r2.readIntVariableLength()
        }
    }
}
