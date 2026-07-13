import Testing
@testable import SwiftySynth

struct SoundFontMathTests {
    @Test func timecentsToSeconds() {
        expectClose(SoundFontMath.timecentsToSeconds(0), 1)
        expectClose(SoundFontMath.timecentsToSeconds(1200), 2)
        // 2^-10 — the SF2 "instant" default (-12000 timecents)
        expectClose(SoundFontMath.timecentsToSeconds(-12000), 0.0009765625)
    }

    @Test func centsToHertz() {
        expectClose(SoundFontMath.centsToHertz(0), 8.176, rel: 1e-5)
        expectClose(SoundFontMath.centsToHertz(1200), 16.352, rel: 1e-5)
        // The SF2 default initialFilterFc (13500 cents) — the value that makes the
        // biquad filter active even for presets that never set a cutoff.
        expectClose(SoundFontMath.centsToHertz(13500), 19912.617, rel: 1e-5)
    }

    @Test func centsToMultiplyingFactor() {
        expectClose(SoundFontMath.centsToMultiplyingFactor(0), 1)
        expectClose(SoundFontMath.centsToMultiplyingFactor(1200), 2)
        expectClose(SoundFontMath.centsToMultiplyingFactor(-1200), 0.5)
    }

    @Test func decibelConversions() {
        expectClose(SoundFontMath.decibelsToLinear(0), 1)
        expectClose(SoundFontMath.decibelsToLinear(20), 10)
        expectClose(SoundFontMath.decibelsToLinear(-40), 0.01, rel: 1e-5)
        expectClose(SoundFontMath.linearToDecibels(1), 0)
        expectClose(SoundFontMath.linearToDecibels(10), 20, rel: 1e-5)
        expectClose(SoundFontMath.linearToDecibels(0.5), -6.0206, rel: 1e-4)
    }

    @Test func keyNumberScaling() {
        // Defined as timecentsToSeconds(cents · (60 − key)).
        expectClose(SoundFontMath.keyNumberToMultiplyingFactor(100, 60), 1)
        expectClose(SoundFontMath.keyNumberToMultiplyingFactor(100, 40), 3.1748021, rel: 1e-5) // 2^(2000/1200)
        expectClose(SoundFontMath.keyNumberToMultiplyingFactor(0, 30), 1)
    }

    @Test func expCutoff() {
        #expect(SoundFontMath.expCutoff(0) == 1)
        #expect(SoundFontMath.expCutoff(-100) == 0) // below log(1e-3) ≈ -6.9078
        expectClose(Float(SoundFontMath.expCutoff(-1)), 0.36787945, rel: 1e-5)
    }
}
