import Foundation

/// Represents a SoundFont: the public top-level loader for an SF2 file.
///
/// Ported from `SoundFont.cs` (MeltySynth, MIT License — see NOTICE),
/// including its post-load `CheckSamples`/`CheckRegions` bounds-sanity
/// passes, which run unconditionally on every load path in the C# original.
public final class SoundFont {
    public let info: SoundFontInfo
    public let bitsPerSample: Int
    /// The sample pool. Read in place from the file for a font loaded with `init(url:)` — see `WaveData`.
    public let waveData: WaveData
    public let sampleHeaders: [SampleHeader]
    public let presets: [Preset]
    public let instruments: [Instrument]
    /// How a channel's (bank, patch) resolves to a preset; nil for a font with no presets. Shared by `Synthesizer`
    /// and `prefetchSamples(bank:patch:)`, so a prefetch warms exactly the samples a note on that channel reads.
    let presetTable: PresetTable?

    /// Loads a SoundFont from `data`. Reads `RIFF` fourCC + u32 size + `sfbk`
    /// form, then the INFO list, sdta list, and pdta list in that order.
    /// Mirrors `SoundFont`'s private `Load(Stream)` method exactly, including
    /// the post-load `CheckSamples`/`CheckRegions` passes (`checkSamples()` /
    /// `checkRegions()` below).
    ///
    /// Swift-idiom adjustment: C# reads from a `Stream`; this port reads the
    /// whole file into memory up front (via `BinaryReader`), keeping the
    /// reader itself simple. The sample pool stays a view of that copy.
    public convenience init(data: Data) throws {
        try self.init(reader: BinaryReader(data: data))
    }

    /// Loads the SoundFont in the file at `url`, reading it in place through a read-only mapping where the platform
    /// has one: nothing is copied, and the sample pool's pages are read in only as voices play them (`WaveData`).
    /// Where the file cannot be mapped it is read into memory instead, which is `init(data:)`. Swift-idiom
    /// adjustment for C#'s `SoundFont(string path)` constructor, which opens a `FileStream` directly.
    public convenience init(url: URL) throws {
        if let file = MappedFile(url: url) {
            try self.init(reader: BinaryReader(mappedFile: file))
        } else {
            try self.init(data: Data(contentsOf: url))
        }
    }

    private init(reader: BinaryReader) throws {
        let chunkId = try reader.readFourCC()
        guard chunkId == "RIFF" else {
            throw SwiftySynthError.invalidSoundFont("The RIFF chunk was not found.")
        }

        // The RIFF chunk size is read (and discarded) purely to advance the
        // cursor past it, matching C#'s unused `var size = reader.ReadInt32();`.
        _ = try reader.readInt32()

        let formType = try reader.readFourCC()
        guard formType == "sfbk" else {
            throw SwiftySynthError.invalidSoundFont(
                "The type of the RIFF chunk must be 'sfbk', but was '\(formType)'."
            )
        }

        let info = try SoundFontInfo(reader: reader)

        let sampleData = try SoundFontSampleData(reader: reader)

        let parameters = try SoundFontParameters(reader: reader)

        self.info = info
        self.bitsPerSample = sampleData.bitsPerSample
        self.waveData = sampleData.samples
        self.sampleHeaders = parameters.sampleHeaders
        self.presets = parameters.presets
        self.instruments = parameters.instruments
        self.presetTable = PresetTable(presets: parameters.presets)

        // Runs unconditionally on every load, matching C#'s `Load` calling
        // `CheckSamples()` then `CheckRegions()` after the parameters are
        // assembled. These reject a malformed font here (throwing a
        // catchable `SwiftySynthError`) instead of letting an out-of-range
        // sample/region address slip through and trap later in the
        // voice/DSP layer — preserving the "malformed font must never trap
        // the host app" invariant.
        try checkSamples()
        try checkRegions()
    }

    /// Validates every sample header's raw addresses against the sample-data
    /// bounds. Mirrors `SoundFont.cs`'s `CheckSamples`, including the `- 4`
    /// margin (present so a later out-of-range read stays safe) and the exact
    /// comparison operators for each field.
    private func checkSamples() throws {
        let sampleCount = waveData.count - 4 // This offset is to ensure that out of range access is safe.

        for sample in sampleHeaders {
            if !(0 <= sample.start && sample.start < sampleCount) {
                throw SwiftySynthError.invalidSoundFont(
                    "The start position of the sample '\(sample.name)' is out of range."
                )
            }
            if !(0 <= sample.startLoop && sample.startLoop < sampleCount) {
                throw SwiftySynthError.invalidSoundFont(
                    "The loop start position of the sample '\(sample.name)' is out of range."
                )
            }
            if !(0 < sample.end && sample.end <= sampleCount) {
                throw SwiftySynthError.invalidSoundFont(
                    "The end position of the sample '\(sample.name)' is out of range."
                )
            }
            if !(0 <= sample.endLoop && sample.endLoop <= sampleCount) {
                throw SwiftySynthError.invalidSoundFont(
                    "The loop end position of the sample '\(sample.name)' is out of range."
                )
            }
        }
    }

