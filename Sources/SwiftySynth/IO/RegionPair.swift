/// Combines a `PresetRegion` (relative offsets) with an `InstrumentRegion`
/// (absolute values) into the final per-voice parameters.
///
/// Ported from `RegionPair.cs` (MeltySynth, MIT License — see NOTICE). C#
/// models this as a `readonly struct` holding two class references; the
/// Swift port mirrors that shape as an `internal struct` holding two `final
/// class` references (`PresetRegion`/`InstrumentRegion`, per this package's
/// canon).
///
/// This is the highest-consequence port in the loader: getters here are
/// exactly what a voice reads, and what the G1 oracle-gate (Task 14)
/// compares 1:1 against the dump's `pairs[]`. Three combination rules,
/// copied verbatim from `RegionPair.cs`:
/// - Combined raw access sums the two regions' raw `gs` values (widened to
///   `Int`): `self[g] = Int(instrument[g]) + Int(preset[g])`.
/// - Hz/seconds getters convert the *summed* cents/timecents once
///   (`centsToHertz(self[g])` / `timecentsToSeconds(self[g])`) — never by
///   combining two independently-converted values.
/// - Sample-scope fields (addresses, offsets, `sampleModes`, `rootKey`,
///   `exclusiveClass`) come from `instrument` only; the preset side is never
///   consulted for these.
internal struct RegionPair {
    internal let preset: PresetRegion
    internal let instrument: InstrumentRegion

    internal init(preset: PresetRegion, instrument: InstrumentRegion) {
        self.preset = preset
        self.instrument = instrument
    }

    /// Combined raw generator access: sums the two regions' raw `gs` values.
    /// Mirrors `private int this[GeneratorType] => instrument[g] + preset[g]`.
    private subscript(_ type: GeneratorType) -> Int {
        Int(instrument[type]) + Int(preset[type])
    }

    /// Public-facing name for the same combined raw access as the private subscript above, for
    /// callers outside this file that need the raw (unconverted) summed value — e.g. Task 9's
    /// `Voice.start`, which adds `modulatorSum`'s output to a generator's raw value before applying
    /// the destination-specific unit conversion.
    internal func rawGenerator(_ type: GeneratorType) -> Int {
        self[type]
    }

    /// The merged effective note-on modulator list for this preset+instrument pair (design spec §6):
    /// the plain concatenation of `instrument.modulators` (already fully resolved by
    /// `ModulatorResolver.resolveInstrument` — SF2 defaults, then instrument global/local-zone
    /// supersession) and `preset.modulators` (already fully resolved by
    /// `ModulatorResolver.resolvePreset` — preset global/local-zone supersession). Both lists are
    /// each internally complete per SF2 §9.5.1; the instrument and preset levels combine additively,
    /// not by further supersession, so concatenation is the correct (and only) combination here.
    ///
    /// Deliberately does NOT re-run `ModulatorResolver.addPreset`/`resolvePreset`/`dedupWithinZone` on
    /// `preset.modulators`: those dedup by `isIdentical3` (source/destination/amount-source only,
    /// transform-blind), so doing so would incorrectly collapse two legitimate preset-level entries
    /// that are 3-field-identical but differ in `transform` — a case `preset.modulators` can
    /// genuinely already contain (its own global/local supersession is 4-field, transform-sensitive).
    /// The resulting list may contain multiple entries for the same destination (e.g. an
    /// instrument-level and a preset-level velocity->attenuation modulator); summing those per
    /// destination is `modulatorSum`'s job, not this property's.
    internal var resolvedModulators: [Modulator] {
        instrument.modulators + preset.modulators
    }

    /// Sums `Modulator.output(velocity:key:)` over every effective note-on modulator (instrument +
    /// preset, the same combination `resolvedModulators` describes) targeting `destination` — the
    /// total contribution `Voice.start` (Task 9) adds to that generator's raw value before unit
    /// conversion.
    ///
    /// Deliberately does NOT read `resolvedModulators`: that computed property concatenates
    /// `instrument.modulators + preset.modulators`, allocating a fresh `Array` on every call.
    /// `Voice.start` runs on the render thread (design spec §8: allocation-free), so this iterates
    /// both source arrays directly instead — same two lists, same filter/sum, zero allocation.
    internal func modulatorSum(destination: GeneratorType, velocity: Int, key: Int) -> Float {
        var sum: Float = 0
        for modulator in instrument.modulators where modulator.destination == destination {
            sum += modulator.output(velocity: velocity, key: key)
        }
        for modulator in preset.modulators where modulator.destination == destination {
            sum += modulator.output(velocity: velocity, key: key)
        }
        return sum
    }

