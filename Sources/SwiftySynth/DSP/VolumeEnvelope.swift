import Foundation

/// DAHDSR (Delay, Attack, Hold, Decay, Sustain, Release) amplitude envelope
/// applied per block to a voice.
///
/// Ported from `VolumeEnvelope.cs` (MeltySynth, MIT License — see NOTICE). C#
/// takes a `Synthesizer` reference in its constructor and reads
/// `synthesizer.SampleRate` / `synthesizer.BlockSize` lazily; this port has no
/// `Synthesizer` type yet (DSP is being ported ahead of the top-level synth),
/// so the constructor takes both directly (mirrors the `Oscillator` port's
/// adaptation).
final class VolumeEnvelope {
    private let synthesizerSampleRate: Int
    private let synthesizerBlockSize: Int

    private var attackSlope: Double = 0
    private var decaySlope: Double = 0
    private var releaseSlope: Double = 0

    private var attackStartTime: Double = 0
    private var holdStartTime: Double = 0
    private var decayStartTime: Double = 0
    private var releaseStartTime: Double = 0

    private var sustainLevel: Float = 0
    private var releaseLevel: Float = 0

    private var processedSampleCount: Int = 0
    private var stage: Stage = .delay
    private(set) var value: Float = 0

    private(set) var priority: Float = 0

    init(sampleRate: Int, blockSize: Int) {
        self.synthesizerSampleRate = sampleRate
        self.synthesizerBlockSize = blockSize
    }

    func start(delay: Float, attack: Float, hold: Float, decay: Float, sustain: Float, release: Float) {
        // C# `attackSlope = 1 / attack;` divides two floats (1 promoted from
        // int to float) and only then widens the float result to the double
        // field — NOT the same value as computing the division directly in
        // double. Mirror the float-then-widen order exactly.
        attackSlope = Double(1 / attack)
        // C# `decaySlope = -9.226 / decay;` has a double literal on the left,
        // so `decay` is promoted to double and the whole division happens in
        // double precision.
        decaySlope = -9.226 / Double(decay)
        releaseSlope = -9.226 / Double(release)

        attackStartTime = Double(delay)
        holdStartTime = attackStartTime + Double(attack)
        decayStartTime = holdStartTime + Double(hold)
        releaseStartTime = 0

        sustainLevel = min(max(sustain, 0), 1)
        releaseLevel = 0

        processedSampleCount = 0
        stage = .delay
        value = 0

        process(0)
    }

    func release() {
        stage = .release
        releaseStartTime = Double(processedSampleCount) / Double(synthesizerSampleRate)
        releaseLevel = value
    }

    @discardableResult
    func process() -> Bool {
        process(synthesizerBlockSize)
    }

    @discardableResult
    private func process(_ sampleCount: Int) -> Bool {
        processedSampleCount += sampleCount

        let currentTime = Double(processedSampleCount) / Double(synthesizerSampleRate)

        while stage.rawValue <= Stage.hold.rawValue {
            let endTime: Double
            switch stage {
            case .delay:
                endTime = attackStartTime
            case .attack:
                endTime = holdStartTime
            case .hold:
                endTime = decayStartTime
            case .decay, .release:
                preconditionFailure("Invalid envelope stage.")
            }

            if currentTime < endTime {
                break
            } else {
                stage = Stage(rawValue: stage.rawValue + 1)!
            }
        }

        switch stage {
        case .delay:
            value = 0
            priority = 4 + value
            return true

        case .attack:
            value = Float(attackSlope * (currentTime - attackStartTime))
            priority = 3 + value
            return true

        case .hold:
            value = 1
            priority = 2 + value
            return true

        case .decay:
            value = max(Float(SoundFontMath.expCutoff(decaySlope * (currentTime - decayStartTime))), sustainLevel)
            priority = 1 + value
            return value > SoundFontMath.nonAudible

        case .release:
            value = Float(Double(releaseLevel) * SoundFontMath.expCutoff(releaseSlope * (currentTime - releaseStartTime)))
            priority = value
            return value > SoundFontMath.nonAudible
        }
    }

    private enum Stage: Int {
        case delay
        case attack
        case hold
        case decay
        case release
    }
}
