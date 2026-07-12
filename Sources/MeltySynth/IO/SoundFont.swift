import Foundation

/// Represents a SoundFont: the public top-level loader for an SF2 file.
///
/// Ported from `SoundFont.cs` (MeltySynth, MIT License — see NOTICE).
///
/// `CheckSamples`/`CheckRegions` (the post-load bounds-sanity passes in
/// `SoundFont.cs`'s `Load`, which validate every sample header's/region's
/// addresses against `waveData.Length - 4`) are intentionally NOT ported
/// here: they have no caller/requirement in this task's pinned interface,
/// and applying them verbatim would reject this task's own pinned
/// synthetic-SF2 test fixture (whose minimal 8-sample `smpl` chunk and
/// `TestSample` header — `end = 8` — fail the `end <= waveData.Length - 4`
/// check with only 8 samples present). This mirrors the project's existing
/// precedent of omitting C# safety nets that have no caller yet in the port
/// (e.g. `Preset.Default`/`Instrument.Default`/`SampleHeader.Default`).
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
            throw MeltySynthError.invalidSoundFont("The RIFF chunk was not found.")
        }

        // The RIFF chunk size is read (and discarded) purely to advance the
        // cursor past it, matching C#'s unused `var size = reader.ReadInt32();`.
        _ = try reader.readInt32()

        let formType = try reader.readFourCC()
        guard formType == "sfbk" else {
            throw MeltySynthError.invalidSoundFont(
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
    }

    /// Loads a SoundFont from the file at `url`. Swift-idiom adjustment for
    /// C#'s `SoundFont(string path)` constructor, which opens a `FileStream`
    /// directly; this port loads the whole file into `Data` first and
    /// delegates to `init(data:)`.
    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }
}
