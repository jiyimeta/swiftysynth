import Foundation

/// Represents a sample in the SoundFont.
///
/// Ported from `SampleHeader.cs` (MeltySynth, MIT License — see NOTICE). C#
/// stores `originalPitch`/`pitchCorrection`/`link`/`sampleType` at their raw
/// wire widths (`byte`/`sbyte`/`ushort`/`ushort` respectively) but exposes
/// them as `int`-returning properties (implicit widening); the Swift port
/// reads the same wire widths and widens to `Int32` at parse time to match.
public final class SampleHeader {
    public let name: String
    public let start: Int32
    public let end: Int32
    public let startLoop: Int32
    public let endLoop: Int32
    public let sampleRate: Int32
    public let originalPitch: Int32
    public let pitchCorrection: Int32
    public let link: Int32
    public let sampleType: Int32

    /// Reads one 46-byte `shdr` record: a 20-byte fixed-length name, five
    /// little-endian `Int32` fields, a `UInt8`, a signed `Int8`, and two
    /// `UInt16` fields, in that exact order — mirrors the private
    /// `SampleHeader(BinaryReader reader)` constructor.
    init(reader: BinaryReader) throws {
        name = try reader.readFixedLengthString(20)
        start = try reader.readInt32()
        end = try reader.readInt32()
        startLoop = try reader.readInt32()
        endLoop = try reader.readInt32()
        sampleRate = try reader.readInt32()
        originalPitch = Int32(try reader.readUInt8())
        pitchCorrection = Int32(try reader.readInt8())
        link = Int32(try reader.readUInt16())
        sampleType = Int32(try reader.readUInt16())
    }

    /// Direct-construction initializer for tests (no C# analogue; C# only
    /// has the reader-based private constructor plus a parameterless
    /// `Default` singleton).
    init(
        name: String,
        start: Int32,
        end: Int32,
        startLoop: Int32,
        endLoop: Int32,
        sampleRate: Int32,
        originalPitch: Int32,
        pitchCorrection: Int32,
        link: Int32,
        sampleType: Int32
    ) {
        self.name = name
        self.start = start
        self.end = end
        self.startLoop = startLoop
        self.endLoop = endLoop
        self.sampleRate = sampleRate
        self.originalPitch = originalPitch
        self.pitchCorrection = pitchCorrection
        self.link = link
        self.sampleType = sampleType
    }
}
