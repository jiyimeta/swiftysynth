import Foundation

/// Reads back a loop-point sample at a pitch-shifted rate using linear
/// interpolation between neighboring samples.
///
/// Ported from `Oscillator.cs` (MeltySynth, MIT License — see NOTICE). C#
/// takes a `Synthesizer` reference in its constructor and reads
/// `synthesizer.SampleRate` lazily in `Start`; this port has no
/// `Synthesizer` type yet (DSP is being ported ahead of the top-level
/// synth), so the constructor takes the output sample rate directly. C#
/// also keeps `data` as a nullable `short[]?` force-unwrapped at use; the
/// Swift port stores it as a non-optional `[Int16]` set in `start` (mirrors
/// C#'s actual lifecycle: `Process`/`Release` are never called before
/// `Start`).
final class Oscillator {
    // In this class, fixed-point numbers are used for speed-up.
    // A fixed-point number is expressed by Int64, whose lower 24 bits represent the fraction part,
    // and the rest represent the integer part.
    // For clarity, fixed-point number variables have a suffix "_fp".

    private static let fracBits: Int64 = 24
    private static let fracUnit: Int64 = 1 << fracBits
    private static let fpToSample: Float = 1 / (32_768 * Float(fracUnit))

    private let synthesizerSampleRate: Int

    private var data: [Int16] = []
    private var loopMode: LoopMode = .noLoop
    private var sampleRate: Int = 0
    private var start: Int = 0
    private var end: Int = 0
    private var startLoop: Int = 0
    private var endLoop: Int = 0
    private var rootKey: Int = 0

    private var tune: Float = 0
    private var pitchChangeScale: Float = 0
    private var sampleRateRatio: Float = 0

    private var looping: Bool = false

    private var position_fp: Int64 = 0

    /// - Parameter sampleRate: the synthesizer's OUTPUT sample rate
    ///   (`synthesizer.SampleRate` in C#, read lazily from the injected
    ///   `Synthesizer` in `Start`; here it is supplied directly at
    ///   construction since there is no `Synthesizer` type yet).
    init(sampleRate: Int) {
        self.synthesizerSampleRate = sampleRate
    }

    func start(
        data: [Int16],
        loopMode: LoopMode,
        sampleRate: Int,
        start: Int,
        end: Int,
        startLoop: Int,
        endLoop: Int,
        rootKey: Int,
        coarseTune: Int,
        fineTune: Int,
        scaleTuning: Int
    ) {
        self.data = data
        self.loopMode = loopMode
        self.sampleRate = sampleRate
        self.start = start
        self.end = end
        self.startLoop = startLoop
        self.endLoop = endLoop
        self.rootKey = rootKey

        tune = Float(coarseTune) + 0.01 * Float(fineTune)
        pitchChangeScale = 0.01 * Float(scaleTuning)
        sampleRateRatio = Float(sampleRate) / Float(synthesizerSampleRate)

        if loopMode == .noLoop {
            looping = false
        } else {
            looping = true
        }

        position_fp = Int64(start) << Oscillator.fracBits
    }

    /// Mirrors `Oscillator.Release`. Only `loopUntilNoteOff` stops looping on
    /// release; `continuous` keeps looping and `noLoop` was never looping.
    func release() {
        if loopMode == .loopUntilNoteOff {
            looping = false
        }
    }

    /// Mirrors `Oscillator.Process`. Returns `false` exactly when the voice
    /// must die (no-loop sample exhausted).
    func process(_ block: inout [Float], _ pitch: Float) -> Bool {
        let pitchChange = pitchChangeScale * (pitch - Float(rootKey)) + tune
        let pitchRatio = sampleRateRatio * powf(2, pitchChange / 12)
        return fillBlock(&block, Double(pitchRatio))
    }

    /// Mirrors `Oscillator.FillBlock`.
    func fillBlock(_ block: inout [Float], _ pitchRatio: Double) -> Bool {
        // C# converts with an unchecked `(long)` cast, which saturates (and
        // folds NaN to 0) instead of failing; Swift's `Int64(_:)` traps on
        // any non-finite or out-of-range value. A malformed font can drive
        // `pitchRatio` there (a huge `scaleTuning` overflows `powf` to
        // +infinity; a zero sample-header `sampleRate` yields NaN; a
        // negative one, a negative ratio), so fold that whole tail —
        // non-finite, negative, or >= 2^62 — to 0: the read position
        // freezes at its current already-validated index and the voice ends
        // through the normal envelope/steal path instead of trapping here,
        // overflowing `position_fp += pitchRatio_fp`, or driving the sample
        // index negative — never-trap. Every ratio a well-formed font
        // produces (fixed-point product well under 2^40) converts
        // bit-identically to before.
        let product = Double(Oscillator.fracUnit) * pitchRatio
        let pitchRatio_fp = product >= 0 && product < 0x1p62 ? Int64(product) : 0

        if looping {
            return fillBlockContinuous(&block, pitchRatio_fp)
        } else {
            return fillBlockNoLoop(&block, pitchRatio_fp)
        }
    }

    /// Mirrors `Oscillator.FillBlock_NoLoop`.
    private func fillBlockNoLoop(_ block: inout [Float], _ pitchRatio_fp: Int64) -> Bool {
        for t in 0..<block.count {
            let index = Int(position_fp >> Oscillator.fracBits)

            if index >= end {
                if t > 0 {
                    for i in t..<block.count {
                        block[i] = 0
                    }
                    return true
                } else {
                    return false
                }
            }

            let x1 = Int64(data[index])
            let x2 = Int64(data[index + 1])
            let a_fp = position_fp & (Oscillator.fracUnit - 1)
            block[t] = Oscillator.fpToSample * Float((x1 << Oscillator.fracBits) + a_fp * (x2 - x1))

            position_fp += pitchRatio_fp
        }

        return true
    }

    /// Mirrors `Oscillator.FillBlock_Continuous`.
    private func fillBlockContinuous(_ block: inout [Float], _ pitchRatio_fp: Int64) -> Bool {
        let endLoop_fp = Int64(endLoop) << Oscillator.fracBits

        let loopLength = Int64(endLoop - startLoop)
        let loopLength_fp = loopLength << Oscillator.fracBits

        for t in 0..<block.count {
            if position_fp >= endLoop_fp {
                position_fp -= loopLength_fp
            }

            let index1 = Int(position_fp >> Oscillator.fracBits)
            var index2 = index1 + 1

            if index2 >= endLoop {
                index2 -= Int(loopLength)
            }

            let x1 = Int64(data[index1])
            let x2 = Int64(data[index2])
            let a_fp = position_fp & (Oscillator.fracUnit - 1)
            block[t] = Oscillator.fpToSample * Float((x1 << Oscillator.fracBits) + a_fp * (x2 - x1))

            position_fp += pitchRatio_fp
        }

        return true
    }
}
