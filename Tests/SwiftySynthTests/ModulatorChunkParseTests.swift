import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. `Modulator.readAll` — the `pmod`/`imod` sub-chunk reader that replaces
/// `Modulator.discardData` (full-port spec §2, Task 5): every 10-byte record is now decoded
/// (`Modulator.read`) into an array instead of skipped. A missing sub-chunk is
/// `SoundFontParameters`'s concern (it simply never calls this), not this reader's — covered at the
/// font level by Task 11's load-compat suite, not here.
struct ModulatorChunkParseTests {
    /// Builds one 10-byte imod/pmod record: srcOper, destOper (generator), amount, amtSrcOper,
    /// transform. Same byte-record pattern as `ModulatorDecodeTests.record`.
    private func record(src: UInt16, dest: UInt16, amount: Int16, amtSrc: UInt16, transform: UInt16)
        -> Data
    {
        var w = ByteWriter()
        w.u16(src)
        w.u16(dest)
        w.i16(amount)
        w.u16(amtSrc)
        w.u16(transform)
        return w.data
    }

    /// Two records back-to-back parse into two decoded `Modulator` values.
    @Test func readsAllRecords() throws {
        var data = Data()
        data.append(record(src: 0x0502, dest: 48, amount: 960, amtSrc: 0, transform: 0))
        data.append(record(src: 0x0002, dest: 48, amount: 100, amtSrc: 0, transform: 0))

        let mods = try Modulator.readAll(from: BinaryReader(data: data), size: data.count)

        #expect(mods.count == 2)
    }

    /// A chunk size that is not a whole number of 10-byte records throws, never trapping.
    @Test func badSizeThrows() {
        #expect(throws: SwiftySynthError.self) {
            try Modulator.readAll(from: BinaryReader(data: Data([0, 0, 0])), size: 3)
        }
    }

    /// A negative size (corrupt chunk length) is rejected up front, mirroring `ZoneInfo.create`'s
    /// `size >= 0` guard — it must never build an inverted range and trap.
    @Test func negativeSizeThrows() {
        #expect(throws: SwiftySynthError.self) {
            try Modulator.readAll(from: BinaryReader(data: Data()), size: -10)
        }
    }
}
