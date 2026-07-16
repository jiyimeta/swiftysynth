import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic, hand-derived component tests for the faithful Freeverb port —
/// the reverb half of G2-fx's COMPONENT evidence. rustysynth's Reverb is
/// pub(crate) (P0 probe finding), so there is no component-level oracle tap:
/// per-unit correctness is pinned by these first-principles invariants
/// (exact expected values derived by hand in the comments), and the oracle
/// comparison happens end-to-end in EffectsEquivalenceTests (G2-fx e2e).
/// All expected values are dyadic rationals — exact in Float — so `==` is
/// deliberate: any arithmetic reordering in the recurrences fails loudly.
struct ReverbTests {
    // MARK: CombFilter

    /// Feedback comb, damp 0 (damp1=0, damp2=1 ⇒ filterStore == last read):
    /// an impulse recirculates at buffer-length round trips, scaled by
    /// feedback each pass. Hand trace (N=4, feedback 0.5, impulse 1 at t=0):
    ///   t=0:  reads buffer[0]=0 → emits 0; stores buffer[0] = 1
    ///   t=4:  reads 1   → emits 1;    refills buffer[0] = 0 + 1·0.5   = 0.5
    ///   t=8:  reads 0.5 → emits 0.5;  refills buffer[0] = 0.25
    ///   t=12: reads 0.25 → emits 0.25
    @Test func combFilterImpulseDecaysByFeedbackPerRoundTrip() {
        let comb = Reverb.CombFilter(bufferSize: 4)
        comb.feedback = 0.5
        comb.damp = 0

        var input = [Float](repeating: 0, count: 16)
        input[0] = 1
        var output = [Float](repeating: 0, count: 16)
        comb.process(input: input, output: &output)

        var expected = [Float](repeating: 0, count: 16)
        expected[4] = 1
        expected[8] = 0.5
        expected[12] = 0.25
        #expect(output == expected)
    }

    /// Damped comb: the one-pole low-pass INSIDE the feedback loop.
    ///
    /// CORRECTED derivation (see NOTE below): `filterStore` is a SINGLE
    /// scalar shared by all 4 ring-buffer positions — `process` updates it
    /// on every sample `t`, not just once per buffer-length round trip — so
    /// once `damp1 != 0` each position's feedback leaks into the next
    /// position's filterStore contribution ("cross-talk" between the 4
    /// interleaved delay taps). Full trace (N=4, feedback=0.5, damp=0.25 ⇒
    /// damp1=0.25, damp2=0.75), bufferPos = t mod 4, buffer/filterStore
    /// start at 0, impulse input[0]=1:
    ///   t=0..3: buffer all read 0 ⇒ output 0; filterStore stays 0 (damp2·0);
    ///           buffer[0] = 1 (input written), buffer[1..3] = 0.
    ///   t=4: bufferPos0, output=buffer[0]=1 ⇒ fs=1·0.75+0·0.25=0.75;
    ///        buffer[0]=0.75·0.5=3/8=0.375.
    ///   t=5: bufferPos1, output=buffer[1]=0 ⇒ fs=0+0.75·0.25=3/16;
    ///        buffer[1]=3/16·0.5=3/32=0.09375.
    ///   t=6: bufferPos2, output=0 ⇒ fs=3/16·0.25=3/64; buffer[2]=3/128=0.0234375.
    ///   t=7: bufferPos3, output=0 ⇒ fs=3/64·0.25=3/256; buffer[3]=3/512=0.005859375.
    ///   t=8: bufferPos0, output=buffer[0]=3/8 ⇒
    ///        fs=(3/8)·0.75+(3/256)·0.25=9/32+3/1024=291/1024;
    ///        buffer[0]=291/2048=0.14208984375.
    ///   t=9: bufferPos1, output=buffer[1]=3/32 ⇒
    ///        fs=(3/32)·0.75+(291/1024)·0.25=9/128+291/4096=579/4096;
    ///        buffer[1]=579/8192=0.0706787109375.
    ///   t=10: bufferPos2, output=buffer[2]=3/128 ⇒
    ///        fs=(3/128)·0.75+(579/4096)·0.25=9/512+579/16384=867/16384;
    ///        buffer[2]=867/32768=0.026458740234375.
    ///   t=11: bufferPos3, output=buffer[3]=3/512 ⇒
    ///        fs=(3/512)·0.75+(867/16384)·0.25=9/2048+867/65536=1155/65536;
    ///        buffer[3]=1155/131072=0.00881195068359375.
    ///   t=12..15: outputs are the just-refreshed buffer[0..3] read back
    ///        (buffer isn't rewritten again — input is 0 past t=0):
    ///        291/2048, 579/8192, 867/32768, 1155/131072.
    /// Every value is a dyadic rational (denominators are powers of 2,
    /// numerators products of 3 well under Float's 24-bit mantissa) — exact
    /// in Float, independently verified bit-for-bit against the port.
    ///
    /// NOTE (root-caused during Task 2): the brief's original hand trace
    /// assumed filterStore's history resets independently per ring-buffer
    /// position (giving output[12] = 0.234375, output[9..11]/[13..15] = 0).
    /// That assumption is wrong — Reverb.cs's `CombFilter` has exactly one
    /// `filterStore` field, threaded across every sample regardless of
    /// which of the 4 positions is being read/written, matching Freeverb's
    /// original single continuous one-pole damping filter on the whole
    /// comb's feedback path (not 4 independent per-tap filters). The
    /// `damp = 0` test above is unaffected because damp1 = 0 zeroes out
    /// filterStore's previous-value term entirely, which coincidentally
    /// hides the cross-talk and makes filterStore == the current read.
    @Test func combFilterDampedFeedbackRecurrence() {
        let comb = Reverb.CombFilter(bufferSize: 4)
        comb.feedback = 0.5
        comb.damp = 0.25

        var input = [Float](repeating: 0, count: 16)
        input[0] = 1
        var output = [Float](repeating: 0, count: 16)
        comb.process(input: input, output: &output)

        let expected: [Float] = [
            0, 0, 0, 0,
            1, 0, 0, 0,
            0.375, 0.09375, 0.0234375, 0.005859375,
            0.14208984375, 0.0706787109375, 0.026458740234375, 0.00881195068359375,
        ]
        #expect(output == expected)
    }

