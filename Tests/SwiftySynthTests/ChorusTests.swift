import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic, hand-derived component tests for the faithful chorus port —
/// the chorus half of G2-fx's COMPONENT evidence (rustysynth's Chorus is
/// pub(crate): no component oracle tap; e2e equivalence is
/// EffectsEquivalenceTests' job). The zero-depth case degenerates the
/// chorus into a fixed fractional delay whose impulse response is derivable
/// by hand; the canonical-parameter case pins the stereo quarter-cycle
/// offset without over-fitting the wobbling read position.
struct ChorusTests {
    /// depth 0 ⇒ every delay-table entry is the constant
    /// Float(44100 × 0.002) = 88.19999694824219 samples ⇒ a pure fractional
    /// delay. An impulse must come out as EXACTLY two adjacent nonzero
    /// samples — the two integer taps bracketing the 88.2-sample delay —
    /// whose weights sum to 1 (linear interpolation conserves the impulse).
    /// Hand trace: at t=88 the read position is 88 − 88.19999… < 0, wraps to
    /// buffer-end and interpolates INTO the impulse at index 0 with weight
    /// a = 1 − frac(d) ≈ 0.80000305; at t=89 the position is 0.80000305 and
    /// the impulse contributes 1 − a ≈ 0.19999695.
    @Test func zeroDepthChorusIsAPureFractionalDelay() {
        let chorus = Chorus(sampleRate: 44_100, delay: 0.002, depth: 0, frequency: 0.4)

        var inputL = [Float](repeating: 0, count: 256)
        inputL[0] = 1
        let inputR = [Float](repeating: 0, count: 256)
        var outputL = [Float](repeating: 0, count: 256)
        var outputR = [Float](repeating: 0, count: 256)
        chorus.process(inputLeft: inputL, inputRight: inputR,
                       outputLeft: &outputL, outputRight: &outputR)

        // First-principles expectation, same arithmetic as the constructor:
        let d = Double(Float(44_100.0 * 0.002))            // 88.19999694824219
        let first = Int(d)                                  // 88
        let weightAtFirst = Float(1 - d.truncatingRemainder(dividingBy: 1))

        let nonZero = outputL.enumerated().filter { $0.element != 0 }.map(\.offset)
        #expect(nonZero == [first, first + 1])
        #expect(abs(outputL[first] - weightAtFirst) < 1.0e-6)
        #expect(abs(outputL[first] + outputL[first + 1] - 1) < 1.0e-6)
        #expect(outputR.allSatisfy { $0 == 0 }, "the right input was silent")
    }

    /// Canonical parameters (0.002, 0.0019, 0.4): the right tap starts a
    /// quarter LFO cycle ahead (table index N/4), where sin ≈ 1 ⇒ right
    /// delay ≈ 44100·(0.002+0.0019) ≈ 172 samples vs left ≈ 88.2. Pins the
    /// stereo offset and the table construction without over-fitting the
    /// per-sample wobble: onsets in tight hand-computed ranges, right after
    /// left, and ~unit impulse mass on both sides (the read position moves
    /// at 1 ∓ 0.005 samples/sample, so mass conservation is approximate).
    @Test func canonicalParametersPlaceStereoTapsAQuarterCycleApart() {
        let chorus = Chorus(sampleRate: 44_100, delay: 0.002, depth: 0.0019, frequency: 0.4)

        var inputL = [Float](repeating: 0, count: 512)
        inputL[0] = 1
        var inputR = [Float](repeating: 0, count: 512)
        inputR[0] = 1
        var outputL = [Float](repeating: 0, count: 512)
        var outputR = [Float](repeating: 0, count: 512)
        chorus.process(inputLeft: inputL, inputRight: inputR,
                       outputLeft: &outputL, outputRight: &outputR)

        let onsetL = outputL.firstIndex { $0 != 0 }
        let onsetR = outputR.firstIndex { $0 != 0 }
        #expect(onsetL != nil && (87...89).contains(onsetL!), "left onset ≈ 88.2-sample delay, got \(String(describing: onsetL))")
        #expect(onsetR != nil && (170...173).contains(onsetR!), "right onset ≈ 172-sample delay (quarter-cycle offset), got \(String(describing: onsetR))")
        #expect(onsetR! > onsetL!)

        let massL = outputL.reduce(Double(0)) { $0 + Double($1) }
        let massR = outputR.reduce(Double(0)) { $0 + Double($1) }
        #expect(abs(massL - 1) < 0.05, "impulse mass ≈ 1 through the moving tap, got \(massL)")
        #expect(abs(massR - 1) < 0.05, "impulse mass ≈ 1 through the moving tap, got \(massR)")
    }

    /// mute() zeros the delay lines (indexes intentionally NOT reset, per
    /// C#): a muted chorus fed zeros emits exactly zeros.
    @Test func muteZeroesTheDelayLines() {
        let chorus = Chorus(sampleRate: 44_100, delay: 0.002, depth: 0.0019, frequency: 0.4)
        var inputL = [Float](repeating: 0, count: 256)
        inputL[0] = 1
        var inputR = inputL
        inputR[10] = 0.5
        var outputL = [Float](repeating: 0, count: 256)
        var outputR = [Float](repeating: 0, count: 256)
        chorus.process(inputLeft: inputL, inputRight: inputR,
                       outputLeft: &outputL, outputRight: &outputR)

        chorus.mute()
        let zeros = [Float](repeating: 0, count: 256)
        chorus.process(inputLeft: zeros, inputRight: zeros,
                       outputLeft: &outputL, outputRight: &outputR)
        #expect(outputL.allSatisfy { $0 == 0 })
        #expect(outputR.allSatisfy { $0 == 0 })
    }
}
