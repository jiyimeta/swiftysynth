import Testing
@testable import MeltySynth

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
        #expect(throws: MeltySynthError.self) {
            _ = try Zone.create(infos: infos, generators: [])
        }
    }

    @Test func loopModeWireMapping() {
        #expect(LoopMode(rawValue: 0) == .noLoop)
        #expect(LoopMode(rawValue: 1) == .continuous)
        #expect(LoopMode(rawValue: 3) == .loopUntilNoteOff)
        #expect(LoopMode(rawValue: 2) == nil) // regions map wire value 2 → .noLoop (Task 10)
    }
}
