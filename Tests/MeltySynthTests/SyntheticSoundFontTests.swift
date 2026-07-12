import Foundation
import Testing
@testable import MeltySynth

/// Builds a minimal, structurally valid SF2 in memory:
/// 1 preset ("Piano", bank 0, patch 0) → 1 instrument ("TestInst") → 1 sample ("TestSample").
enum SyntheticSF2 {
    static func minimal() -> Data {
        // sdta ------------------------------------------------------------------
        var smpl = ByteWriter()
        for v: Int16 in [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000] { smpl.i16(v) }
        var sdta = ByteWriter()
        sdta.fourCC("sdta")
        sdta.chunk("smpl", smpl)

        // INFO ------------------------------------------------------------------
        var ifil = ByteWriter()
        ifil.u16(2); ifil.u16(1)
        var inam = ByteWriter()
        inam.fixedString("Test Font", length: 10)
        var info = ByteWriter()
        info.fourCC("INFO")
        info.chunk("ifil", ifil)
        info.chunk("INAM", inam)

        // pdta ------------------------------------------------------------------
        var phdr = ByteWriter()
        phdr.fixedString("Piano", length: 20)
        phdr.u16(0); phdr.u16(0); phdr.u16(0)          // patch, bank, bagIndex
        phdr.u32(0); phdr.u32(0); phdr.u32(0)          // library, genre, morphology
        phdr.fixedString("EOP", length: 20)            // terminal
        phdr.u16(0); phdr.u16(0); phdr.u16(1)
        phdr.u32(0); phdr.u32(0); phdr.u32(0)

        var pbag = ByteWriter()
        pbag.u16(0); pbag.u16(0)                       // zone 0 → generator 0
        pbag.u16(1); pbag.u16(0)                       // terminal → 1 real pgen record

        var pmod = ByteWriter()
        pmod.bytes([UInt8](repeating: 0, count: 10))   // terminal modulator record only

        var pgen = ByteWriter()
        pgen.u16(41); pgen.u16(0)                      // instrument = 0
        pgen.u16(0); pgen.u16(0)                       // terminal

        var inst = ByteWriter()
        inst.fixedString("TestInst", length: 20); inst.u16(0)
        inst.fixedString("EOI", length: 20); inst.u16(1)

        var ibag = ByteWriter()
        ibag.u16(0); ibag.u16(0)
        ibag.u16(1); ibag.u16(0)

        var imod = ByteWriter()
        imod.bytes([UInt8](repeating: 0, count: 10))

        var igen = ByteWriter()
        igen.u16(53); igen.u16(0)                      // sampleID = 0
        igen.u16(0); igen.u16(0)                       // terminal

        var shdr = ByteWriter()
        shdr.fixedString("TestSample", length: 20)
        shdr.u32(0); shdr.u32(8); shdr.u32(2); shdr.u32(6)
        shdr.u32(44_100); shdr.u8(60); shdr.i8(0); shdr.u16(0); shdr.u16(1)
        shdr.fixedString("EOS", length: 20)            // terminal (46 bytes total)
        shdr.bytes([UInt8](repeating: 0, count: 26))

        var pdta = ByteWriter()
        pdta.fourCC("pdta")
        pdta.chunk("phdr", phdr)
        pdta.chunk("pbag", pbag)
        pdta.chunk("pmod", pmod)
        pdta.chunk("pgen", pgen)
        pdta.chunk("inst", inst)
        pdta.chunk("ibag", ibag)
        pdta.chunk("imod", imod)
        pdta.chunk("igen", igen)
        pdta.chunk("shdr", shdr)

        // RIFF ------------------------------------------------------------------
        var riffBody = ByteWriter()
        riffBody.fourCC("sfbk")
        riffBody.list(info)
        riffBody.list(sdta)
        riffBody.list(pdta)
        var out = ByteWriter()
        out.fourCC("RIFF")
        out.u32(UInt32(riffBody.data.count))
        out.append(riffBody)
        return out.data
    }
}

struct SyntheticSoundFontTests {
    @Test func loadsMinimalFontEndToEnd() throws {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        #expect(font.info.version.major == 2)
        #expect(font.info.version.minor == 1)
        #expect(font.info.bankName == "Test Font")
        #expect(font.bitsPerSample == 16)
        #expect(font.waveData == [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000])
        #expect(font.presets.count == 1)
        #expect(font.instruments.count == 1)
        #expect(font.sampleHeaders.count == 1)

        let preset = font.presets[0]
        #expect(preset.name == "Piano")
        #expect(preset.bankNumber == 0)
        #expect(preset.patchNumber == 0)
        #expect(preset.regions.count == 1)
        #expect(preset.regions[0].instrument === font.instruments[0])

        let instrument = font.instruments[0]
        #expect(instrument.name == "TestInst")
        #expect(instrument.regions.count == 1)
        #expect(instrument.regions[0].sample === font.sampleHeaders[0])
        #expect(instrument.regions[0].sampleStart == 0)
        #expect(instrument.regions[0].sampleEndLoop == 6)
    }

    @Test func rejectsNonSoundFontData() {
        #expect(throws: MeltySynthError.self) {
            _ = try SoundFont(data: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
        }
    }
}
