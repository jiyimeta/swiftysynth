import Foundation
import Testing
@testable import SwiftySynth

struct GeneratorZoneTests {
    @Test func generatorParsesTypeAndRawValue() throws {
        var w = ByteWriter()
        w.u16(48)     // initialAttenuation
        w.u16(0xFF9C) // Int16 bit pattern for -100 — must round-trip as a bit pattern
        let g = try Generator(reader: BinaryReader(data: w.data))
        #expect(g.type == .initialAttenuation)
        #expect(g.value == 0xFF9C)
        #expect(Int16(bitPattern: g.value) == -100)
    }

    /// Item B: a raw wire type outside `0...60` (`GeneratorType`'s range) has
    /// no matching case — `Generator.init(reader:)` must store it as a `nil`
    /// type (SF2 §9.4 "unknown generators are ignored") instead of throwing,
    /// while still preserving the raw `value`.
    @Test func generatorWithOutOfRangeRawTypeIsNilNotThrown() throws {
        var w = ByteWriter()
        w.u16(61)      // one past the last defined case (unusedEnd = 60)
        w.u16(0x1234)
        let g = try Generator(reader: BinaryReader(data: w.data))
        #expect(g.type == nil)
        #expect(g.value == 0x1234)
    }

    @Test func readFromChunkDropsTheTerminalRecord() throws {
        var w = ByteWriter()
        w.u16(41); w.u16(2)   // instrument = 2
        w.u16(48); w.u16(10)  // initialAttenuation = 10
        w.u16(0); w.u16(0)    // terminal record — must be dropped
        let gens = try Generator.readFromChunk(reader: BinaryReader(data: w.data), size: 12)
        #expect(gens.count == 2)
        #expect(gens[0].type == .instrument)
        #expect(gens[1].type == .initialAttenuation)
    }

    @Test func zoneInfoComputesCountsFromConsecutiveIndices() throws {
        var w = ByteWriter()
        for (g, m) in [(0, 0), (2, 0), (3, 1), (5, 2)] {  // last record is the terminal
            w.u16(UInt16(g)); w.u16(UInt16(m))
        }
        let infos = try ZoneInfo.create(reader: BinaryReader(data: w.data), size: 16)
        #expect(infos.count == 4)
        #expect(infos[0].generatorIndex == 0)
        #expect(infos[0].generatorCount == 2)
        #expect(infos[1].generatorCount == 1)
        #expect(infos[2].generatorCount == 2)
        #expect(infos[2].modulatorCount == 1)
    }

    @Test func zoneCreateSlicesGeneratorsByBagIndices() throws {
        var w = ByteWriter()
        for (g, m) in [(0, 0), (2, 0), (3, 0), (5, 0)] {
            w.u16(UInt16(g)); w.u16(UInt16(m))
        }
        let infos = try ZoneInfo.create(reader: BinaryReader(data: w.data), size: 16)
        let gens = (0..<5).map { Generator(type: .startAddressOffset, value: UInt16($0)) }
        let zones = try Zone.create(infos: infos, generators: gens)
        #expect(zones.count == 3) // terminal info produces no zone
        #expect(zones[0].generators.map(\.value) == [0, 1])
        #expect(zones[1].generators.map(\.value) == [2])
        #expect(zones[2].generators.map(\.value) == [3, 4])
    }

    @Test func zoneCreateRequiresARealZone() throws {
        var w = ByteWriter()
        w.u16(0); w.u16(0) // terminal only
        let infos = try ZoneInfo.create(reader: BinaryReader(data: w.data), size: 4)
        #expect(throws: SwiftySynthError.self) {
            _ = try Zone.create(infos: infos, generators: [])
        }
    }

    @Test func readFromChunkRejectsZeroLengthChunkWithoutTrapping() {
        // size == 0 passes the `% 4` check but would make `0..<(size/4 - 1)`
        // an inverted range and trap; it must throw a catchable error instead.
        #expect(throws: SwiftySynthError.self) {
            _ = try Generator.readFromChunk(reader: BinaryReader(data: Data()), size: 0)
        }
    }

    @Test func zoneCreateRejectsOutOfRangeBagIndicesWithoutTrapping() throws {
        var w = ByteWriter()
        // First record's generatorCount = 5 - 0 = 5, but we supply only two
        // generators, so start + count (5) runs past the end and would trap
        // the slice subscript; it must throw a catchable error instead.
        for (g, m) in [(0, 0), (5, 0)] {  // second record is the terminal
            w.u16(UInt16(g)); w.u16(UInt16(m))
        }
        let infos = try ZoneInfo.create(reader: BinaryReader(data: w.data), size: 8)
        let gens = (0..<2).map { Generator(type: .startAddressOffset, value: UInt16($0)) }
        #expect(throws: SwiftySynthError.self) {
            _ = try Zone.create(infos: infos, generators: gens)
        }
    }

    @Test func loopModeWireMapping() {
        #expect(LoopMode(rawValue: 0) == .noLoop)
        #expect(LoopMode(rawValue: 1) == .continuous)
        #expect(LoopMode(rawValue: 3) == .loopUntilNoteOff)
        #expect(LoopMode(rawValue: 2) == nil) // regions map wire value 2 → .noLoop (Task 10)
    }
}
