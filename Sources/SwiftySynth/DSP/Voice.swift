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

    private(set) var instrumentReverb: Float = 0
    private(set) var instrumentChorus: Float = 0

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
    /// independent computation of every modulator-eligible parameter this method reads: ON folds
    /// `RegionPair.modulatorSum`'s resolved note-on modulator contributions into each destination's raw
    /// generator value (clamped to its SF2 §8.1.3 range, via `RegionPair.modulatedGenerator`) before
    /// unit conversion, and — since SF2 default #1 (velocity -> initialAttenuation) is always inside
    /// the attenuation modulator sum unless a font supersedes it — REPLACES the hardcoded
    /// `2 * linearToDecibels(velocity/127)` velocity term rather than adding to it (adding both would
    /// double-count velocity attenuation). Defaults to `false` so every existing call site (`VoiceTests`,
    /// `VoiceCollectionTests`) is unaffected. The OFF branch below is the EXACT pre-existing body,
    /// untouched, preserving every MeltySynth-equivalence oracle vector (design spec's OFF-path
    /// guarantee).
    ///
    /// `.initialAttenuation` (destination 48) is the one exception to the generic "raw + modSum,
    /// clamped, then converted" shape above (design spec Task 14, FluidSynth reconciliation): the STATIC
    /// generator term gets the same Polyphone-derived 0.4x reduction the OFF path applies, while the
    /// MODULATOR sum (velocity -> attenuation, incl. default #1) stays at full weight — see the ON
    /// branch's attenuation block below for the derivation and rationale.
    ///
    /// Covered note-on destinations (design spec §6): `initialFilterQ` (9, both `resonance` and
    /// the `filterAttenuation` carry-over now read the MODULATED Q consistently — the real-font bug this
    /// task fixes needs a font's `modEnvToFilterFc` modulator to open a deliberately-dark base filter,
    /// and that filter's own declared Q must track it); `modulationLfoToFilterCutoffFrequency` (10) /
    /// `modulationEnvelopeToFilterCutoffFrequency` (11) — feeding these two DEPTH generators is enough
    /// to flow a modulator's contribution through `Voice.process`'s existing `dynamicCutoff` rendering,
    /// no DSP change needed; the pitch depths (5/6/7); `coarseTune` (51) / `fineTune` (52, modulator sum
    /// applies to the GENERATOR only — `sample.pitchCorrection` is folded in separately, unclamped,
    /// exactly as `RegionPair.fineTune` already does on the OFF path) / `scaleTuning` (56);
    /// `modulationLfoToVolume` (13) / `pan` (17) / `reverbEffectsSend` (16) / `chorusEffectsSend` (15);
    /// and the volume/modulation envelope timecent generators (`startVolumeEnvelope`/
    /// `startModulationEnvelope`, below). Deferred (not yet modulated on either path — read from the raw
    /// generator regardless of `enableModulators`): `sustainVolumeEnvelope` (37) /
    /// `sustainModulationEnvelope` (29); the keynum -> envelope-time scalers
    /// `keyNumberToVolumeEnvelopeHold`/`Decay` (39/40) and `keyNumberToModulationEnvelopeHold`/`Decay`
    /// (31/32); and the LFO delay/frequency generators (21-24, `startVibratoLfo`/`startModulationLfo`
    /// take no `enableModulators` parameter). MuseScore_General's piano needs none of these; wiring them
    /// is left as a follow-up if a font that does surfaces.
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
            // ON path (design spec §6, full note-on destination set).
            let filterQCentibels = region.modulatedGenerator(.initialFilterQ, velocity: velocity, key: key, clampedTo: 0...960)
            let filterQDecibels = 0.1 * filterQCentibels
            // `filterAttenuation` is a MeltySynth-ism (compensates this filter realization's resonance
            // peak), not an SF2 quantity — kept as-is on purpose (design spec's "Deliberate
            // carry-overs"), but now reads the MODULATED Q consistently with `resonance` below.
            let filterAttenuation = 0.5 * filterQDecibels

            if velocity > 0 {
                // Attenuation reconciliation against FluidSynth (Task 14): the STATIC `initialAttenuation`
                // generator gets the SAME Polyphone-derived 0.4x reduction the OFF path applies below
                // (`sampleAttenuation`) — applying it at full (1.0x) weight was making fonts with a large
                // static generator (e.g. MuseScore_General's piano, ~22 dB) render ~13 dB too quiet
                // relative to FluidSynth. The MODULATOR sum (velocity -> attenuation, including SF2
                // default #1 and any font-declared crossfade modulators) stays at FULL weight — it
                // already encodes the intended dynamic range directly, unlike the static generator's
                // Polyphone fudge factor. For a modulator-free, zero-`initialAttenuation` region this
                // collapses to `modAttenDb` alone, which — since default #1 is always present in the sum
                // — equals the OFF path's hardcoded velocity term, preserving the ON == OFF identity.
                let staticAttenDb = 0.4 * (0.1 * Float(region.rawGenerator(.initialAttenuation)))
                let modAttenDb = 0.1 * region.modulatorSum(destination: .initialAttenuation, velocity: velocity, key: key)
                // Upper-bound mirrors the pre-existing 1440 cB (144 dB) SF2 §8.1.3 generator ceiling —
                // far above anything reachable, kept only as a safety clamp against a pathological font.
                let attenDb = min(max(0, staticAttenDb + modAttenDb), 144)
                noteGain = SoundFontMath.decibelsToLinear(-attenDb - filterAttenuation)
            } else {
                noteGain = 0
            }

            let cutoffCents = region.modulatedGenerator(
                .initialFilterCutoffFrequency, velocity: velocity, key: key, clampedTo: 1500...13500)
            cutoff = SoundFontMath.centsToHertz(cutoffCents)
            resonance = SoundFontMath.decibelsToLinear(filterQDecibels)

            vibLfoToPitch = 0.01 * region.modulatedGenerator(
                .vibratoLfoToPitch, velocity: velocity, key: key, clampedTo: -12000...12000)
            modLfoToPitch = 0.01 * region.modulatedGenerator(
                .modulationLfoToPitch, velocity: velocity, key: key, clampedTo: -12000...12000)
            modEnvToPitch = 0.01 * region.modulatedGenerator(
                .modulationEnvelopeToPitch, velocity: velocity, key: key, clampedTo: -12000...12000)

            // Feeding the modulator sum into these two DEPTH generators is enough: `Voice.process`
            // already renders `modEnvToCutoff`/`modLfoToCutoff` -> filter cutoff via `dynamicCutoff`,
            // so a font's `velocity -> modEnvToFilterFc` modulator (the real-font bug's mechanism —
            // opening a deliberately-dark base filter with velocity) flows through unchanged.
            modLfoToCutoff = Int(region.modulatedGenerator(
                .modulationLfoToFilterCutoffFrequency, velocity: velocity, key: key, clampedTo: -12000...12000))
            modEnvToCutoff = Int(region.modulatedGenerator(
                .modulationEnvelopeToFilterCutoffFrequency, velocity: velocity, key: key, clampedTo: -12000...12000))
            dynamicCutoff = modLfoToCutoff != 0 || modEnvToCutoff != 0

            modLfoToVolume = 0.1 * region.modulatedGenerator(
                .modulationLfoToVolume, velocity: velocity, key: key, clampedTo: -960...960)
            dynamicVolume = modLfoToVolume > 0.05

            let panRaw = region.modulatedGenerator(.pan, velocity: velocity, key: key, clampedTo: -500...500)
            instrumentPan = min(max(0.1 * panRaw, -50), 50)
            // `region.reverbEffectsSend`/`chorusEffectsSend` getters bake in the SF2 0.1%->fraction
            // 0.1x scale; `modulatedGenerator` returns the RAW generator, so re-apply that 0.1x
            // (net 0.001x, matching the OFF path below) before the 0.01x send conversion.
            instrumentReverb = 0.001 * region.modulatedGenerator(
                .reverbEffectsSend, velocity: velocity, key: key, clampedTo: 0...1000)
            instrumentChorus = 0.001 * region.modulatedGenerator(
                .chorusEffectsSend, velocity: velocity, key: key, clampedTo: 0...1000)
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
        }

        startVolumeEnvelope(region: region, key: key, velocity: velocity, enableModulators: enableModulators)
        startModulationEnvelope(region: region, key: key, velocity: velocity, enableModulators: enableModulators)
        startVibratoLfo(region: region)
        startModulationLfo(region: region)
        startOscillator(region: region, data: data, key: key, velocity: velocity, enableModulators: enableModulators)
        filter.clearBuffer()
        filter.setLowPassFilter(cutoffFrequency: cutoff, resonance: resonance)

        smoothedCutoff = cutoff

        voiceState = .playing
        voiceLength = 0
    }

    /// Mirrors `RegionEx.Start(this VolumeEnvelope, RegionPair, int, int)`. `enableModulators` (design
    /// spec §6) feeds each timecent generator's modulator sum in before the timecents-to-seconds
    /// conversion, clamped to its SF2 §8.1.3 range (`delay`/`hold` -12000...5000, `attack`/`decay`/
    /// `release` -12000...8000) — the font's own note-on modulators (e.g. a velocity-shortened attack)
    /// are lower-priority than the filter/attenuation set for the reported bug, but still apply. The
    /// OFF branch is the EXACT pre-existing body, byte-identical.
    private func startVolumeEnvelope(region: RegionPair, key: Int, velocity: Int, enableModulators: Bool) {
        // If the release time is shorter than 10 ms, it will be clamped to 10 ms to avoid pop noise.
        let delay: Float
        let attack: Float
        let hold: Float
        let decay: Float
        let release: Float
        if enableModulators {
            delay = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.delayVolumeEnvelope, velocity: velocity, key: key, clampedTo: -12000...5000))
            attack = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.attackVolumeEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000))
            hold = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.holdVolumeEnvelope, velocity: velocity, key: key, clampedTo: -12000...5000))
                * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeHold, key)
            decay = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.decayVolumeEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000))
                * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeDecay, key)
            release = max(
                SoundFontMath.timecentsToSeconds(
                    region.modulatedGenerator(.releaseVolumeEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000)),
                0.01
            )
        } else {
            delay = region.delayVolumeEnvelope
            attack = region.attackVolumeEnvelope
            hold = region.holdVolumeEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeHold, key)
            decay = region.decayVolumeEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToVolumeEnvelopeDecay, key)
            release = max(region.releaseVolumeEnvelope, 0.01)
        }
        let sustain = SoundFontMath.decibelsToLinear(-region.sustainVolumeEnvelope)

        volEnv.start(delay: delay, attack: attack, hold: hold, decay: decay, sustain: sustain, release: release)
    }

    /// Mirrors `RegionEx.Start(this ModulationEnvelope, RegionPair, int, int)`. `enableModulators`
    /// (design spec §6) feeds each timecent generator's modulator sum in before the timecents-to-seconds
    /// conversion (same shape/ranges as `startVolumeEnvelope`), ahead of the existing TinySoundFont
    /// velocity-attack adjustment (kept unchanged, applied to the already-modulated `attack`). The OFF
    /// branch is the EXACT pre-existing body, byte-identical.
    private func startModulationEnvelope(region: RegionPair, key: Int, velocity: Int, enableModulators: Bool) {
        let delay: Float
        let attackBase: Float
        let hold: Float
        let decay: Float
        let release: Float
        if enableModulators {
            delay = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.delayModulationEnvelope, velocity: velocity, key: key, clampedTo: -12000...5000))
            attackBase = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.attackModulationEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000))
            hold = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.holdModulationEnvelope, velocity: velocity, key: key, clampedTo: -12000...5000))
                * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeHold, key)
            decay = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.decayModulationEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000))
                * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeDecay, key)
            release = SoundFontMath.timecentsToSeconds(
                region.modulatedGenerator(.releaseModulationEnvelope, velocity: velocity, key: key, clampedTo: -12000...8000))
        } else {
            delay = region.delayModulationEnvelope
            attackBase = region.attackModulationEnvelope
            hold = region.holdModulationEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeHold, key)
            decay = region.decayModulationEnvelope * SoundFontMath.keyNumberToMultiplyingFactor(region.keyNumberToModulationEnvelopeDecay, key)
            release = region.releaseModulationEnvelope
        }
        // According to the implementation of TinySoundFont, the attack time should be adjusted by the velocity.
        let attack = attackBase * (Float(145 - velocity) / 144)
        let sustain = 1 - region.sustainModulationEnvelope / 100

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

    /// Mirrors `RegionEx.Start(this Oscillator, short[], RegionPair)`. `enableModulators` (design spec
    /// §6) feeds `coarseTune` (51, clamped -120...120 semitones) / `scaleTuning` (56, clamped
    /// 0...1200) modulator sums into their raw generators directly; `fineTune` (52, clamped -99...99
    /// cents) applies its modulator sum to the GENERATOR ONLY, then adds `sample.pitchCorrection`
    /// separately and unclamped — mirrors `RegionPair.fineTune`, which bakes in `pitchCorrection` the
    /// same way on the OFF path, so the correction is never double-clamped or lost. `Oscillator.start`
    /// takes these three as `Float` (not `Int`) specifically so a fractional modulator contribution
    /// isn't rounded away before reaching the pitch computation. The OFF branch is the EXACT
    /// pre-existing body (`Float(...)`-widened for the shared parameter type), byte-identical.
    private func startOscillator(region: RegionPair, data: [Int16], key: Int, velocity: Int, enableModulators: Bool) {
        let coarseTune: Float
        let fineTune: Float
        let scaleTuning: Float
        if enableModulators {
            coarseTune = region.modulatedGenerator(.coarseTune, velocity: velocity, key: key, clampedTo: -120...120)
            let fineTuneGenerator = region.modulatedGenerator(.fineTune, velocity: velocity, key: key, clampedTo: -99...99)
            fineTune = fineTuneGenerator + Float(region.instrument.sample.pitchCorrection)
            scaleTuning = region.modulatedGenerator(.scaleTuning, velocity: velocity, key: key, clampedTo: 0...1200)
        } else {
            coarseTune = Float(region.coarseTune)
            fineTune = Float(region.fineTune)
            scaleTuning = Float(region.scaleTuning)
        }

        oscillator.start(
            data: data,
            loopMode: region.sampleModes,
            sampleRate: Int(region.instrument.sample.sampleRate),
            start: region.sampleStart,
            end: region.sampleEnd,
            startLoop: region.sampleStartLoop,
            endLoop: region.sampleEndLoop,
            rootKey: region.rootKey,
            coarseTune: coarseTune,
            fineTune: fineTune,
            scaleTuning: scaleTuning
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
