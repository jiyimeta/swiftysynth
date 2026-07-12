import Foundation

/// Per-note synthesis state: two envelopes, two LFOs, an oscillator, and a
/// filter, wired together into a single mono voice and mixed to stereo by
/// `Synthesizer`.
///
/// Ported from `Voice.cs` (MeltySynth, MIT License — see NOTICE), with
/// `RegionEx.cs`'s `Start` extension helpers folded in as the private
/// `start*` methods below (`startVolumeEnvelope`, `startModulationEnvelope`,
/// `startVibratoLfo`, `startModulationLfo`, `startOscillator`) — this port
/// only needs the `RegionPair`-typed overload of each `RegionEx.cs` helper
/// (the `InstrumentRegion`-typed overloads exist in C# solely to let a
/// bare `InstrumentRegion` stand in for a full `RegionPair` elsewhere in the
/// full library; this spike always constructs a `RegionPair`, so those
/// overloads have no caller here and are omitted).
///
/// Swift-idiom adjustment (SPIKE): C# takes a `Synthesizer` reference in its
/// constructor and threads a `channel: Int` through `Start`, reading
/// `synthesizer.Channels[channel]` lazily every block in `Process`. This port
/// has no `Voice → Synthesizer` back-reference — `Synthesizer` owns its voice
/// pool via strong references, and a back-reference would create a retain
/// cycle (unlike C#'s GC, ARC cannot collect a cycle of only strong
/// references). Instead `Voice` receives `(sampleRate:blockSize:)` directly
/// at construction (mirrors every other DSP component's adaptation in this
/// port: `Oscillator`, `VolumeEnvelope`, `ModulationEnvelope`, `Lfo`,
/// `BiQuadFilter`) and the `Channel` instance directly in `start` (rather
/// than an index into `synthesizer.Channels`), holding a strong reference to
/// it for the voice's lifetime — safe because `Channel` never references its
/// `Voice`s back.
///
/// SPIKE scope narrowing vs `Voice.cs`: this spike's `Synthesizer` has no
/// reverb/chorus bus (`Chorus.cs`/`Reverb.cs` are out of scope), so the
/// `instrumentReverb`/`instrumentChorus`/`previousReverbSend`/
/// `previousChorusSend`/`currentReverbSend`/`currentChorusSend` fields (and
/// their `Start`/`Process` assignments) are dropped entirely — they have no
/// consumer in this port. The mix-gain path they sit alongside in `Voice.cs`
/// (which IS consumed by `Synthesizer.renderBlock`) is unaffected by the
/// omission. `Kill()` (used only by `Synthesizer.NoteOffAll`'s "immediate"
/// path, which is out of this spike's public API) and `Priority`
/// (used only by `VoiceCollection`'s priority-based stealing, itself out of
/// spike scope — see `Synthesizer.requestVoice`) are also dropped.
final class Voice {
    private let volEnv: VolumeEnvelope
    private let modEnv: ModulationEnvelope

    private let vibLfo: Lfo
    private let modLfo: Lfo

    private let oscillator: Oscillator
    private let filter: BiQuadFilter

    private let synthesizerBlockSize: Int
    private let minimumVoiceDuration: Int

    private(set) var block: [Float]

    // A sudden change in the mix gain will cause pop noise.
    // To avoid this, we save the mix gain of the previous block,
    // and smooth out the gain if the gap between the current and previous gain is too large.
    // The actual smoothing process is done in Synthesizer.writeBlock.
    private(set) var previousMixGainLeft: Float = 0
    private(set) var previousMixGainRight: Float = 0
    private(set) var currentMixGainLeft: Float = 0
    private(set) var currentMixGainRight: Float = 0

    private(set) var exclusiveClass: Int = 0
    private(set) var key: Int = 0
    private var velocity: Int = 0

    /// The `Channel` a voice was most recently `start`ed against. Implicitly
    /// unwrapped: never read before `start` has run at least once, mirroring
    /// the established convention in this port (e.g. `Oscillator`'s `data`)
    /// that `process`/`end` are never called before `start`.
    private var channel: Channel!

    private var noteGain: Float = 0

    private var cutoff: Float = 0
    private var resonance: Float = 0

    private var vibLfoToPitch: Float = 0
    private var modLfoToPitch: Float = 0
    private var modEnvToPitch: Float = 0

    private var modLfoToCutoff: Int = 0
    private var modEnvToCutoff: Int = 0
    private var dynamicCutoff: Bool = false

    private var modLfoToVolume: Float = 0
    private var dynamicVolume: Bool = false

    private var instrumentPan: Float = 0

    // Some instruments require fast cutoff change, which can cause pop noise.
    // This is used to smooth out the cutoff frequency.
    private var smoothedCutoff: Float = 0

    private var voiceState: VoiceState = .playing
    private var voiceLength: Int = 0

    private(set) var isActive: Bool = false

