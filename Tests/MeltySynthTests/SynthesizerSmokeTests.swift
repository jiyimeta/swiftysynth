import Foundation
import Testing
@testable import MeltySynth

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct SynthesizerSmokeTests {
    @Test func singleNoteLifecycle() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let synth = try Synthesizer(soundFont: font, sampleRate: 44_100)
        #expect(synth.blockSize == 64)
        #expect(synth.masterVolume == 0.5)
        #expect(synth.activeVoiceCount == 0)

        var left = [Float](repeating: 0, count: 220_500)
        var right = [Float](repeating: 0, count: 220_500)

        synth.noteOn(key: 60, velocity: 100)
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
        synth.noteOff(key: 60)
        renderInto(synth, &left, &right, 88_200..<100_001)
        renderInto(synth, &left, &right, 100_001..<220_500)

        #expect(synth.activeVoiceCount == 0, "voices must be freed after the release tail")
        let tailL = rmsOf(left[216_090..<220_500])   // final 100 ms
        #expect(tailL < 1e-3, "release must decay to silence, got RMS \(tailL)")
    }

    @Test func pool8IgnoresOverflowNoteOns() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let synth = try Synthesizer(soundFont: font, sampleRate: 44_100)
        for key in 60..<70 { synth.noteOn(key: key, velocity: 100) }   // 10 keys × ≥2 voices ≫ 8
        #expect(synth.activeVoiceCount == 8, "fixed pool must cap at 8 with no stealing")
        var left = [Float](repeating: 0, count: 4_410)
        var right = [Float](repeating: 0, count: 4_410)
        renderInto(synth, &left, &right, 0..<4_410)   // must not crash or clip
        #expect(left.allSatisfy { $0.isFinite })
    }
}

func rmsOf(_ xs: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for x in xs { sum += Double(x) * Double(x) }
    return (sum / Double(xs.count)).squareRoot()
}
