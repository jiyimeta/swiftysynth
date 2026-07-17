import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. `Modulator.discardData` — the canonical parse-and-discard
/// (`Modulator.cs DiscardData`): each pmod/imod record is 10 bytes; the
/// chunk is size-validated and skipped, never surfaced. Font-level behavior
/// (valid pmod/imod chunks in a full font) is covered by
/// SyntheticSoundFontTests and G1.
struct ModulatorTests {
    @Test func discardsWholeRecordsBySkipping() throws {
        let reader = BinaryReader(data: Data(repeating: 0xAB, count: 25))
        try Modulator.discardData(reader: reader, size: 20)
        #expect(reader.position == 20)
    }

    @Test func zeroSizeIsValidAndSkipsNothing() throws {
        let reader = BinaryReader(data: Data(repeating: 0, count: 4))
        try Modulator.discardData(reader: reader, size: 0)
        #expect(reader.position == 0)
    }

    /// C#: "The modulator list is invalid." on a partial record.
    @Test func partialRecordSizeThrowsInvalidSoundFont() {
        let reader = BinaryReader(data: Data(repeating: 0, count: 25))
        #expect(throws: SwiftySynthError.self) {
            try Modulator.discardData(reader: reader, size: 15)
        }
        #expect(reader.position == 0, "nothing consumed on rejection")
    }

    /// A size past the end of the data throws (from BinaryReader.skip) —
    /// truncation never traps.
    @Test func truncatedChunkThrows() {
        let reader = BinaryReader(data: Data(repeating: 0, count: 5))
        #expect(throws: SwiftySynthError.self) {
            try Modulator.discardData(reader: reader, size: 10)
        }
    }
}
