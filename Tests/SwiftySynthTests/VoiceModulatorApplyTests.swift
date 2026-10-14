import Darwin
import Foundation
import Testing
@testable import SwiftySynth

/// Task 9 (design spec §6): `Voice.start`'s gated ON path folds the resolved note-on modulator sums
/// into the raw generators (attenuation, filter cutoff) before unit conversion, replacing the
/// hardcoded velocity-attenuation term with SF2 default #1 (now inside the modulator sum). The OFF
/// path must stay byte-identical to today (every MeltySynth-equivalence oracle vector depends on it).
struct VoiceModulatorApplyTests {
    /// **The key reconciliation test.** `SyntheticSF2.minimal()` builds a region with NO modulators
    /// (`pmod`/`imod` carry only their terminal record) and `initialAttenuation` generator = 0
    /// (`instrumentGenerators` defaults to `[(53, 0)]`, i.e. sampleID only). Per design spec §4, SF2
    /// default #1 (velocity -> initialAttenuation) is always present in `RegionPair.resolvedModulators`
    /// (`ModulatorResolver.resolveInstrument` starts from `DefaultModulators.noteOn`) unless superseded
    /// — and this font has no instrument modulator to supersede it. So the ON path's
    /// `modulatorSum(.initialAttenuation, ...)` evaluates the SAME analytic curve the OFF path computes
    /// via the hardcoded `2 * linearToDecibels(velocity/127)` term (spec §4's proven identity) — the two
    /// paths must produce the same `noteGain` (and therefore the same rendered peak) up to float
    /// evaluation-order ulps, NOT bit-exact (option (b), spec §4).
    @Test
    func onEqualsOffForModulatorFreeZeroAttenuationRegion() throws {
        let data = SyntheticSF2.minimal()
        let fontOff = try SoundFont(data: data)
        let fontOn = try SoundFont(data: data)

        let settingsOff = try SynthesizerSettings(sampleRate: 44_100, enableModulators: false)
        let settingsOn = try SynthesizerSettings(sampleRate: 44_100, enableModulators: true)

        let synthOff = try Synthesizer(soundFont: fontOff, settings: settingsOff)
        let synthOn = try Synthesizer(soundFont: fontOn, settings: settingsOn)

        synthOff.noteOn(key: 60, velocity: 80, on: 0)
        synthOn.noteOn(key: 60, velocity: 80, on: 0)

        let offPeak = peakAbs(rendering: synthOff, frames: 2_048)
        let onPeak = peakAbs(rendering: synthOn, frames: 2_048)

        #expect(
            abs(onPeak - offPeak) < 1e-4,
            "ON (\(onPeak)) must equal OFF (\(offPeak)) within tolerance for a modulator-free, zero-attenuation region")
        // Sanity: the note must actually produce audible output, or the comparison above would
        // trivially pass at 0 == 0 without exercising the noteGain computation at all.
        #expect(offPeak > 1e-3, "expected the OFF-path note to render nonzero peak amplitude")
    }

    /// Sanity check (not the core identity): with modulators ON, a region whose `initialAttenuation`
    /// generator is a positive raw value must render quieter than the zero-attenuation region above —
    /// proving the ON path's `attenCB = clamp(raw + modSum, 0, 1440)` term actually reduces `noteGain`
    /// rather than being a no-op.
    @Test
    func onIsQuieterWithPositiveAttenuationGenerator() throws {
        let zeroAttenFont = try SoundFont(data: SyntheticSF2.minimal())
        // Raw generator value 200 (cB) == 20 dB of attenuation (RegionPair.initialAttenuation is
        // 0.1 * raw, converting cB to dB) — well above render noise floor, comfortably below the
        // [0, 1440] clamp ceiling.
        let attenuatedFont = try SoundFont(
            data: SyntheticSF2.minimal(instrumentGenerators: [(48, 200), (53, 0)]))

        let settingsOn = try SynthesizerSettings(sampleRate: 44_100, enableModulators: true)

        let synthZero = try Synthesizer(soundFont: zeroAttenFont, settings: settingsOn)
        let synthAttenuated = try Synthesizer(soundFont: attenuatedFont, settings: settingsOn)

        synthZero.noteOn(key: 60, velocity: 80, on: 0)
        synthAttenuated.noteOn(key: 60, velocity: 80, on: 0)

        let zeroPeak = peakAbs(rendering: synthZero, frames: 2_048)
        let attenuatedPeak = peakAbs(rendering: synthAttenuated, frames: 2_048)

        #expect(
            attenuatedPeak < zeroPeak,
            "a positive initialAttenuation generator (\(attenuatedPeak)) must render quieter than the zero-attenuation region (\(zeroPeak)) on the ON path")
    }

    /// **The discriminating test.** Unlike the two tests above (which pass whether or not the ON path
    /// is actually implemented, since a modulator-free region makes the ON and OFF formulas coincide
    /// even with no gating at all), this one can ONLY pass once `Voice.start` genuinely reads
    /// `modulatorSum` on the ON path: the region carries an instrument-level velocity->initialAttenuation
    /// modulator with amount 0 — the exact 4-field shape MuseScore_General's piano instrument uses
    /// (design spec, Problem section) to cancel velocity-driven attenuation entirely. With modulators
    /// ON, `attenCB` must be velocity-INVARIANT (always 0 regardless of velocity), so `noteGain` — and
    /// therefore rendered peak — must be the same at a low and a high velocity. With modulators OFF,
    /// the hardcoded curve must still vary with velocity regardless of any modulator (it never reads
    /// modulators at all).
    @Test
    func onPathReadsModulatorSumMakingCancelingRegionVelocityInvariant() throws {
        let (pair, data) = try makeCancelingAttenuationRegionPair()

        // `Voice.process` writes the RAW filtered-oscillator waveform into `block` — `noteGain` is
        // folded in only as `currentMixGainLeft`/`currentMixGainRight` (mirrors what
        // `Synthesizer.writeBlock` mixes in later), so the peak must multiply the two together to
        // reflect `noteGain`'s effect at all.
        func peak(velocity: Int, enableModulators: Bool) -> Float {
            let voice = Voice(sampleRate: 44_100, blockSize: 64)
            voice.start(
                region: pair, channel: 0, channelInfo: Channel(isPercussionChannel: false),
                data: data, key: 60, velocity: velocity, enableModulators: enableModulators)
            var maxPeak: Float = 0
            for _ in 0..<20 {
                guard voice.process() else { break }
                let blockPeak = voice.block.reduce(Float(0)) { max($0, abs($1)) }
                let gain = max(voice.currentMixGainLeft, voice.currentMixGainRight)
                maxPeak = max(maxPeak, blockPeak * gain)
            }
            return maxPeak
        }

        let onLow = peak(velocity: 20, enableModulators: true)
        let onHigh = peak(velocity: 110, enableModulators: true)
        #expect(
            abs(onLow - onHigh) < 1e-5,
            "a canceling velocity->attenuation modulator (amount 0) must make the ON-path noteGain velocity-invariant: low-velocity peak \(onLow) vs high-velocity peak \(onHigh)")

        let offLow = peak(velocity: 20, enableModulators: false)
        let offHigh = peak(velocity: 110, enableModulators: false)
        #expect(
            offLow < offHigh - 1e-3,
            "the OFF path must still vary with velocity via the hardcoded curve regardless of any modulator: low-velocity peak \(offLow) vs high-velocity peak \(offHigh)")
    }

    /// **Allocation-free regression (design spec §5/§8).** `Voice.start` runs on the render thread via
    /// the sequencer; `RegionPair.modulatorSum` must iterate `instrument.modulators`/`preset.modulators`
    /// directly rather than reading `resolvedModulators` (which concatenates the two into a fresh
    /// `Array` on every call). Same bounded-retry, process-global `malloc_zone_statistics` technique as
    /// `RealTimeSafetyTests.zeroAllocationAfterWarmup` (non-strict variant): any one non-positive
    /// measured window is a sufficient clean witness; every window positive means a real render-path
    /// allocation. Uses the synthetic in-memory font so this runs without the (uncommitted)
    /// GeneralUser-GS fixture.
    @Test
    func onPathNoteOnAndRenderAllocateNothingAfterWarmup() throws {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        let settings = try SynthesizerSettings(sampleRate: 44_100, enableModulators: true)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        func cycle() {
            for i in 0..<200 {
                if i % 20 == 0 { synth.noteOn(key: 60 + (i % 12), velocity: 80, on: 0) }
                renderInto(synth, &left, &right, 0..<512)
            }
        }

        cycle()   // warm-up: no lazy first-touch allocation should survive into the measured windows

        func measureWindow() -> (blocks: Int, size: Int) {
            var before = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &before)
            cycle()
            var after = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &after)
            return (
                Int(after.blocks_in_use) - Int(before.blocks_in_use),
                Int(after.size_in_use) - Int(before.size_in_use)
            )
        }

        var windows: [(blocks: Int, size: Int)] = []
        for _ in 0..<8 {
            let delta = measureWindow()
            windows.append(delta)
            if delta.blocks <= 0 && delta.size <= 0 { break }
            cycle()   // drain: let this window's frees settle outside the next measured span
        }

        let cleanWindow = windows.first { $0.blocks <= 0 && $0.size <= 0 }
        #expect(
            cleanWindow != nil,
            "every one of \(windows.count) measured windows netted a positive malloc-zone delta with enableModulators=true — modulatorSum (or Voice.start's ON path) is not allocation-free. windows=\(windows)")
    }

    /// **C1 pin test (critical correctness fix).** `RegionPair.reverbEffectsSend`/`chorusEffectsSend`
    /// (`RegionPair.swift:125-126`) bake in the SF2 0.1x centibel->fraction scale, so the OFF path's
    /// `0.01 * region.reverbEffectsSend` (`Voice.swift`'s OFF branch) nets **0.001x** the raw
    /// generator. The ON path instead reads the RAW generator via `modulatedGenerator` (no 0.1x baked
    /// in), so it must explicitly re-apply that 0.1x — i.e. also net 0.001x — to match. Before this
    /// fix the ON path used `0.01 *` directly on the raw generator (net 0.01x, 10x the OFF path),
    /// which — given the downstream `min(max(channelInfo.reverbSend + instrumentReverb, 0), 1)` clamp
    /// in `Voice.process` — silently pushed most real-font presets (e.g. MuseScore_General's 312
    /// preset `reverbEffectsSend` generators, values 20-600) to near-full-wet reverb once modulators
    /// were enabled. Uses a modulator-free region (no `pmod`/`imod` records at all) so
    /// `modulatedGenerator`'s `modulatorSum` term is always 0 and the assertion isolates the unit-
    /// conversion arithmetic alone.
    @Test
    func onPathSendConversionMatchesOffPathNotTenTimesLarger() throws {
        let (pair, data) = try makeSendRegionPair()

        let voiceOn = Voice(sampleRate: 44_100, blockSize: 64)
        voiceOn.start(
            region: pair, channel: 0, channelInfo: Channel(isPercussionChannel: false),
            data: data, key: 60, velocity: 80, enableModulators: true)

        let voiceOff = Voice(sampleRate: 44_100, blockSize: 64)
        voiceOff.start(
            region: pair, channel: 0, channelInfo: Channel(isPercussionChannel: false),
            data: data, key: 60, velocity: 80, enableModulators: false)

        // Raw reverbEffectsSend generator = 500 -> 0.001 * 500 = 0.5; raw chorusEffectsSend = 300 ->
        // 0.001 * 300 = 0.3. The pre-fix ON path would have produced 5.0 / 3.0 instead (10x too large).
        #expect(
            abs(voiceOn.instrumentReverb - 0.5) < 1e-5,
            "ON reverb send \(voiceOn.instrumentReverb) must equal 0.001 * raw(500) = 0.5, NOT 10x that (5.0)")
        #expect(
            abs(voiceOn.instrumentChorus - 0.3) < 1e-5,
            "ON chorus send \(voiceOn.instrumentChorus) must equal 0.001 * raw(300) = 0.3, NOT 10x that (3.0)")
        #expect(
            abs(voiceOn.instrumentReverb - voiceOff.instrumentReverb) < 1e-5,
            "ON reverb send (\(voiceOn.instrumentReverb)) must match the OFF path (\(voiceOff.instrumentReverb)) — both net 0.001x the raw generator")
        #expect(
            abs(voiceOn.instrumentChorus - voiceOff.instrumentChorus) < 1e-5,
            "ON chorus send (\(voiceOn.instrumentChorus)) must match the OFF path (\(voiceOff.instrumentChorus)) — both net 0.001x the raw generator")
    }
}