    /// Validates every instrument region's OFFSET-APPLIED addresses against
    /// the sample-data bounds, plus the region's loop mode. Mirrors
    /// `SoundFont.cs`'s `CheckRegions` exactly, including its four bounds
    /// checks (on the region's `sampleStart`/`sampleStartLoop`/`sampleEnd`/
    /// `sampleEndLoop`, i.e. after coarse/fine address offsets are applied)
    /// and the `sampleModes` validity check.
    ///
    /// Note: `InstrumentRegion.sampleModes` already folds any out-of-spec
    /// wire value into `.noLoop` (see `Instrument.swift`), so — unlike C#'s
    /// unchecked enum cast — this switch's `default` branch is unreachable
    /// through the Swift port. It is kept for parity with the source and as a
    /// guard against future changes to `sampleModes`.
    private func checkRegions() throws {
        let sampleCount = waveData.count - 4 // This offset is to ensure that out of range access is safe.

        for instrument in instruments {
            for region in instrument.regions {
                if !(0 <= region.sampleStart && region.sampleStart < sampleCount) {
                    throw SwiftySynthError.invalidSoundFont(
                        "The start position of the sample '\(region.sample.name)' in the instrument '\(instrument.name)' is out of range."
                    )
                }
                if !(0 <= region.sampleStartLoop && region.sampleStartLoop < sampleCount) {
                    throw SwiftySynthError.invalidSoundFont(
                        "The loop start position of the sample '\(region.sample.name)' in the instrument '\(instrument.name)' is out of range."
                    )
                }
                if !(0 < region.sampleEnd && region.sampleEnd <= sampleCount) {
                    throw SwiftySynthError.invalidSoundFont(
                        "The end position of the sample '\(region.sample.name)' in the instrument '\(instrument.name)' is out of range."
                    )
                }
                if !(0 <= region.sampleEndLoop && region.sampleEndLoop <= sampleCount) {
                    throw SwiftySynthError.invalidSoundFont(
                        "The loop end position of the sample '\(region.sample.name)' in the instrument '\(instrument.name)' is out of range."
                    )
                }

                switch region.sampleModes {
                case .noLoop, .continuous, .loopUntilNoteOff:
                    break
                }
            }
        }
    }

    /// Reads in, on the calling thread, every sample a note on a channel set to `bank` / `patch` can play, so the
    /// first notes of a newly chosen instrument do not fault the font's pages in on the audio render thread. `bank` is
    /// the channel's effective bank, as `Synthesizer` resolves it: 128 and up on the percussion channel. Resolves the
    /// preset the same way a note does — the exact (bank, patch), then the General MIDI fallback, then the default
    /// preset — and reads every region of it, whatever key or velocity would select them.
    ///
    /// Only does anything for a font read in place (`waveData.isMemoryMapped`); an owned pool is already resident.
    /// Call it off the render thread: a cold page is a disk read.
    public func prefetchSamples(bank: Int, patch: Int) {
        guard waveData.isMemoryMapped, let presetTable else { return }
        var seen = Set<ObjectIdentifier>()
        for presetRegion in presetTable.resolve(bank: bank, patch: patch).regions {
            for region in presetRegion.instrument.regions where seen.insert(ObjectIdentifier(region)).inserted {
                let lower = min(region.sampleStart, region.sampleStartLoop)
                // `+ 1`: the oscillator interpolates toward the sample after the one it is on.
                let upper = max(region.sampleEnd, region.sampleEndLoop) + 1
                waveData.prefetch(lower ..< max(lower, upper))
            }
        }
    }
}

/// The (bank, patch) → preset resolution `Synthesizer.noteOn` plays by. Mirrors MeltySynth: the lookup is keyed
/// `(bank << 16) | patch`, the first preset with an ID wins (C# `Dictionary.TryAdd`), and the preset with the lowest
/// ID is the default — for a General MIDI font, the Grand Piano.
struct PresetTable {
    let lookup: [Int: Preset]
    let defaultPreset: Preset

    /// Nil for a font with no presets.
    init?(presets: [Preset]) {
        var lookup = [Int: Preset]()
        lookup.reserveCapacity(presets.count)
        var defaultPreset: Preset?
        var minPresetId = Int.max
        for preset in presets {
            let presetId = (preset.bankNumber << 16) | preset.patchNumber
            if lookup[presetId] == nil {
                lookup[presetId] = preset
            }
            if presetId < minPresetId {
                defaultPreset = preset
                minPresetId = presetId
            }
        }
        guard let defaultPreset else { return nil }
        self.lookup = lookup
        self.defaultPreset = defaultPreset
    }

    /// The exact (bank, patch); else the General MIDI fallback — the patch under bank 0 for a melodic bank, the
    /// standard percussion set 128:0 for a drum bank; else the default preset.
    func resolve(bank: Int, patch: Int) -> Preset {
        if let preset = lookup[(bank << 16) | patch] {
            return preset
        }
        let gmPresetId = bank < 128 ? patch : (128 << 16)
        return lookup[gmPresetId] ?? defaultPreset
    }
}
