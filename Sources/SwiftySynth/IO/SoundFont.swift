import Foundation

/// Represents a SoundFont: the public top-level loader for an SF2 file.
///
/// Ported from `SoundFont.cs` (MeltySynth, MIT License — see NOTICE),
/// including its post-load `CheckSamples`/`CheckRegions` bounds-sanity
/// passes, which run unconditionally on every load path in the C# original.
public final class SoundFont {
    public let info: SoundFontInfo
    public let bitsPerSample: Int
    public let waveData: [Int16]
    public let sampleHeaders: [SampleHeader]
    public let presets: [Preset]
    public let instruments: [Instrument]

    /// Loads a SoundFont from `data`. Reads `RIFF` fourCC + u32 size + `sfbk`
    /// form, then the INFO list, sdta list, and pdta list in that order.
    /// Mirrors `SoundFont`'s private `Load(Stream)` method exactly (modulo
    /// the `CheckSamples`/`CheckRegions` omission documented above).
    ///
    /// Swift-idiom adjustment: C# reads from a `Stream`; this port reads the
    /// whole file into `Data` up front (via `BinaryReader`), keeping the
    /// reader itself simple.
    public init(data: Data) throws {
        let reader = BinaryReader(data: data)

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

    /// Loads a SoundFont from the file at `url`. Swift-idiom adjustment for
    /// C#'s `SoundFont(string path)` constructor, which opens a `FileStream`
    /// directly; this port loads the whole file into `Data` first and
    /// delegates to `init(data:)`.
    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }
}
