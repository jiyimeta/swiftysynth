import Testing
@testable import SwiftySynth

struct ChunkParserTests {
    @Test func parsesSampleHeaderRecord() throws {
        var w = ByteWriter()
        w.fixedString("TestSample", length: 20)
        w.u32(0)        // start
        w.u32(8)        // end
        w.u32(2)        // startLoop
        w.u32(6)        // endLoop
        w.u32(44_100)   // sampleRate
        w.u8(60)        // originalPitch
        w.i8(-5)        // pitchCorrection
        w.u16(0)        // link
        w.u16(1)        // sampleType (mono)
        let h = try SampleHeader(reader: BinaryReader(data: w.data))
        #expect(h.name == "TestSample")
        #expect(h.start == 0)
        #expect(h.end == 8)
        #expect(h.startLoop == 2)
        #expect(h.endLoop == 6)
        #expect(h.sampleRate == 44_100)
        #expect(h.originalPitch == 60)
        #expect(h.pitchCorrection == -5)
        #expect(h.link == 0)
        #expect(h.sampleType == 1)
    }

    @Test func parsesInfoList() throws {
        var body = ByteWriter()
        body.fourCC("INFO")
        var ifil = ByteWriter()
        ifil.u16(2); ifil.u16(1)
        body.chunk("ifil", ifil)
        var inam = ByteWriter()
        inam.fixedString("Test Font", length: 10)   // 9 chars + NUL, even size
        body.chunk("INAM", inam)
        var icop = ByteWriter()
        icop.fixedString("(c) nobody", length: 12)
        body.chunk("ICOP", icop)
        var w = ByteWriter()
        w.list(body)

        let info = try SoundFontInfo(reader: BinaryReader(data: w.data))
        #expect(info.version.major == 2)
        #expect(info.version.minor == 1)
        #expect(info.bankName == "Test Font")
        #expect(info.copyright == "(c) nobody")
        #expect(info.author == "")   // absent chunks default to empty strings
    }

    @Test func parsesSampleDataAndSkipsSm24() throws {
        var smpl = ByteWriter()
        for v: Int16 in [1000, -1000, 32_767, -32_768] { smpl.i16(v) }
        var body = ByteWriter()
        body.fourCC("sdta")
        body.chunk("smpl", smpl)
        var sm24 = ByteWriter()
        sm24.bytes([0, 0, 0, 0])     // 24-bit extension — must be detected and skipped
        body.chunk("sm24", sm24)
        var w = ByteWriter()
        w.list(body)

        let data = try SoundFontSampleData(reader: BinaryReader(data: w.data))
        #expect(data.bitsPerSample == 16)
        #expect(data.samples == [1000, -1000, 32_767, -32_768])
    }

    @Test func sampleDataRequiresSmpl() {
        var body = ByteWriter()
        body.fourCC("sdta")
        var w = ByteWriter()
        w.list(body)
        #expect(throws: SwiftySynthError.self) {
            _ = try SoundFontSampleData(reader: BinaryReader(data: w.data))
        }
    }
}