    /// Convenience for `Voice.start`'s ON path (design spec §6): adds `type`'s resolved note-on
    /// modulator sum to its raw generator value and clamps the result to `range` (the destination's
    /// SF2 §8.1.3 range) in one call. Every modulated destination in `Voice.start` follows this same
    /// raw-then-clamp shape; centralizing it here keeps each call site to one line and keeps the
    /// arithmetic allocation-free — `modulatorSum`'s two `for` loops over the already-stored
    /// `instrument.modulators`/`preset.modulators` arrays are the only iteration, and `ClosedRange<Float>`
    /// is a value type (no heap allocation).
    internal func modulatedGenerator(
        _ type: GeneratorType, velocity: Int, key: Int, clampedTo range: ClosedRange<Float>
    ) -> Float {
        let raw = Float(rawGenerator(type)) + modulatorSum(destination: type, velocity: velocity, key: key)
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    // MARK: - Instrument-only (sample-scope) members

    internal var sampleStart: Int { instrument.sampleStart }
    internal var sampleEnd: Int { instrument.sampleEnd }
    internal var sampleStartLoop: Int { instrument.sampleStartLoop }
    internal var sampleEndLoop: Int { instrument.sampleEndLoop }

    internal var startAddressOffset: Int { instrument.startAddressOffset }
    internal var endAddressOffset: Int { instrument.endAddressOffset }
    internal var startLoopAddressOffset: Int { instrument.startLoopAddressOffset }
    internal var endLoopAddressOffset: Int { instrument.endLoopAddressOffset }

    // MARK: - Combined (preset + instrument) members

    internal var modulationLfoToPitch: Int { self[.modulationLfoToPitch] }
    internal var vibratoLfoToPitch: Int { self[.vibratoLfoToPitch] }
    internal var modulationEnvelopeToPitch: Int { self[.modulationEnvelopeToPitch] }
    internal var initialFilterCutoffFrequency: Float {
        SoundFontMath.centsToHertz(Float(self[.initialFilterCutoffFrequency]))
    }
    internal var initialFilterQ: Float { 0.1 * Float(self[.initialFilterQ]) }
    internal var modulationLfoToFilterCutoffFrequency: Int { self[.modulationLfoToFilterCutoffFrequency] }
    internal var modulationEnvelopeToFilterCutoffFrequency: Int { self[.modulationEnvelopeToFilterCutoffFrequency] }

    internal var modulationLfoToVolume: Float { 0.1 * Float(self[.modulationLfoToVolume]) }

    internal var chorusEffectsSend: Float { 0.1 * Float(self[.chorusEffectsSend]) }
    internal var reverbEffectsSend: Float { 0.1 * Float(self[.reverbEffectsSend]) }
    internal var pan: Float { 0.1 * Float(self[.pan]) }

    internal var delayModulationLfo: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayModulationLfo])) }
    internal var frequencyModulationLfo: Float { SoundFontMath.centsToHertz(Float(self[.frequencyModulationLfo])) }
    internal var delayVibratoLfo: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayVibratoLfo])) }
    internal var frequencyVibratoLfo: Float { SoundFontMath.centsToHertz(Float(self[.frequencyVibratoLfo])) }
    internal var delayModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayModulationEnvelope])) }
    internal var attackModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.attackModulationEnvelope])) }
    internal var holdModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.holdModulationEnvelope])) }
    internal var decayModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.decayModulationEnvelope])) }
    internal var sustainModulationEnvelope: Float { 0.1 * Float(self[.sustainModulationEnvelope]) }
    internal var releaseModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.releaseModulationEnvelope])) }
    internal var keyNumberToModulationEnvelopeHold: Int { self[.keyNumberToModulationEnvelopeHold] }
    internal var keyNumberToModulationEnvelopeDecay: Int { self[.keyNumberToModulationEnvelopeDecay] }
    internal var delayVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayVolumeEnvelope])) }
    internal var attackVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.attackVolumeEnvelope])) }
    internal var holdVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.holdVolumeEnvelope])) }
    internal var decayVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.decayVolumeEnvelope])) }
    internal var sustainVolumeEnvelope: Float { 0.1 * Float(self[.sustainVolumeEnvelope]) }
    internal var releaseVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.releaseVolumeEnvelope])) }
    internal var keyNumberToVolumeEnvelopeHold: Int { self[.keyNumberToVolumeEnvelopeHold] }
    internal var keyNumberToVolumeEnvelopeDecay: Int { self[.keyNumberToVolumeEnvelopeDecay] }

    internal var initialAttenuation: Float { 0.1 * Float(self[.initialAttenuation]) }

    internal var coarseTune: Int { self[.coarseTune] }

    /// `self[.fineTune] + instrument.sample.pitchCorrection` — the combined
    /// (preset + instrument) raw offset, plus the sample's pitch correction
    /// counted exactly once. Mirrors `RegionPair.cs`'s `FineTune`, which
    /// does NOT reuse `InstrumentRegion.fineTune` (that getter already folds
    /// in `sample.pitchCorrection` on its own) — reusing it here would
    /// double-count the correction.
    internal var fineTune: Int { self[.fineTune] + Int(instrument.sample.pitchCorrection) }

    internal var scaleTuning: Int { self[.scaleTuning] }

    // MARK: - Instrument-only (sample-scope) members, continued

    internal var sampleModes: LoopMode { instrument.sampleModes }
    internal var exclusiveClass: Int { instrument.exclusiveClass }
    internal var rootKey: Int { instrument.rootKey }
}
