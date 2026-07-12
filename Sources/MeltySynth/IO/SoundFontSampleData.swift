import Foundation

/// The sample data (`LIST`/`sdta` chunk) of a SoundFont.
///
/// Ported from `SoundFontSampleData.cs` (MeltySynth, MIT License — see
/// NOTICE). 24-bit sample extension (`sm24`) is parsed-past and discarded —
/// this spike's scope is limited to 16-bit playback, matching
/// `SoundFontSampleData.cs`'s own scope (it never surfaces `sm24` data
/// either, just consumes the bytes).
final class SoundFontSampleData {
    let bitsPerSample: Int
    let samples: [Int16]

    /// Reads the whole `LIST`/`sdta` chunk: fourCC + size + `sdta` form,
    /// then iterates sub-chunks by ID until `size` bytes are consumed.
    /// Mirrors `SoundFontSampleData`'s internal constructor, including its
    /// hard failure on any sub-chunk ID it doesn't recognize and on a
    /// missing `smpl` sub-chunk.
    init(reader: BinaryReader) throws {
        let chunkId = try reader.readFourCC()
        guard chunkId == "LIST" else {
            throw MeltySynthError.invalidSoundFont("The LIST chunk was not found.")
        }

        // See SoundFontInfo.swift for why widening this Int32 to Int can
        // never overflow/trap on this package's platforms.
        let size = try reader.readInt32()
        let end = reader.position + Int(size)

        let listType = try reader.readFourCC()
        guard listType == "sdta" else {
            throw MeltySynthError.invalidSoundFont(
                "The type of the LIST chunk must be 'sdta', but was '\(listType)'."
            )
        }

        var bitsPerSample = 0
        var samples: [Int16]?

        while reader.position < end {
            let id = try reader.readFourCC()
            let chunkSize = try reader.readInt32()

            switch id {
            case "smpl":
                // C#'s `new short[size / 2]` throws (catchably) on a
                // negative length; a negative chunk size here would make
                // Swift's `0..<(chunkSize / 2)` build an inverted range and
                // trap, so reject it up front to preserve the "never trap
                // the host app" invariant. The array is built via explicit
                // little-endian `Int16` reads through `BinaryReader` (no
                // `withUnsafeBytes` reinterpretation of file bytes), mirroring
                // the loop shape of C#'s `MemoryMarshal.Cast` copy without
                // relying on host-endianness-sensitive reinterpretation.
                guard chunkSize >= 0 else {
                    throw MeltySynthError.invalidSoundFont("The sample data chunk is invalid.")
                }
                bitsPerSample = 16
                let count = Int(chunkSize) / 2
                var values: [Int16] = []
                values.reserveCapacity(count)
                for _ in 0..<count {
                    values.append(try reader.readInt16())
                }
                samples = values
            case "sm24":
                // 24-bit audio is not supported; skip past it. `skip`
                // itself rejects a negative count without trapping.
                try reader.skip(Int(chunkSize))
            default:
                throw MeltySynthError.invalidSoundFont("The INFO list contains an unknown ID '\(id)'.")
            }
        }

        guard let samples else {
            throw MeltySynthError.invalidSoundFont("No valid sample data was found.")
        }

        // "OggS" little-endian (SoundFont3's Ogg Vorbis compressed-sample
        // signature) is not supported; guard the 2-sample/4-byte peek so a
        // too-short `smpl` chunk can't make this subscript trap.
        if samples.count >= 2, samples[0] == 0x674F, samples[1] == 0x5367 {
            throw MeltySynthError.invalidSoundFont("SoundFont3 is not yet supported.")
        }

        self.bitsPerSample = bitsPerSample
        self.samples = samples
    }
}
