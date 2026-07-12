import Foundation

/// The parameters of a SoundFont (the `LIST`/`pdta` chunk): sample headers,
/// presets, and instruments.
///
/// Ported from `SoundFontParameters.cs` (MeltySynth, MIT License — see
/// NOTICE). Modulators (`pmod`/`imod`) are parsed-and-discarded — this
/// spike's scope never surfaces modulator data, matching `Zone.swift`'s own
/// scope decision (see `Zone.cs`/`Modulator.cs`).
final class SoundFontParameters {
    let sampleHeaders: [SampleHeader]
    let presets: [Preset]
    let instruments: [Instrument]

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
            throw MeltySynthError.invalidSoundFont("The LIST chunk was not found.")
        }

        // See SoundFontInfo.swift for why widening this Int32 chunk size to
        // Int can never overflow/trap on this package's platforms.
        let size = try reader.readInt32()
        let end = reader.position + Int(size)

        let listType = try reader.readFourCC()
        guard listType == "pdta" else {
            throw MeltySynthError.invalidSoundFont(
                "The type of the LIST chunk must be 'pdta', but was '\(listType)'."
            )
        }

        var presetInfos: [PresetInfo]?
        var presetBag: [ZoneInfo]?
        var presetGenerators: [Generator]?
        var instrumentInfos: [InstrumentInfo]?
        var instrumentBag: [ZoneInfo]?
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
                try SoundFontParameters.discardModulatorData(reader: reader, size: chunkSize)
            case "pgen":
                presetGenerators = try Generator.readFromChunk(reader: reader, size: chunkSize)
            case "inst":
                instrumentInfos = try InstrumentInfo.create(reader: reader, size: chunkSize)
            case "ibag":
                instrumentBag = try ZoneInfo.create(reader: reader, size: chunkSize)
            case "imod":
                try SoundFontParameters.discardModulatorData(reader: reader, size: chunkSize)
            case "igen":
                instrumentGenerators = try Generator.readFromChunk(reader: reader, size: chunkSize)
            case "shdr":
                sampleHeaders = try SampleHeader.readFromChunk(reader: reader, size: chunkSize)
            default:
                // Message text mirrors the upstream copy-paste of the INFO
                // list's error message (see `SoundFontSampleData.swift` for
                // the same precedent) — kept verbatim for porting fidelity.
                throw MeltySynthError.invalidSoundFont("The INFO list contains an unknown ID '\(id)'.")
            }
        }

        guard let presetInfos else {
            throw MeltySynthError.invalidSoundFont("The PHDR sub-chunk was not found.")
        }
        guard let presetBag else {
            throw MeltySynthError.invalidSoundFont("The PBAG sub-chunk was not found.")
        }
        guard let presetGenerators else {
            throw MeltySynthError.invalidSoundFont("The PGEN sub-chunk was not found.")
        }
        guard let instrumentInfos else {
            throw MeltySynthError.invalidSoundFont("The INST sub-chunk was not found.")
        }
        guard let instrumentBag else {
            throw MeltySynthError.invalidSoundFont("The IBAG sub-chunk was not found.")
        }
        guard let instrumentGenerators else {
            throw MeltySynthError.invalidSoundFont("The IGEN sub-chunk was not found.")
        }
        guard let sampleHeaders else {
            throw MeltySynthError.invalidSoundFont("The SHDR sub-chunk was not found.")
        }

        let instrumentZones = try Zone.create(infos: instrumentBag, generators: instrumentGenerators)
        let instruments = try Instrument.create(infos: instrumentInfos, zones: instrumentZones, samples: sampleHeaders)

        let presetZones = try Zone.create(infos: presetBag, generators: presetGenerators)
        let presets = try Preset.create(infos: presetInfos, zones: presetZones, instruments: instruments)

        self.sampleHeaders = sampleHeaders
        self.presets = presets
        self.instruments = instruments
    }

    /// Skips a `pmod`/`imod` sub-chunk without parsing it. Mirrors
    /// `Modulator.DiscardData`: modulators are not supported by this port.
    private static func discardModulatorData(reader: BinaryReader, size: Int) throws {
        guard size % 10 == 0 else {
            throw MeltySynthError.invalidSoundFont("The modulator list is invalid.")
        }
        try reader.skip(size)
    }
}