/// Renders `frames` samples from a fresh note-on and returns the peak absolute sample across both
/// channels — the same render helper shape as `RealTimeSafetyTests`/`FixtureSupport`'s `renderInto`.
private func peakAbs(rendering synth: Synthesizer, frames: Int) -> Float {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    renderInto(synth, &left, &right, 0..<frames)
    let peakLeft = left.reduce(Float(0)) { max($0, abs($1)) }
    let peakRight = right.reduce(Float(0)) { max($0, abs($1)) }
    return max(peakLeft, peakRight)
}

/// Direct-construction `RegionPair` (mirrors `RegionPairModulatorTests.makeRegionPair`'s shape) whose
/// instrument region carries exactly one note-on modulator: velocity -> initialAttenuation, amount 0
/// (`makeVelocityToAttenuationModulator`, `Tests/.../Support/ModulatorTestSupport.swift`) — passed
/// directly as the region's already-resolved modulator set (bypassing `ModulatorResolver`, which is
/// Task 8's own tested concern). `data` is a small nonzero synthetic waveform long enough to back the
/// sample header's `end`/`endLoop` bounds.
private func makeCancelingAttenuationRegionPair() throws -> (RegionPair, WaveData) {
    let data = WaveData(copying: (0..<1_100).map { i in Int16(truncatingIfNeeded: (i % 20) * 1_000 - 9_000) })
    let header = SampleHeader(
        name: "S", start: 0, end: 1_000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: 0, link: 0, sampleType: 1)
    let instrumentRegion = try InstrumentRegion(
        global: [], local: [Generator(type: .sampleID, value: 0)], samples: [header],
        modulators: [makeVelocityToAttenuationModulator(amount: 0)])
    let instrument = try Instrument(
        name: "I", zones: [Zone(generators: [Generator(type: .sampleID, value: 0)])], samples: [header])
    let presetRegion = try PresetRegion(
        global: [], local: [Generator(type: .instrument, value: 0)], instruments: [instrument])
    return (RegionPair(preset: presetRegion, instrument: instrumentRegion), data)
}

