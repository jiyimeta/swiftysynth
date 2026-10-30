import Foundation
import Testing
@testable import SwiftySynth

struct BinaryReaderTests {
    @Test func readsLittleEndianPrimitives() throws {
        var w = ByteWriter()
        w.u8(0xAB)
        w.i8(-2)
        w.u16(0x1234)
        w.i16(-1000)
        w.u32(0xDEAD_BEEF)
        w.i32(-123_456_789)
        let reader = BinaryReader(data: w.data)
        #expect(try reader.readUInt8() == 0xAB)
        #expect(try reader.readInt8() == -2)
        #expect(try reader.readUInt16() == 0x1234)
        #expect(try reader.readInt16() == -1000)
        #expect(try reader.readUInt32() == 0xDEAD_BEEF)
        #expect(try reader.readInt32() == -123_456_789)
        #expect(reader.position == 14)
    }

    /// `Data` of up to 14 bytes keeps its bytes inline in the value, and `withUnsafeBytes` hands the closure a pointer
    /// to a temporary copy that is dead once the closure returns, so the reader must copy the bytes inside it. Only an
    /// optimized build reuses that memory, so a pointer escaping the closure shows up under `swift test -c release`.
    @Test(arguments: 1...14) func readerOverInlineDataReadsItsOwnBytes(count: Int) throws {
        let expected = (0..<count).map { UInt8(0xA0 + $0) }
        let reader = BinaryReader(data: Data(expected))
        var actual: [UInt8] = []
        for _ in 0..<count {
            actual.append(try reader.readUInt8())
        }
        #expect(actual == expected)
    }

    @Test func readsFourCCAndFixedLengthStrings() throws {
        var w = ByteWriter()
        w.fourCC("RIFF")
        w.fixedString("Piano", length: 20)
        let reader = BinaryReader(data: w.data)
        #expect(try reader.readFourCC() == "RIFF")
        // Fixed-length strings trim at the first NUL, mirroring BinaryReaderEx.cs.
        #expect(try reader.readFixedLengthString(20) == "Piano")
        #expect(reader.position == 24)
    }

    @Test func throwsOnTruncatedData() {
        let reader = BinaryReader(data: Data([0x01]))
        #expect(throws: SwiftySynthError.self) { _ = try reader.readUInt32() }
    }

    @Test func skipAdvancesAndBoundsChecks() throws {
        let reader = BinaryReader(data: Data(repeating: 0, count: 10))
        try reader.skip(6)
        #expect(reader.position == 6)
        #expect(throws: SwiftySynthError.self) { try reader.skip(5) }
    }

    /// Item E: `bytesRemaining` tracks the cursor, used by chunk parsers to
    /// clamp `reserveCapacity` against attacker-controlled sizes.
    @Test func bytesRemainingTracksTheCursor() throws {
        let reader = BinaryReader(data: Data(repeating: 0, count: 6))
        #expect(reader.bytesRemaining == 6)
        _ = try reader.readUInt32()
        #expect(reader.bytesRemaining == 2)
    }
}