    init(sampleRate: Int, blockSize: Int) {
        self.synthesizerBlockSize = blockSize
        self.minimumVoiceDuration = sampleRate / 500

        volEnv = VolumeEnvelope(sampleRate: sampleRate, blockSize: blockSize)
        modEnv = ModulationEnvelope(sampleRate: sampleRate, blockSize: blockSize)

        vibLfo = Lfo(sampleRate: sampleRate, blockSize: blockSize)
        modLfo = Lfo(sampleRate: sampleRate, blockSize: blockSize)

        oscillator = Oscillator(sampleRate: sampleRate)
        filter = BiQuadFilter(sampleRate: sampleRate)

        block = [Float](repeating: 0, count: blockSize)
    }

    /// Mirrors `Voice.Start` with `RegionEx.cs`'s `RegionPair`-typed helpers
    /// folded in inline. Copy every constant/order exactly — this is the
    /// equivalence-critical entry point for a voice's entire parameter set.
    func start(region: RegionPair, channel: Channel, data: [Int16], key: Int, velocity: Int) {
        self.exclusiveClass = region.exclusiveClass
        self.channel = channel
        self.key = key
        self.velocity = velocity

        if velocity > 0 {
            // According to the Polyphone's implementation, the initial attenuation should be reduced to 40%.
            // I'm not sure why, but this indeed improves the loudness variability.
            let sampleAttenuation = 0.4 * region.initialAttenuation
            let filterAttenuation = 0.5 * region.initialFilterQ
            let decibels = 2 * SoundFontMath.linearToDecibels(Float(velocity) / 127) - sampleAttenuation - filterAttenuation
            noteGain = SoundFontMath.decibelsToLinear(decibels)
        } else {
            noteGain = 0
        }

        cutoff = region.initialFilterCutoffFrequency
        resonance = SoundFontMath.decibelsToLinear(region.initialFilterQ)

        vibLfoToPitch = 0.01 * Float(region.vibratoLfoToPitch)
        modLfoToPitch = 0.01 * Float(region.modulationLfoToPitch)
        modEnvToPitch = 0.01 * Float(region.modulationEnvelopeToPitch)

        modLfoToCutoff = region.modulationLfoToFilterCutoffFrequency
        modEnvToCutoff = region.modulationEnvelopeToFilterCutoffFrequency
        dynamicCutoff = modLfoToCutoff != 0 || modEnvToCutoff != 0

        modLfoToVolume = region.modulationLfoToVolume
        dynamicVolume = modLfoToVolume > 0.05

        instrumentPan = min(max(region.pan, -50), 50)
        // SPIKE: instrumentReverb/instrumentChorus (0.01 × region's
        // reverb/chorus effects-send generators) are dropped — see the class
        // doc comment (no reverb/chorus bus in this spike's Synthesizer).

        startVolumeEnvelope(region: region, key: key, velocity: velocity)
        startModulationEnvelope(region: region, key: key, velocity: velocity)
        startVibratoLfo(region: region)
        startModulationLfo(region: region)
        startOscillator(region: region, data: data)
        filter.clearBuffer()
        filter.setLowPassFilter(cutoffFrequency: cutoff, resonance: resonance)

        smoothedCutoff = cutoff

        voiceState = .playing
        voiceLength = 0
        isActive = true
    }

