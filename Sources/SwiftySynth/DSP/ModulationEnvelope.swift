/// DAHDSR (Delay, Attack, Hold, Decay, Sustain, Release) modulation envelope,
/// routed to pitch and filter cutoff (not amplitude) by the voice.
///
/// Ported from `ModulationEnvelope.cs` (MeltySynth, MIT License — see
/// NOTICE). C# takes a `Synthesizer` reference in its constructor and reads
/// `synthesizer.SampleRate` / `synthesizer.BlockSize` lazily; this port has
/// no `Synthesizer` type yet (DSP is being ported ahead of the top-level
/// synth), so the constructor takes both directly (mirrors the
/// `VolumeEnvelope`/`Oscillator` ports' adaptation).
///
/// Shares `VolumeEnvelope`'s DAHDSR stage machine (same stage enum, same
/// stage-advance loop), but the curve shapes are the mod envelope's own —
/// copied verbatim from `ModulationEnvelope.cs`, not shared with
/// `VolumeEnvelope`:
/// - All three slopes (`attackSlope`, `decaySlope`, `releaseSlope`) are
///   plain `1 / x`, whereas `VolumeEnvelope` uses `-9.226 / x` for decay and
///   release (its exponential time-constant).
/// - Decay and release ramp **linearly** to their target, driven by a fixed
///   end time (`decayEndTime`, `releaseEndTime`) computed once and compared
///   against `currentTime`. `VolumeEnvelope` instead ramps **exponentially**
///   via `SoundFontMath.expCutoff` measured from its stage *start* time.
/// - There is no `priority` output here (unlike `VolumeEnvelope`, which
///   feeds voice-stealing priority) — `ModulationEnvelope.cs` has no such
///   field.
final class ModulationEnvelope {
    private let synthesizerSampleRate: Int
    private let synthesizerBlockSize: Int

    private var attackSlope: Double = 0
    private var decaySlope: Double = 0
    private var releaseSlope: Double = 0

    private var attackStartTime: Double = 0
    private var holdStartTime: Double = 0
    private var decayStartTime: Double = 0

    private var decayEndTime: Double = 0
    private var releaseEndTime: Double = 0

    private var sustainLevel: Float = 0
    private var releaseLevel: Float = 0

    private var processedSampleCount: Int = 0
    private var stage: Stage = .delay
    private(set) var value: Float = 0

    init(sampleRate: Int, blockSize: Int) {
        self.synthesizerSampleRate = sampleRate
        self.synthesizerBlockSize = blockSize
    }

    func start(delay: Float, attack: Float, hold: Float, decay: Float, sustain: Float, release: Float) {
        // C# `attackSlope = 1 / attack;` (and the decay/release equivalents)
        // divide an int literal `1` against a float parameter — int
        // promotes to float, so the division happens in float precision,
        // and only the result widens to the double field. This differs from
        // VolumeEnvelope.cs, where `-9.226 / decay` has a double literal on
        // the left, forcing full double-precision division throughout.
        attackSlope = Double(1 / attack)
        decaySlope = Double(1 / decay)
        releaseSlope = Double(1 / release)

        attackStartTime = Double(delay)
        holdStartTime = attackStartTime + Double(attack)
        decayStartTime = holdStartTime + Double(hold)

        decayEndTime = decayStartTime + Double(decay)
        releaseEndTime = Double(release)

        sustainLevel = min(max(sustain, 0), 1)
        releaseLevel = 0

        processedSampleCount = 0
        stage = .delay
        value = 0

        process(0)
    }

    func release() {
        stage = .release
        releaseEndTime += Double(processedSampleCount) / Double(synthesizerSampleRate)
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
            return true

        case .attack:
            value = Float(attackSlope * (currentTime - attackStartTime))
            return true

        case .hold:
            value = 1
            return true

        case .decay:
            value = max(Float(decaySlope * (decayEndTime - currentTime)), sustainLevel)
            return value > SoundFontMath.nonAudible

        case .release:
            value = max(Float(Double(releaseLevel) * releaseSlope * (releaseEndTime - currentTime)), 0)
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