/// Direct-construction `RegionPair` (same shape as `makeCancelingAttenuationRegionPair` above) for the
/// C1 reverb/chorus-send pin test: an instrument region with static `reverbEffectsSend` (raw 500) and
/// `chorusEffectsSend` (raw 300) generators and NO modulators at all — isolating the ON path's send
/// unit-conversion arithmetic from any modulator-sum contribution.
private func makeSendRegionPair() throws -> (RegionPair, WaveData) {
    let data = WaveData(copying: (0..<1_100).map { i in Int16(truncatingIfNeeded: (i % 20) * 1_000 - 9_000) })
    let header = SampleHeader(
        name: "S", start: 0, end: 1_000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: 0, link: 0, sampleType: 1)
    let instrumentRegion = try InstrumentRegion(
        global: [], local: [
            Generator(type: .sampleID, value: 0),
            Generator(type: .reverbEffectsSend, value: 500),
            Generator(type: .chorusEffectsSend, value: 300),
        ], samples: [header])
    let instrument = try Instrument(
        name: "I", zones: [Zone(generators: [Generator(type: .sampleID, value: 0)])], samples: [header])
    let presetRegion = try PresetRegion(
        global: [], local: [Generator(type: .instrument, value: 0)], instruments: [instrument])
    return (RegionPair(preset: presetRegion, instrument: instrumentRegion), data)
}
