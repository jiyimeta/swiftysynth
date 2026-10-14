import Testing
@testable import SwiftySynth

struct OscillatorTests {
    /// At pitch == rootKey with equal sample rates the pitch ratio is exactly 1, so the
    /// oscillator must reproduce the source samples scaled by 1/32768 — exactly, because
    /// linear interpolation at integer positions hits the samples.
    @Test func unityPitchReproducesSamples() throws {
        var data = (0..<128).map { Int16($0 * 100) }
        data.append(contentsOf: [Int16](repeating: 0, count: 4)) // guard samples past end (SF2 spec provides 46)
        let osc = Oscillator(sampleRate: 44_100)
        osc.start(data: WaveData(copying: data), loopMode: .noLoop, sampleRate: 44_100,
                  start: 0, end: 128, startLoop: 0, endLoop: 128,
                  rootKey: 60, coarseTune: 0, fineTune: 0, scaleTuning: 100)
        var block = [Float](repeating: 99, count: 64)

        #expect(osc.process(&block, 60) == true)
        for i in 0..<64 {
            expectClose(block[i], Float(data[i]) / 32_768, rel: 1e-6, "sample \(i)")
        }
        #expect(osc.process(&block, 60) == true)
        for i in 0..<64 {
            expectClose(block[i], Float(data[64 + i]) / 32_768, rel: 1e-6, "sample \(64 + i)")
        }
        // 128 source samples are exhausted after 2 blocks — no-loop mode must signal death.
        #expect(osc.process(&block, 60) == false)
    }

    /// Continuous loop: after entering the loop the output is periodic with the loop
    /// length. Asserting periodicity (not absolute phase) keeps the test independent of
    /// the exact wrap bookkeeping while still catching loop-point bugs.
    @Test func continuousLoopIsPeriodic() throws {
        var data = (0..<96).map { Int16(($0 &* 337) % 8_000) }   // non-degenerate waveform
        data.append(contentsOf: [Int16](repeating: 0, count: 4))
        let osc = Oscillator(sampleRate: 44_100)
        osc.start(data: WaveData(copying: data), loopMode: .continuous, sampleRate: 44_100,
                  start: 0, end: 96, startLoop: 32, endLoop: 96,
                  rootKey: 60, coarseTune: 0, fineTune: 0, scaleTuning: 100)
        var out = [Float]()
        var block = [Float](repeating: 0, count: 64)
        for _ in 0..<6 {                                          // 384 samples
            #expect(osc.process(&block, 60) == true)
            out.append(contentsOf: block)
        }
        // Pre-loop region is exact.
        for i in 0..<96 {
            expectClose(out[i], Float(data[i]) / 32_768, rel: 1e-6, "pre-loop sample \(i)")
        }
        // Steady-state periodicity with loop length 64.
        for i in 96..<(384 - 64) {
            expectClose(out[i], out[i + 64], rel: 1e-6, "periodicity at \(i)")
        }
        // The loop region actually contains loop samples (not silence).
        #expect(out[100...].contains { abs($0) > 0.01 })
    }

    /// Item D regression: a malformed font can drive `pitchRatio` to a
    /// non-finite or out-of-range value (a huge `scaleTuning` overflowing
    /// `powf` to +infinity; a zero-`sampleRate` sample header yielding NaN;
    /// a negative one, a negative ratio) — C#'s unchecked `(long)` cast
    /// saturates such values; Swift's `Int64(_:)` traps on them.
    /// `fillBlock` must fold every one of these to a fixed-point ratio of 0
    /// (freezing the read position at its current, already-validated
    /// index) instead of trapping, and the oscillator must keep behaving
    /// normally afterward.
    @Test func fillBlockNeverTrapsOnNonFiniteOrOutOfRangePitchRatio() throws {
        var data = (0..<128).map { Int16($0 * 100) }
        data.append(contentsOf: [Int16](repeating: 0, count: 4)) // guard samples past end
        let osc = Oscillator(sampleRate: 44_100)
        osc.start(data: WaveData(copying: data), loopMode: .noLoop, sampleRate: 44_100,
                  start: 0, end: 128, startLoop: 0, endLoop: 128,
                  rootKey: 60, coarseTune: 0, fineTune: 0, scaleTuning: 100)
        var block = [Float](repeating: 0, count: 64)

        for ratio in [Double.nan, .infinity, 1e300, -4.0] {
            #expect(osc.fillBlock(&block, ratio) == true, "ratio \(ratio) must not trap")
        }
        // The read position froze at an already-validated index rather than
        // walking off into garbage or overflowing — normal playback resumes.
        #expect(osc.fillBlock(&block, 1.0) == true)
    }

    /// One octave up (pitch = rootKey + 12) advances 2 source samples per output sample.
    @Test func octaveUpDoublesTheRate() throws {
        var data = (0..<256).map { Int16($0 * 50) }
        data.append(contentsOf: [Int16](repeating: 0, count: 4))
        let osc = Oscillator(sampleRate: 44_100)
        osc.start(data: WaveData(copying: data), loopMode: .noLoop, sampleRate: 44_100,
                  start: 0, end: 256, startLoop: 0, endLoop: 256,
                  rootKey: 60, coarseTune: 0, fineTune: 0, scaleTuning: 100)
        var block = [Float](repeating: 0, count: 64)
        #expect(osc.process(&block, 72) == true)
        for i in 0..<64 {
            expectClose(block[i], Float(data[2 * i]) / 32_768, rel: 1e-5, "sample \(i)")
        }
    }
}
