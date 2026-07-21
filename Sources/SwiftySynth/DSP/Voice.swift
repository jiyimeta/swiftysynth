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
/// Full-port extension over the spike: reverb/chorus send state
/// (`previousReverbSend`/`currentReverbSend`/`previousChorusSend`/
/// `currentChorusSend` + the instrument send offsets — updated every block
/// now, consumed by the effects bus in Phase 2), `kill()` (the immediate
/// note-off path), `priority` (read by `VoiceCollection`'s steal selection),
/// the hold-pedal release guard, and the MIDI channel index (`channel`)
/// alongside the `Channel` state reference (`channelInfo`).
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

    private(set) var previousReverbSend: Float = 0
    private(set) var previousChorusSend: Float = 0
    private(set) var currentReverbSend: Float = 0
    private(set) var currentChorusSend: Float = 0

    private(set) var exclusiveClass: Int = 0
    private(set) var key: Int = 0
    private var velocity: Int = 0

    /// The MIDI channel INDEX this voice was started on (C# `Voice.channel`) —
    /// `VoiceCollection` compares it for exclusive-class reuse and
    /// `Synthesizer` for per-channel note-off/kill.
    private(set) var channel: Int = 0

    /// The `Channel` state object read every block (C# reads
    /// `synthesizer.Channels[channel]` lazily; this port receives the
    /// reference at `start` — the established no-back-reference adaptation).
    /// Implicitly unwrapped: never read before `start` has run at least once.
    private var channelInfo: Channel!

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

    private var instrumentReverb: Float = 0
    private var instrumentChorus: Float = 0

    // Some instruments require fast cutoff change, which can cause pop noise.
    // This is used to smooth out the cutoff frequency.
    private var smoothedCutoff: Float = 0

    private var voiceState: VoiceState = .playing
    private(set) var voiceLength: Int = 0

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
    ///
    /// `enableModulators` (design spec §6, optional SF2 note-on modulator support) gates a second,
    /// independent computation of `noteGain`/`cutoff`: ON folds `RegionPair.modulatorSum`'s resolved
    /// note-on modulator contributions into the raw `initialAttenuation`/`initialFilterCutoffFrequency`
    /// generators (each clamped to its SF2 §8.1.3 range) before unit conversion, and — since SF2
    /// default #1 (velocity -> initialAttenuation) is always inside that modulator sum unless a font
    /// supersedes it — REPLACES the hardcoded `2 * linearToDecibels(velocity/127)` velocity term rather
    /// than adding to it (adding both would double-count velocity attenuation). Defaults to `false` so
    /// every existing call site (`VoiceTests`, `VoiceCollectionTests`) is unaffected. The OFF branch
    /// below is the EXACT pre-existing body, untouched, preserving every MeltySynth-equivalence oracle
    /// vector (design spec's OFF-path guarantee).
    ///
    /// Scope note (documented partial, per design spec's "Partial fidelity" risk): this task folds
    /// `modulatorSum` into `initialAttenuation` and `initialFilterCutoffFrequency` only — the two
    /// destinations that fix the reported loudness/brightness bug. Other modulator-eligible generators
    /// this method reads raw (`coarseTune`/`fineTune`, `modulationEnvelopeToPitch`/
    /// `modulationEnvelopeToFilterCutoffFrequency`, the `modulationLfoTo*` depths) are left unmodulated
    /// this release; applying them correctly needs each destination's own SF2 §8.1.3 clamp range
    /// (and, for `fineTune`, care not to fold the modulator sum into `sample.pitchCorrection`, which
    /// `RegionPair.fineTune` already bakes in) — deferred rather than guessed at.
    func start(
        region: RegionPair, channel: Int, channelInfo: Channel, data: [Int16], key: Int, velocity: Int,
        enableModulators: Bool = false
    ) {
        self.exclusiveClass = region.exclusiveClass
        self.channel = channel
        self.channelInfo = channelInfo
        self.key = key
        self.velocity = velocity

        if enableModulators {
            // ON path (design spec §6). `filterAttenuation` is a MeltySynth-ism (compensates this
            // filter realization's resonance peak), not an SF2 quantity — kept as-is on purpose
            // (design spec's "Deliberate carry-overs"), so it reads `region.initialFilterQ` directly,
            // with no modulator sum folded in.
            let filterAttenuation = 0.5 * region.initialFilterQ

            if velocity > 0 {
                let attenuationCentibels = min(
                    max(
                        Float(region.rawGenerator(.initialAttenuation))
                            + region.modulatorSum(destination: .initialAttenuation, velocity: velocity, key: key),
                        0
                    ),
                    1440
                )
                noteGain = SoundFontMath.decibelsToLinear(-(0.1 * attenuationCentibels) - filterAttenuation)
            } else {
                noteGain = 0
            }

            let cutoffCents = min(
                max(
                    Float(region.rawGenerator(.initialFilterCutoffFrequency))
                        + region.modulatorSum(destination: .initialFilterCutoffFrequency, velocity: velocity, key: key),
                    1500
                ),
                13500
            )
            cutoff = SoundFontMath.centsToHertz(cutoffCents)
            resonance = SoundFontMath.decibelsToLinear(region.initialFilterQ)
        } else {
            // OFF path — UNCHANGED from the pre-modulator body (byte-identical).
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
        }

        vibLfoToPitch = 0.01 * Float(region.vibratoLfoToPitch)
        modLfoToPitch = 0.01 * Float(region.modulationLfoToPitch)
        modEnvToPitch = 0.01 * Float(region.modulationEnvelopeToPitch)

        modLfoToCutoff = region.modulationLfoToFilterCutoffFrequency
        modEnvToCutoff = region.modulationEnvelopeToFilterCutoffFrequency
        dynamicCutoff = modLfoToCutoff != 0 || modEnvToCutoff != 0

        modLfoToVolume = region.modulationLfoToVolume
        dynamicVolume = modLfoToVolume > 0.05

        instrumentPan = min(max(region.pan, -50), 50)
        instrumentReverb = 0.01 * region.reverbEffectsSend
        instrumentChorus = 0.01 * region.chorusEffectsSend

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

    /// Mirrors `Voice.Kill`: silences the voice with no release phase. The
    /// voice stays in the pool until its next `process()` returns false —
    /// and, critically for stealing, `priority` reads 0 in the meantime, so
    /// a killed voice is always the first steal candidate.
    func kill() {
        noteGain = 0
    }

    /// Mirrors `Voice.Process`: renders one block into `block` and returns
    /// whether the voice is still alive. Copy the block order of operations
    /// exactly. Returning false is the death signal — `VoiceCollection.process()`
    /// swap-compacts the voice out, exactly as C# does.
    func process() -> Bool {
        if noteGain < SoundFontMath.nonAudible {
            return false
        }

        releaseIfNecessary()

        if !volEnv.process() {
            return false
        }

        modEnv.process()
        vibLfo.process()
        modLfo.process()

        let vibPitchChange = (0.01 * channelInfo.modulation + vibLfoToPitch) * vibLfo.value
        let modPitchChange = modLfoToPitch * modLfo.value + modEnvToPitch * modEnv.value
        let channelPitchChange = channelInfo.tune + channelInfo.pitchBend
        let pitch = Float(key) + vibPitchChange + modPitchChange + channelPitchChange
        if !oscillator.process(&block, pitch) {
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
        previousReverbSend = currentReverbSend
        previousChorusSend = currentChorusSend

        // According to the GM spec, the following value should be squared.
        let ve = channelInfo.volume * channelInfo.expression
        let channelGain = ve * ve

        var mixGain = noteGain * channelGain * volEnv.value
        if dynamicVolume {
            let decibels = modLfoToVolume * modLfo.value
            mixGain *= SoundFontMath.decibelsToLinear(decibels)
        }

        let angle = (Float.pi / 200) * (channelInfo.pan + instrumentPan + 50)
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

        currentReverbSend = min(max(channelInfo.reverbSend + instrumentReverb, 0), 1)
        currentChorusSend = min(max(channelInfo.chorusSend + instrumentChorus, 0), 1)

        if voiceLength == 0 {
            previousMixGainLeft = currentMixGainLeft
            previousMixGainRight = currentMixGainRight
            previousReverbSend = currentReverbSend
            previousChorusSend = currentChorusSend
        }

        voiceLength += synthesizerBlockSize

        return true
    }

    /// Mirrors `Voice.ReleaseIfNecessary`: a requested release engages only
    /// after `minimumVoiceDuration` AND while the channel's hold pedal is up.
    private func releaseIfNecessary() {
        if voiceLength < minimumVoiceDuration {
            return
        }

        if voiceState == .releaseRequested && !channelInfo.holdPedal {
            volEnv.release()
            modEnv.release()
            oscillator.release()

            voiceState = .released
        }
    }

    /// Mirrors `Voice.Priority`: 0 for inaudible voices; otherwise the
    /// volume envelope's stage-based priority (Release: the current release
    /// gain 0..1 — quietest tails steal first; Decay/Hold/Attack/Delay:
    /// 1..5 — effectively never stolen while lower-priority candidates
    /// exist). FAITHFUL — this value is what the G-steal gate pins.
    var priority: Float {
        if noteGain < SoundFontMath.nonAudible {
            return 0
        } else {
            return volEnv.priority
        }
    }

    private enum VoiceState {
        case playing
        case releaseRequested
        case released
    }
}
