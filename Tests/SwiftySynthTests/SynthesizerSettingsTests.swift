import Testing
@testable import SwiftySynth

/// Hermetic. `SynthesizerSettings` is the idiomatic value-type analogue of
/// `SynthesizerSettings.cs`: validation happens once, in a throwing init
/// (C# validates in property setters); properties are immutable `let`s so a
/// constructed value is valid by construction. Ranges are canonical-faithful:
/// sampleRate 16000...192000, blockSize 8...1024, maximumPolyphony 8...256.
struct SynthesizerSettingsTests {
    @Test func defaultsAreCanonical() throws {
        let settings = try SynthesizerSettings(sampleRate: 44_100)
        #expect(settings.sampleRate == 44_100)
        #expect(settings.blockSize == 64)
        #expect(settings.maximumPolyphony == 64)
        #expect(settings.enableReverbAndChorus == true)
        #expect(SynthesizerSettings.defaultBlockSize == 64)
        #expect(SynthesizerSettings.defaultMaximumPolyphony == 64)
    }

    @Test func acceptsTheDocumentedRangeBounds() throws {
        _ = try SynthesizerSettings(sampleRate: 16_000, blockSize: 8, maximumPolyphony: 8)
        _ = try SynthesizerSettings(sampleRate: 192_000, blockSize: 1_024, maximumPolyphony: 256)
    }

    @Test(arguments: [15_999, 192_001, 0, -44_100])
    func rejectsOutOfRangeSampleRate(_ sampleRate: Int) {
        #expect(throws: SwiftySynthError.self) {
            _ = try SynthesizerSettings(sampleRate: sampleRate)
        }
    }

    @Test(arguments: [7, 1_025, 0])
    func rejectsOutOfRangeBlockSize(_ blockSize: Int) {
        #expect(throws: SwiftySynthError.self) {
            _ = try SynthesizerSettings(sampleRate: 44_100, blockSize: blockSize)
        }
    }

    @Test(arguments: [7, 257, 0])
    func rejectsOutOfRangePolyphony(_ maximumPolyphony: Int) {
        #expect(throws: SwiftySynthError.self) {
            _ = try SynthesizerSettings(sampleRate: 44_100, maximumPolyphony: maximumPolyphony)
        }
    }
}