    /// The 1.0e-6 denormal guard: sub-threshold energy is flushed on READ,
    /// so it can never recirculate — the output stays exactly zero.
    @Test func combFilterFlushesDenormalGuardedValuesToZero() {
        let comb = Reverb.CombFilter(bufferSize: 4)
        comb.feedback = 0.84
        comb.damp = 0.2

        var input = [Float](repeating: 0, count: 16)
        input[0] = 5.0e-7   // below the 1.0e-6 guard
        var output = [Float](repeating: 0, count: 16)
        comb.process(input: input, output: &output)

        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test func combFilterMuteClearsRecirculatingState() {
        let comb = Reverb.CombFilter(bufferSize: 4)
        comb.feedback = 0.5
        comb.damp = 0.25
        var input = [Float](repeating: 0, count: 8)
        input[0] = 1
        var output = [Float](repeating: 0, count: 8)
        comb.process(input: input, output: &output)
        #expect(output.contains { $0 != 0 })

        comb.mute()
        let zeros = [Float](repeating: 0, count: 16)
        var after = [Float](repeating: 0, count: 16)
        comb.process(input: zeros, output: &after)
        #expect(after.allSatisfy { $0 == 0 })
    }

    // MARK: AllPassFilter

    /// Freeverb's "allpass" primitive (out = bufout − in; buf = in + bufout·fb).
    /// Hand trace (N=4, feedback 0.5, impulse 1 at t=0, processed IN PLACE):
    ///   t=0:  bufout=0 → block[0] = 0 − 1 = −1; buffer[0] = 1 + 0     = 1
    ///   t=4:  bufout=1 → block[4] = 1 − 0 = 1;  buffer[0] = 0 + 1·0.5 = 0.5
    ///   t=8:  0.5   t=12: 0.25
    @Test func allPassFilterImpulseResponse() {
        let apf = Reverb.AllPassFilter(bufferSize: 4)
        apf.feedback = 0.5

        var block = [Float](repeating: 0, count: 16)
        block[0] = 1
        apf.process(block: &block)

        var expected = [Float](repeating: 0, count: 16)
        expected[0] = -1
        expected[4] = 1
        expected[8] = 0.5
        expected[12] = 0.25
        #expect(block == expected)
    }

    @Test func allPassFilterMuteClearsState() {
        let apf = Reverb.AllPassFilter(bufferSize: 4)
        apf.feedback = 0.5
        var block = [Float](repeating: 0, count: 8)
        block[0] = 1
        apf.process(block: &block)

        apf.mute()
        var zeros = [Float](repeating: 0, count: 16)
        apf.process(block: &zeros)
        #expect(zeros.allSatisfy { $0 == 0 })
    }

    // MARK: Reverb unit

    /// Freeverb defaults after init: inputGain = fixedGain exactly; the
    /// scaled parameter getters round-trip the initial values.
    @Test func defaultParametersMatchFreeverb() {
        let reverb = Reverb(sampleRate: 44_100)
        #expect(reverb.inputGain == 0.015)
        #expect(abs(reverb.roomSize - 0.5) < 1.0e-6)
        #expect(abs(reverb.damp - 0.5) < 1.0e-6)
        #expect(abs(reverb.wet - 1.0 / 3.0) < 1.0e-6)
        #expect(reverb.width == 1)
    }

    /// The sharpest single invariant in this suite. At 44.1 kHz scaleTuning
    /// is the identity, the shortest L comb is 1116 and the shortest R comb
    /// 1116+23=1139. An impulse's FIRST arrival passes each of the four
    /// series allpasses as (out = bufout − in) with zero state ⇒ one
    /// negation each ⇒ (−1)⁴ = +1 — and the default wet1=1/wet2=0 rotation
    /// is skipped. So the first output sample is +1.0 EXACTLY, at exactly
    /// the shortest comb tuning. Pins: both tuning tables, the stereo
    /// spread, the bank order, and the default-wet skip, all at once.
    @Test func impulseFirstArrivalPinsTuningTablesAt44100() {
        let reverb = Reverb(sampleRate: 44_100)
        var input = [Float](repeating: 0, count: 2_048)
        input[0] = 1
        var left = [Float](repeating: 0, count: 2_048)
        var right = [Float](repeating: 0, count: 2_048)
        reverb.process(input: input, outputLeft: &left, outputRight: &right)

        #expect(left[0..<1_116].allSatisfy { $0 == 0 })
        #expect(left[1_116] == 1.0)
        #expect(right[0..<1_139].allSatisfy { $0 == 0 })
        #expect(right[1_139] == 1.0)
    }

    /// At 22050 Hz every tuning scales by 0.5 through C#'s Math.Round —
    /// BANKER'S rounding. Shortest L comb: 1116·0.5 = 558 (exact). Third L
    /// comb: 1277·0.5 = 638.5 → 638 (round-half-to-EVEN; `.rounded()` would
    /// give 639 and fail this). Shortest R comb: 1139·0.5 = 569.5 → 570.
    /// First arrivals are +1.0 exactly (same 4-negation argument; no other
    /// comb or allpass echo lands on these indices — combs first re-emit at
    /// 2× their tuning, allpass copies start at arrival+112 minimum).
    @Test func scaleTuningUsesBankersRoundingAt22050() {
        let reverb = Reverb(sampleRate: 22_050)
        var input = [Float](repeating: 0, count: 1_024)
        input[0] = 1
        var left = [Float](repeating: 0, count: 1_024)
        var right = [Float](repeating: 0, count: 1_024)
        reverb.process(input: input, outputLeft: &left, outputRight: &right)

        #expect(left[0..<558].allSatisfy { $0 == 0 })
        #expect(left[558] == 1.0)
        #expect(left[638] == 1.0, "1277·0.5 = 638.5 must round HALF-TO-EVEN to 638 (C# Math.Round)")
        #expect(right[0..<570].allSatisfy { $0 == 0 })
        #expect(right[570] == 1.0)
    }

    /// mute() silences all recirculating state: after energizing the banks,
    /// a muted reverb fed zeros emits exactly zeros.
    @Test func muteSilencesTheTail() {
        let reverb = Reverb(sampleRate: 44_100)
        var input = [Float](repeating: 0, count: 2_048)
        input[0] = 1
        var left = [Float](repeating: 0, count: 2_048)
        var right = [Float](repeating: 0, count: 2_048)
        reverb.process(input: input, outputLeft: &left, outputRight: &right)
        #expect(left.contains { $0 != 0 })

        reverb.mute()
        let zeros = [Float](repeating: 0, count: 2_048)
        reverb.process(input: zeros, outputLeft: &left, outputRight: &right)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })
    }
}