    /// Mirrors `RegionEx.Start(this VolumeEnvelope, RegionPair, int, int)`.
    private func startVolumeEnvelope(region: RegionPair, key: Int, velocity: Int) {
        // If the release time is shorter than 10 ms, it will be clamped to 10 ms to avoid pop noise.
        let delay = region.delayVolumeEnvelope
        let attack = region.attackVolumeEnvelope
        let hold = region.holdVolumeEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeHold, key)
        let decay = region.decayVolumeEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeDecay, key)
        let sustain = SoundFontMath.decibelsToLinear(-region.sustainVolumeEnvelope)
        let release = max(region.releaseVolumeEnvelope, 0.01)

        volEnv.start(delay: delay, attack: attack, hold: hold, decay: decay, sustain: sustain, release: release)
    }

    /// Mirrors `RegionEx.Start(this ModulationEnvelope, RegionPair, int, int)`.
    private func startModulationEnvelope(region: RegionPair, key: Int, velocity: Int) {
        // According to the implementation of TinySoundFont, the attack time should be adjusted by the velocity.
        let delay = region.delayModulationEnvelope
        let attack = region.attackModulationEnvelope * (Float(145 - velocity) / 144)
        let hold = region.holdModulationEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeHold, key)
        let decay = region.decayModulationEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeDecay, key)
        let sustain = 1 - region.sustainModulationEnvelope / 100
        let release = region.releaseModulationEnvelope

        modEnv.start(delay: delay, attack: attack, hold: hold, decay: decay, sustain: sustain, release: release)
    }

    /// Mirrors `RegionEx.StartVibrato(this Lfo, RegionPair, int, int)`.
    private func startVibratoLfo(region: RegionPair) {
        vibLfo.start(delay: region.delayVibratoLfo, frequency: region.frequencyVibratoLfo)
    }

    /// Mirrors `RegionEx.StartModulation(this Lfo, RegionPair, int, int)`.
    private func startModulationLfo(region: RegionPair) {
        modLfo.start(delay: region.delayModulationLfo, frequency: region.frequencyModulationLfo)
    }

    /// Mirrors `RegionEx.Start(this Oscillator, short[], RegionPair)`.
    private func startOscillator(region: RegionPair, data: [Int16]) {
        oscillator.start(
            data: data,
            loopMode: region.sampleModes,
            sampleRate: Int(region.instrument.sample.sampleRate),
            start: region.sampleStart,
            end: region.sampleEnd,
            startLoop: region.sampleStartLoop,
            endLoop: region.sampleEndLoop,
            rootKey: region.rootKey,
            coarseTune: region.coarseTune,
            fineTune: region.fineTune,
            scaleTuning: region.scaleTuning
        )
    }

    /// Mirrors `Voice.End`: note-off → release phase, unless already playing
    /// (or already released).
    func end() {
        if voiceState == .playing {
            voiceState = .releaseRequested
        }
    }

    /// Mirrors `Voice.Process`: renders one block into `block` and returns
    /// whether the voice is still alive. Copy the block order of operations
    /// exactly. Sets `isActive = false` on every death path (mirrors this
    /// port's fixed-pool `Synthesizer` reading `isActive` afterward instead
    /// of separately tracking C#'s `VoiceCollection` swap-compaction).
    func process() -> Bool {
        if noteGain < SoundFontMath.nonAudible {
            isActive = false
            return false
        }

        releaseIfNecessary()

        if !volEnv.process() {
            isActive = false
            return false
        }

        modEnv.process()
        vibLfo.process()
        modLfo.process()

        let vibPitchChange = (0.01 * channel.modulation + vibLfoToPitch) * vibLfo.value
        let modPitchChange = modLfoToPitch * modLfo.value + modEnvToPitch * modEnv.value
        let channelPitchChange = channel.tune + channel.pitchBend
        let pitch = Float(key) + vibPitchChange + modPitchChange + channelPitchChange
        if !oscillator.process(&block, pitch) {
            isActive = false
            return false
        }

        if dynamicCutoff {
            let cents = Float(modLfoToCutoff) * modLfo.value + Float(modEnvToCutoff) * modEnv.value
            let factor = SoundFontMath.centsToMultiplyingFactor(cents)
            let newCutoff = factor * cutoff

            // The cutoff change is limited within x0.5 and x2 to reduce pop noise.
            let lowerLimit = 0.5 * smoothedCutoff
            let upperLimit = 2 * smoothedCutoff
            smoothedCutoff = min(max(newCutoff, lowerLimit), upperLimit)

            filter.setLowPassFilter(cutoffFrequency: smoothedCutoff, resonance: resonance)
        }
        filter.process(&block)

        previousMixGainLeft = currentMixGainLeft
        previousMixGainRight = currentMixGainRight

        // According to the GM spec, the following value should be squared.
        let ve = channel.volume * channel.expression
        let channelGain = ve * ve

        var mixGain = noteGain * channelGain * volEnv.value
        if dynamicVolume {
            let decibels = modLfoToVolume * modLfo.value
            mixGain *= SoundFontMath.decibelsToLinear(decibels)
        }

        let angle = (Float.pi / 200) * (channel.pan + instrumentPan + 50)
        if angle <= 0 {
            currentMixGainLeft = mixGain
            currentMixGainRight = 0
        } else if angle >= SoundFontMath.halfPi {
            currentMixGainLeft = 0
            currentMixGainRight = mixGain
        } else {
            currentMixGainLeft = mixGain * cos(angle)
            currentMixGainRight = mixGain * sin(angle)
        }

        if voiceLength == 0 {
            previousMixGainLeft = currentMixGainLeft
            previousMixGainRight = currentMixGainRight
        }

        voiceLength += synthesizerBlockSize

        return true
    }

    /// Mirrors `Voice.ReleaseIfNecessary`.
    ///
    /// SPIKE: C#'s guard is `voiceState == ReleaseRequested && !channelInfo.HoldPedal`.
    /// `Channel` omits the hold-pedal getter in this port (no CC64 dispatch —
    /// see `Channel.swift`'s doc comment), so the `&& !HoldPedal` half of the
    /// guard is dropped; this port always behaves as if the hold pedal is up.
    private func releaseIfNecessary() {
        if voiceLength < minimumVoiceDuration {
            return
        }

        if voiceState == .releaseRequested {
            volEnv.release()
            modEnv.release()
            oscillator.release()

            voiceState = .released
        }
    }

    private enum VoiceState {
        case playing
        case releaseRequested
        case released
    }
}
