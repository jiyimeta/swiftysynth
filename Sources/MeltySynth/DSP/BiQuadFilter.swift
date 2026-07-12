import Foundation

/// Resonant low-pass filter (RBJ-style biquad) applied per block to each
/// voice's output.
///
/// Ported from `BiQuadFilter.cs` (MeltySynth, MIT License — see NOTICE). C#
/// takes a `Synthesizer` reference in its constructor and reads
/// `synthesizer.SampleRate` lazily in `SetLowPassFilter`; this port has no
/// `Synthesizer` type yet (DSP is being ported ahead of the top-level
/// synth), so the constructor takes the sample rate directly (mirrors the
/// `VolumeEnvelope`/`ModulationEnvelope`/`Oscillator`/`Lfo` ports'
/// adaptation).
final class BiQuadFilter {
    private static let resonancePeakOffset: Float = 1 - 1 / Float(2).squareRoot()

    private let synthesizerSampleRate: Int

    private var active: Bool = false

    private var a0: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0
    private var a4: Float = 0

    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(sampleRate: Int) {
        self.synthesizerSampleRate = sampleRate
    }

    /// Mirrors `BiQuadFilter.ClearBuffer`.
    func clearBuffer() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }

    /// Mirrors `BiQuadFilter.SetLowPassFilter`. Cutoffs at/above
    /// `0.499 * sampleRate` disable the filter entirely (`process` then
    /// passes the block through unchanged); this threshold is above the SF2
    /// default cutoff (13500 cents ≈ 19912.6 Hz at 44.1 kHz), so the filter
    /// is active even for presets that never set a cutoff.
    func setLowPassFilter(cutoffFrequency: Float, resonance: Float) {
        if cutoffFrequency < 0.499 * Float(synthesizerSampleRate) {
            active = true

            // This equation gives the Q value which makes the desired resonance peak.
            // The error of the resultant peak height is less than 3%.
            let q = resonance - BiQuadFilter.resonancePeakOffset / (1 + 6 * (resonance - 1))

            let w = 2 * Float.pi * cutoffFrequency / Float(synthesizerSampleRate)
            let cosw = cos(w)
            let alpha = sin(w) / (2 * q)

            let b0 = (1 - cosw) / 2
            let b1 = 1 - cosw
            let b2 = (1 - cosw) / 2
            let a0 = 1 + alpha
            let a1 = -2 * cosw
            let a2 = 1 - alpha

            setCoefficients(a0: a0, a1: a1, a2: a2, b0: b0, b1: b1, b2: b2)
        } else {
            active = false
        }
    }

    /// Mirrors `BiQuadFilter.Process`. When active, applies the Direct
    /// Form I difference equation sample-by-sample, updating the x1/x2/y1/y2
    /// state in the same order as the C# original. When bypassed, the block
    /// passes through untouched; only the filter's state is primed from the
    /// block's last two samples (so a later `setLowPassFilter` call resumes
    /// continuity without a discontinuity click).
    func process(_ block: inout [Float]) {
        if active {
            for t in 0..<block.count {
                let input = block[t]
                let output = a0 * input + a1 * x1 + a2 * x2 - a3 * y1 - a4 * y2

                x2 = x1
                x1 = input
                y2 = y1
                y1 = output

                block[t] = output
            }
        } else {
            x2 = block[block.count - 2]
            x1 = block[block.count - 1]
            y2 = x2
            y1 = x1
        }
    }

    /// Mirrors `BiQuadFilter.SetCoefficients`. Normalizes the numerator
    /// (`b0`/`b1`/`b2`) and denominator (`a1`/`a2`) coefficients by the
    /// denominator's `a0`, storing them in the fields `process` reads.
    private func setCoefficients(a0: Float, a1: Float, a2: Float, b0: Float, b1: Float, b2: Float) {
        self.a0 = b0 / a0
        self.a1 = b1 / a0
        self.a2 = b2 / a0
        self.a3 = a1 / a0
        self.a4 = a2 / a0
    }
}
