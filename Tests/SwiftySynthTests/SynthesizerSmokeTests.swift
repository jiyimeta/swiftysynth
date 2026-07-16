import Foundation
import Testing
@testable import SwiftySynth

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct SynthesizerSmokeTests {
    @Test func singleNoteLifecycle() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        // P2: default settings now enable the effects bus; this smoke pins
        // the DRY note lifecycle (wet routing/e2e are SynthesizerEffectsTests
        // and EffectsEquivalenceTests' job), so the flag is explicit.
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, enableReverbAndChorus: false)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        #expect(synth.blockSize == 64)
        #expect(synth.masterVolume == 0.5)
        #expect(synth.activeVoiceCount == 0)

        var left = [Float](repeating: 0, count: 220_500)
        var right = [Float](repeating: 0, count: 220_500)

        synth.noteOn(key: 60, velocity: 100, on: 0)
        // TEST FIX (not a port bug — verified against generaluser-gs-dump.json,
        // independent of this Swift port): the brief's premise that a "stereo
        // piano preset spawns an L/R voice pair" does not hold for
        // GeneralUser GS's actual Grand Piano → "Stereo Grand Mellow"
        // instrument. Every one of its 22 instrument regions covers the full
        // velocity range [0, 127] with a non-overlapping key range and a
        // *panned mono* sample (pan sweeps -34..+34 across the keyboard,
        // simulating stereo width) — "stereo" describes the source
        // recording, not a discrete L/R SF2 region pair. Cross-checked
        // directly against the oracle dump: exactly 1 of 48 preset regions
        // (key 51-65, one of 8 non-overlapping velocity layers) and exactly
        // 1 of that region's linked instrument's 22 regions (key 58-60)
        // contain (key: 60, velocity: 100) — for every key/velocity this
        // preset ever plays, `noteOn` starts exactly one voice.
        #expect(synth.activeVoiceCount == 1, "got \(synth.activeVoiceCount) active voices")

        renderInto(synth, &left, &right, 0..<44_100)
        let firstSecondL = rmsOf(left[0..<44_100])
        let firstSecondR = rmsOf(right[0..<44_100])
        #expect(firstSecondL > 1e-3, "left channel must carry signal, got RMS \(firstSecondL)")
        #expect(firstSecondR > 1e-3, "right channel must carry signal, got RMS \(firstSecondR)")
        #expect(left[0..<44_100].allSatisfy { abs($0) < 1.0 }, "no clipping at master 0.5")

        // Odd-sized chunks exercise the partial-block carry (none is a multiple of 64).
        renderInto(synth, &left, &right, 44_100..<56_445)
        renderInto(synth, &left, &right, 56_445..<88_200)
        synth.noteOff(key: 60, on: 0)
        renderInto(synth, &left, &right, 88_200..<100_001)
        renderInto(synth, &left, &right, 100_001..<220_500)

        #expect(synth.activeVoiceCount == 0, "voices must be freed after the release tail")
        let tailL = rmsOf(left[216_090..<220_500])   // final 100 ms
        #expect(tailL < 1e-3, "release must decay to silence, got RMS \(tailL)")
    }

    /// The steal smoke: overflowing a full pool must neither grow it nor drop
    /// the new note. Full behavioral coverage is the G-steal suite
    /// (VoiceStealingTests); this pins the always-sounds contract cheaply.
    @Test func pool8StealsInsteadOfDropping() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 8, enableReverbAndChorus: false)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        for key in 60..<70 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 10 keys > 8 slots
        #expect(synth.activeVoiceCount == 8, "the pool stays exactly full — steal, don't grow, don't drop")
        let keys = (0..<synth.voices.activeVoiceCount).map { synth.voices[$0].key }
        #expect(keys.contains(69), "the most recent noteOn must always sound (steal-to-play)")
        var left = [Float](repeating: 0, count: 4_410)
        var right = [Float](repeating: 0, count: 4_410)
        renderInto(synth, &left, &right, 0..<4_410)
        #expect(left.allSatisfy { $0.isFinite })
    }
}

func rmsOf(_ xs: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for x in xs { sum += Double(x) * Double(x) }
    return (sum / Double(xs.count)).squareRoot()
}
