import Foundation
import Testing
@testable import SwiftySynth

/// `SoundFont(url:)` reads the sample pool in place from a file mapping; `SoundFont(data:)` keeps its own copy. Both
/// must be the same font to everything that plays it.
struct MappedSoundFontTests {
    /// A font written to a file and loaded from it is read in place, and is the same font as the bytes it came from.
    @Test func fileLoadReadsTheSamePoolInPlace() throws {
        let data = SyntheticSF2.minimal()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftysynth-mapped-\(UUID().uuidString).sf2")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let mapped = try SoundFont(url: url)
        let copied = try SoundFont(data: data)

        #expect(mapped.waveData.isMemoryMapped)
        #expect(!copied.waveData.isMemoryMapped)
        #expect(Array(mapped.waveData) == Array(copied.waveData))
        #expect(mapped.sampleHeaders.map(\.name) == copied.sampleHeaders.map(\.name))
        #expect(mapped.presets.map(\.name) == copied.presets.map(\.name))
    }

    /// The pool outlives the font that read it: a voice that still holds it keeps the mapping alive.
    @Test func poolOutlivesItsFont() throws {
        let data = SyntheticSF2.minimal()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftysynth-mapped-\(UUID().uuidString).sf2")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var font: SoundFont? = try SoundFont(url: url)
        let pool = try #require(font?.waveData)
        let expected = Array(pool)
        font = nil
        #expect(Array(pool) == expected)
    }

    /// A `smpl` chunk at an odd offset cannot be read as `Int16` in place; it is copied, and still reads right.
    @Test func oddOffsetPoolIsCopied() throws {
        let reader = BinaryReader(data: Data([0xFF, 0x01, 0x00, 0xFE, 0xFF]))
        try reader.skip(1)
        let pool = try reader.readWaveData(count: 2)
        #expect(Array(pool) == [1, -2])
        #expect(!pool.isMemoryMapped)
    }

    /// An over-claimed sample count throws instead of reading past the end.
    @Test func overClaimedCountThrows() throws {
        let reader = BinaryReader(data: Data([0x01, 0x00]))
        #expect(throws: SwiftySynthError.self) {
            _ = try reader.readWaveData(count: 2)
        }
    }

    /// A missing file falls back to `Data(contentsOf:)`, which reports it.
    @Test func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftysynth-missing-\(UUID()).sf2")
        #expect(throws: (any Error).self) {
            _ = try SoundFont(url: url)
        }
    }

    /// Prefetching takes any channel setting — every melodic program and the drum bank, none of which the one-preset
    /// font has — resolving it the way a note does, so it never reads outside the pool.
    @Test func prefetchTakesAnyProgram() throws {
        let data = SyntheticSF2.minimal()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftysynth-mapped-\(UUID().uuidString).sf2")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let font = try SoundFont(url: url)
        let table = try #require(font.presetTable)

        for patch in 0 ..< 128 {
            font.prefetchSamples(bank: 0, patch: patch)
        }
        font.prefetchSamples(bank: 128, patch: 0)
        // A program the font lacks plays its default preset — the one preset it has.
        #expect(table.resolve(bank: 0, patch: 99) === font.presets[0])
        #expect(table.resolve(bank: 128, patch: 0) === font.presets[0])
    }
}

/// The same checks against the real General MIDI font, which only runs where it is present.
@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct MappedGeneralMIDIFontTests {
    /// The mapped and the copied font are the same pool, sample for sample.
    @Test func mappedPoolMatchesCopiedPool() throws {
        let mapped = try SoundFont(url: FixtureSF2.url)
        let copied = try SoundFont(data: Data(contentsOf: FixtureSF2.url))
        #expect(mapped.waveData.isMemoryMapped)
        #expect(smplSHA256(mapped.waveData) == smplSHA256(copied.waveData))
    }

    /// A chord on a few programs, the drum kit included, renders bit-identically from the mapped font and from the
    /// copied one — after every program has been prefetched, so prefetching changes nothing audible either.
    @Test func mappedFontRendersBitIdentically() throws {
        let mapped = try SoundFont(url: FixtureSF2.url)
        let copied = try SoundFont(data: Data(contentsOf: FixtureSF2.url))
        for patch in [0, 24, 40, 73] {
            mapped.prefetchSamples(bank: 0, patch: patch)
        }
        mapped.prefetchSamples(bank: 128, patch: 0)

        func render(_ font: SoundFont) throws -> [Float] {
            let settings = try SynthesizerSettings(sampleRate: 44_100, enableReverbAndChorus: true)
            let synth = try Synthesizer(soundFont: font, settings: settings)
            for (channel, patch) in [(0, 0), (1, 24), (2, 40), (3, 73)] {
                synth.processMidiMessage(channel: channel, command: 0xC0, data1: patch, data2: 0)
                synth.noteOn(key: 60 + channel * 4, velocity: 100, on: channel)
            }
            synth.noteOn(key: 36, velocity: 110, on: 9)
            synth.noteOn(key: 42, velocity: 90, on: 9)
            var left = [Float](repeating: 0, count: 44_100)
            var right = [Float](repeating: 0, count: 44_100)
            renderInto(synth, &left, &right, 0 ..< 44_100)
            return left + right
        }

        let fromMapped = try render(mapped)
        let fromCopied = try render(copied)
        #expect(fromMapped.contains { $0 != 0 })
        #expect(fromMapped == fromCopied)
    }
}
