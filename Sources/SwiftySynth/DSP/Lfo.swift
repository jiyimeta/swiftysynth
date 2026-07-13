import Foundation

/// Triangle low-frequency oscillator (delay + frequency), routed to
/// pitch/filter/volume modulation by the voice.
///
/// Ported from `Lfo.cs` (MeltySynth, MIT License — see NOTICE). C# takes a
/// `Synthesizer` reference in its constructor and reads
/// `synthesizer.SampleRate` / `synthesizer.BlockSize` lazily; this port has
/// no `Synthesizer` type yet (DSP is being ported ahead of the top-level
/// synth), so the constructor takes both directly (mirrors the
/// `VolumeEnvelope`/`ModulationEnvelope`/`Oscillator` ports' adaptation).
///
/// The triangle wave's phase convention (copied verbatim from `Lfo.cs`):
/// starts at 0 at `phase == 0`, rises linearly to +1 at `phase == 0.25`,
/// falls back through 0 at `phase == 0.5`, reaches −1 at `phase == 0.75`,
/// and rises back to 0 at `phase == 1`. `delay` holds the value at 0 until
/// `currentTime` (measured from the start of oscillation, advancing once
/// per `process()` call by `blockSize` samples) reaches it; the phase clock
/// itself starts counting from `delay`, not from time zero.
final class Lfo {
    private let synthesizerSampleRate: Int
    private let synthesizerBlockSize: Int

    private var active: Bool = false

    private var delay: Double = 0
    private var period: Double = 0

    private var processedSampleCount: Int = 0
    private(set) var value: Float = 0

    init(sampleRate: Int, blockSize: Int) {
        self.synthesizerSampleRate = sampleRate
        self.synthesizerBlockSize = blockSize
    }

    func start(delay: Float, frequency: Float) {
        if frequency > 1.0E-3 {
            active = true

            self.delay = Double(delay)
            self.period = 1.0 / Double(frequency)

            processedSampleCount = 0
            value = 0
        } else {
            active = false
            value = 0
        }
    }

    func process() {
        guard active else {
            return
        }

        processedSampleCount += synthesizerBlockSize

        let currentTime = Double(processedSampleCount) / Double(synthesizerSampleRate)

        if currentTime < delay {
            value = 0
        } else {
            let phase = ((currentTime - delay).truncatingRemainder(dividingBy: period)) / period
            if phase < 0.25 {
                value = Float(4 * phase)
            } else if phase < 0.75 {
                value = Float(4 * (0.5 - phase))
            } else {
                value = Float(4 * (phase - 1.0))
            }
        }
    }
}
