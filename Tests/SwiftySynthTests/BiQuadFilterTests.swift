import Foundation
import Testing
@testable import SwiftySynth

struct BiQuadFilterTests {
    /// Cutoffs at/above 0.499 × sampleRate (≈ 22006 Hz at 44.1 kHz) bypass the filter.
    @Test func bypassesAboveNyquistGuard() {
        let filter = BiQuadFilter(sampleRate: 44_100)
        filter.setLowPassFilter(cutoffFrequency: 23_000, resonance: 1)
        var block = [Float](repeating: 0, count: 64)
        block[0] = 1
        filter.process(&block)
        #expect(block[0] == 1)
        #expect(block[10] == 0)
    }

    /// The SF2 default cutoff (13500 cents ≈ 19912.6 Hz) is BELOW the bypass threshold —
    /// the filter must actively process even for presets that never set a cutoff.
    /// This is the spec's "the filter cannot be stubbed" fact, encoded as a test.
    @Test func sf2DefaultCutoffIsActive() {
        let filter = BiQuadFilter(sampleRate: 44_100)
        filter.setLowPassFilter(cutoffFrequency: SoundFontMath.centsToHertz(13500), resonance: 1)
        var block = [Float](repeating: 0, count: 64)
        block[0] = 1
        filter.process(&block)
        #expect(abs(block[0] - 1) > 0.05, "filter must be active at the SF2 default cutoff")
    }

    /// An RBJ low-pass biquad has exactly unity DC gain: a constant input converges to 1.
    @Test func unityDCGain() {
        let filter = BiQuadFilter(sampleRate: 44_100)
        filter.setLowPassFilter(cutoffFrequency: 1_000, resonance: 1)
        var block = [Float](repeating: 1, count: 2_048)
        filter.process(&block)
        expectClose(block[2_047], 1, rel: 2e-3)
    }

    /// Second-order low-pass: a 10 kHz sine through a 1 kHz cutoff (one decade above)
    /// is attenuated by ~40 dB; assert at least 26 dB (×0.05) to stay robust to Q details.
    @Test func attenuatesHighFrequencies() {
        let filter = BiQuadFilter(sampleRate: 44_100)
        filter.setLowPassFilter(cutoffFrequency: 1_000, resonance: 1)
        var block = (0..<8_192).map { Float(sin(2 * Double.pi * 10_000 * Double($0) / 44_100)) }
        let inputRMS = rms(block[4_096...])
        filter.process(&block)
        let outputRMS = rms(block[4_096...])   // post-transient region
        #expect(outputRMS < 0.05 * inputRMS, "expected ≥26 dB attenuation, got \(20 * log10(outputRMS / inputRMS)) dB")
    }
}

private func rms(_ xs: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for x in xs { sum += Double(x) * Double(x) }
    return (sum / Double(xs.count)).squareRoot()
}
