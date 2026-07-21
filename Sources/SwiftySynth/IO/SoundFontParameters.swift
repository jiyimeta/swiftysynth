/// The parameters of a SoundFont (the `LIST`/`pdta` chunk): sample headers,
/// presets, and instruments.
///
/// Ported from `SoundFontParameters.cs` (MeltySynth, MIT License — see
/// NOTICE). MeltySynth itself never decodes modulator records past the raw
/// bytes; this port reads `pmod`/`imod` into `presetModulators` /
/// `instrumentModulators` (`Modulator.readAll`) instead of discarding them —
/// new plumbing for the optional note-on-modulator feature (full-port spec
/// §2; see `Modulator.swift`). A missing `pmod`/`imod` sub-chunk leaves the
/// corresponding array empty rather than throwing — unlike the other seven
/// sub-chunks, these two intentionally have no mandatory-presence guard
/// (spec §2), matching today's load behavior for fonts that omit them.
final class SoundFontParameters {
    let sampleHeaders: [SampleHeader]
    let presets: [Preset]
    let instruments: [Instrument]
    let presetModulators: [Modulator]
    let instrumentModulators: [Modulator]

    /// Reads the whole `LIST`/`pdta` chunk: fourCC + size + `pdta` form,
    /// then iterates sub-chunks by ID until `size` bytes are consumed.
    /// Mirrors `SoundFontParameters`'s internal constructor exactly,
    /// including its sub-chunk read order (phdr, pbag, pmod, pgen, inst,
    /// ibag, imod, igen, shdr), its missing-mandatory-chunk null checks, and
    /// its post-read assembly order (instrument zones/instruments, then
    /// preset zones/presets).
    init(reader: BinaryReader) throws {
        let chunkId = try reader.readFourCC()
        guard chunkId == "LIST" else {
            throw SwiftySynthError.invalidSoundFont("The LIST chunk was not found.")
        }

        // See SoundFontInfo.swift for why widening this Int32 chunk size to
        // Int can never overflow/trap on this package's platforms.
        let size = try reader.readInt32()
        let end = reader.position + Int(size)

        let listType = try reader.readFourCC()
        guard listType == "pdta" else {
            throw SwiftySynthError.invalidSoundFont(
                "The type of the LIST chunk must be 'pdta', but was '\(listType)'."
            )
        }

        var presetInfos: [PresetInfo]?
        var presetBag: [ZoneInfo]?
        var presetModulators: [Modulator] = []
        var presetGenerators: [Generator]?
        var instrumentInfos: [InstrumentInfo]?
        var instrumentBag: [ZoneInfo]?
        var instrumentModulators: [Modulator] = []
        var instrumentGenerators: [Generator]?
        var sampleHeaders: [SampleHeader]?

        while reader.position < end {
            let id = try reader.readFourCC()
            let chunkSize = Int(try reader.readInt32())

            switch id {
            case "phdr":
                presetInfos = try PresetInfo.create(reader: reader, size: chunkSize)
            case "pbag":
                presetBag = try ZoneInfo.create(reader: reader, size: chunkSize)
            case "pmod":
                presetModulators = try Modulator.readAll(from: reader, size: chunkSize)
            case "pgen":
                presetGenerators = try Generator.readFromChunk(reader: reader, size: chunkSize)
            case "inst":
                instrumentInfos = try InstrumentInfo.create(reader: reader, size: chunkSize)
            case "ibag":
                instrumentBag = try ZoneInfo.create(reader: reader, size: chunkSize)
            case "imod":
                instrumentModulators = try Modulator.readAll(from: reader, size: chunkSize)
            case "igen":
                instrumentGenerators = try Generator.readFromChunk(reader: reader, size: chunkSize)
            case "shdr":
                sampleHeaders = try SampleHeader.readFromChunk(reader: reader, size: chunkSize)
            default:
                // Message text mirrors the upstream copy-paste of the INFO
                // list's error message (see `SoundFontSampleData.swift` for
                // the same precedent) — kept verbatim for porting fidelity.
                throw SwiftySynthError.invalidSoundFont("The INFO list contains an unknown ID '\(id)'.")
            }
        }

        guard let presetInfos else {
            throw SwiftySynthError.invalidSoundFont("The PHDR sub-chunk was not found.")
        }
        guard let presetBag else {
            throw SwiftySynthError.invalidSoundFont("The PBAG sub-chunk was not found.")
        }
        guard let presetGenerators else {
            throw SwiftySynthError.invalidSoundFont("The PGEN sub-chunk was not found.")
        }
        guard let instrumentInfos else {
            throw SwiftySynthError.invalidSoundFont("The INST sub-chunk was not found.")
        }
        guard let instrumentBag else {
            throw SwiftySynthError.invalidSoundFont("The IBAG sub-chunk was not found.")
        }
        guard let instrumentGenerators else {
            throw SwiftySynthError.invalidSoundFont("The IGEN sub-chunk was not found.")
        }
        guard let sampleHeaders else {
            throw SwiftySynthError.invalidSoundFont("The SHDR sub-chunk was not found.")
        }

        let instrumentZones = try Zone.create(infos: instrumentBag, generators: instrumentGenerators)
        let instruments = try Instrument.create(infos: instrumentInfos, zones: instrumentZones, samples: sampleHeaders)

        let presetZones = try Zone.create(infos: presetBag, generators: presetGenerators)
        let presets = try Preset.create(infos: presetInfos, zones: presetZones, instruments: instruments)

        self.sampleHeaders = sampleHeaders
        self.presets = presets
        self.instruments = instruments
        self.presetModulators = presetModulators
        self.instrumentModulators = instrumentModulators
    }
}
