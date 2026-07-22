import Foundation
import Testing
@testable import SwiftySynth

/// Task 10 (design spec §Testing item 7): the BEHAVIORAL GUARD — a small, committable synthetic SF2
/// (`SyntheticFont.crossfadeFont`) reproducing the velocity-crossfade pattern that collapsed
/// MuseScore_General's Acoustic Grand Piano (design spec's Problem section). Proves that, with
/// modulators ON, a "piano-like" preset (velocity-split zones + per-zone `pmod`
/// velocity->attenuation crossfade, plus an instrument-level modulator canceling SF2 default #1)
/// renders at loudness parity with a flat "bass-like" preset at mf, and with a MONOTONIC velocity
/// response — the two properties the real font's collapse violated (piano quieter at mf(80) than at
/// pp(49), an inverted response — design spec's measured table).
///
/// Also carries the REQUIRED coordinator carry-forward from the Task-9 review: a test that pins the
/// ON path's FULL-WEIGHT attenuation coefficient, discriminating it from the OFF path's `0.4×`
/// reduction — a regression none of Task 9's own tests (attenuation 0, monotonic-only, amount-0
/// modulators) would have caught.
struct ModulatorBehavioralTests {
    /// **The behavioral guard.** Design spec's empirical gate on the collapse, in miniature: with
    /// modulators ON, does restoring correct per-layer levels actually produce a piano that sounds
    /// like a piano (parity with a flat reference preset at mf, monotonic in velocity) rather than
    /// the real font's inverted, near-silent-at-mf collapse?
    @Test
    func pianoLikeMatchesBassLikeAndIsMonotonic() throws {
        let font = try SyntheticFont.crossfadeFont() // bass-like program 0, piano-like program 1

        let bass80 = try SyntheticFont.presetPeak(font, program: 0, key: 60, velocity: 80, enableModulators: true)
        let piano80 = try SyntheticFont.presetPeak(font, program: 1, key: 60, velocity: 80, enableModulators: true)
        #expect(
            abs(piano80 - bass80) < 6.0,
            "piano-like (\(piano80) dB) must be within 6 dB of bass-like (\(bass80) dB) at mf with modulators ON"
        )

        let p49 = try SyntheticFont.presetPeak(font, program: 1, key: 60, velocity: 49, enableModulators: true)
        let p100 = try SyntheticFont.presetPeak(font, program: 1, key: 60, velocity: 100, enableModulators: true)
        #expect(p100 > piano80, "monotonic: louder at higher velocity (100: \(p100) dB vs 80: \(piano80) dB)")
        #expect(piano80 > p49, "monotonic: louder at higher velocity (80: \(piano80) dB vs 49: \(p49) dB)")

        // Sanity: both notes must actually produce clearly audible output, or the comparisons above
        // could pass trivially near the render noise floor without exercising the modulator path at
        // all (mirrors VoiceModulatorApplyTests's own "offPeak > 1e-3" sanity check, in dB terms).
        #expect(bass80 > -60, "expected bass-like to render clearly audible output at mf, got \(bass80) dB")
        #expect(piano80 > -60, "expected piano-like to render clearly audible output at mf, got \(piano80) dB")
    }

    /// Companion sanity check the brief calls out explicitly: a font that silently loaded with zero
    /// (or the wrong) modulators would make the behavioral guard above a FALSE PASS — it would just
    /// be exercising two differently-attenuated, unmodulated presets, proving nothing about the
    /// modulator engine. Asserts the resolved region-level modulator lists carry exactly the records
    /// the byte layout intends: Bass's instrument keeps SF2 default #1 (960) unmodified; Piano's
    /// instrument SUPERSEDES it to 0 (the canceling `imod`); and each of Piano's two preset zones
    /// carries its own amount-700 crossfade `pmod`.
    @Test
    func crossfadeFontModulatorsSurviveParsing() throws {
        let font = try SyntheticFont.crossfadeFont()

        let bassPreset = try #require(font.presets.first { $0.name == "Bass" })
        let pianoPreset = try #require(font.presets.first { $0.name == "Piano" })

        let bassRegion = try #require(bassPreset.regions.first)
        #expect(bassRegion.modulators.isEmpty, "Bass preset zone carries no preset-level modulators")
        let bassInstrumentRegion = try #require(bassRegion.instrument.regions.first)
        #expect(
            bassInstrumentRegion.modulators.contains { $0.amount == 960 && $0.destination == .initialAttenuation },
            "Bass instrument must still carry SF2 default #1 unmodified (amount 960)"
        )

        #expect(pianoPreset.regions.count == 2, "expected two velocity-split Piano preset regions")
        for region in pianoPreset.regions {
            #expect(
                region.modulators.contains { $0.amount == 700 && $0.destination == .initialAttenuation },
                "each Piano preset zone must carry its own amount-700 velocity->attenuation pmod"
            )
            let instrumentRegion = try #require(region.instrument.regions.first)
            #expect(
                instrumentRegion.modulators.contains { $0.amount == 0 && $0.destination == .initialAttenuation },
                "Piano instrument must carry the canceling (amount 0) modulator"
            )
            #expect(
                !instrumentRegion.modulators.contains { $0.amount == 960 },
                "Piano instrument's default #1 (960) must be SUPERSEDED, not merely added to"
            )
        }
    }

    /// **Destination-11 regression guard (design spec §6, full note-on destination set).** Pins the
    /// `velocity -> modulationEnvelopeToFilterCutoffFrequency` path — the exact mechanism the design
    /// spec's Problem section identifies for the real MuseScore_General piano collapse (a font-declared
    /// `modEnvToFilterFc` modulator opening a deliberately-dark base filter as velocity increases).
    /// `SyntheticFont.crossfadeFont`'s "DarkFilter" program (patch 2) sets a floor-value base filter
    /// (`initialFilterCutoffFrequency` = 1500, ~19 Hz, far below the shared sample's ~344.5 Hz
    /// fundamental at key 60) plus one instrument-local modulator: velocity(minToMax, linear) ->
    /// destination 11, amount 5000. `Voice.process` already renders `modEnvToCutoff` -> filter cutoff
    /// via its existing `dynamicCutoff` path; this test only exercises whether `Voice.start` actually
    /// feeds the resolved modulator sum into that depth generator. Without that (the prior scope-cut
    /// state), the base filter stays fixed at ~19 Hz regardless of velocity, so peak stays flat
    /// (non-monotonic) rather than rising with velocity — this test is RED on that prior state and only
    /// goes GREEN once destination 11 is wired.
    @Test
    func darkBaseFilterOpensWithVelocityViaModEnvToFilterFc() throws {
        let font = try SyntheticFont.crossfadeFont()

        let p49 = try SyntheticFont.presetPeak(font, program: 2, key: 60, velocity: 49, enableModulators: true)
        let p80 = try SyntheticFont.presetPeak(font, program: 2, key: 60, velocity: 80, enableModulators: true)
        let p100 = try SyntheticFont.presetPeak(font, program: 2, key: 60, velocity: 100, enableModulators: true)

        #expect(
            p80 > p49,
            """
            a velocity->modEnvToFilterFc modulator opening a dark base filter must render LOUDER at \
            higher velocity (49: \(p49) dB vs 80: \(p80) dB) — this is the destination-11 path the \
            real-font piano collapse depends on
            """
        )
        #expect(
            p100 > p80,
            "monotonic: louder still at velocity 100 than 80 (80: \(p80) dB vs 100: \(p100) dB)"
        )

        // Sanity: velocity 100 must actually clear the render noise floor, or the comparisons above
        // could pass trivially near silence without the filter ever actually opening.
        #expect(p100 > -60, "expected velocity 100 to render clearly audible output, got \(p100) dB")
    }

    /// **REQUIRED (Task-9 review carry-forward) — pins the ON path's FULL-WEIGHT attenuation
    /// coefficient.** `Voice.start`'s ON branch must compute `-(0.1 * attenuationCentibels)` at FULL
    /// (1.0×) weight, never the OFF branch's `0.4 × region.initialAttenuation` reduction (a
    /// Polyphone-derived fudge factor that the design spec's "Deliberate carry-overs" note calls an
    /// OFF-path-only artifact — the ON path is supposed to use full-weight spec attenuation). Every
    /// one of Task 9's own tests uses attenuation 0, a monotonic-only comparison, or an amount-0
    /// modulator, so a regression that kept the `0.4×` weight on the ON path would pass ALL of them
    /// silently — this is the test that would catch it.
    ///
    /// Uses `SyntheticSF2.minimal(instrumentGenerators:)` with a KNOWN positive raw
    /// `initialAttenuation` generator (100 cB = 10 dB) and NO modulators beyond SF2 default #1 (that
    /// builder's `pmod`/`imod` chunks carry only their terminal, unreferenced record — see its own
    /// doc comment). Because default #1's output is, per the design spec §4 identity already proven
    /// by `VoiceModulatorApplyTests`/`ModulatorTransformTests`, analytically EQUAL to the OFF path's
    /// hardcoded `2 * linearToDecibels(velocity/127)` term, that shared velocity-dependent piece
    /// cancels out of the ON-vs-OFF measured DELTA algebraically:
    ///
    /// ```
    /// OFF_dB = hardcodedVelTerm(v) - 0.4 * (0.1 * 100) - filterAtten   =  hardcodedVelTerm(v) - 4 - filterAtten
    /// ON_dB  = -(0.1 * (100 + modSumDefault1(v))) - filterAtten        =  hardcodedVelTerm(v) - 10 - filterAtten
    /// OFF_dB - ON_dB = -4 - (-10) = 6.0 dB   (exactly, independent of velocity/filterAtten)
    /// ```
    ///
    /// So the 100 cB raw attenuation weighted at 1.0× (ON) vs 0.4× (OFF) predicts an EXACT 6.0 dB
    /// gap between the two rendered peaks. A regression that kept `0.4×` on the ON path would
    /// collapse this measured delta to ~0 dB, well outside the tolerance below.
    @Test
    func onPathAppliesFullWeightAttenuationNotOffPathsPointFourWeight() throws {
        let data = SyntheticSF2.minimal(instrumentGenerators: [(48, 100), (53, 0)])
        let fontOff = try SoundFont(data: data)
        let fontOn = try SoundFont(data: data)

        let settingsOff = try SynthesizerSettings(
            sampleRate: 44_100, enableReverbAndChorus: false, enableModulators: false)
        let settingsOn = try SynthesizerSettings(
            sampleRate: 44_100, enableReverbAndChorus: false, enableModulators: true)

        let synthOff = try Synthesizer(soundFont: fontOff, settings: settingsOff)
        let synthOn = try Synthesizer(soundFont: fontOn, settings: settingsOn)

        synthOff.noteOn(key: 60, velocity: 80, on: 0)
        synthOn.noteOn(key: 60, velocity: 80, on: 0)

        let offPeakDb = peakDb(rendering: synthOff, frames: 2_048)
        let onPeakDb = peakDb(rendering: synthOn, frames: 2_048)
        let measuredDeltaDb = offPeakDb - onPeakDb

        #expect(
            abs(measuredDeltaDb - 6.0) < 0.5,
            """
            expected ON to be ~6.0 dB quieter than OFF (100 cB raw attenuation at FULL 1.0x weight on \
            ON vs 0.4x weight on OFF); measured delta \(measuredDeltaDb) dB (off=\(offPeakDb) on=\(onPeakDb)). \
            A ~0 dB delta means the ON path is still using the OFF path's 0.4x coefficient — a real regression.
            """
        )
    }
}

/// Renders `frames` samples from a fresh note-on and returns the peak absolute sample level in dBFS
/// across both channels — the same render-then-measure shape as `SyntheticFont.presetPeak`, but
/// against an already-started `Synthesizer` (mirrors `VoiceModulatorApplyTests`'s local `peakAbs`,
/// converted to dBFS since this test's assertion is naturally a dB delta).
private func peakDb(rendering synth: Synthesizer, frames: Int) -> Float {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    renderInto(synth, &left, &right, 0..<frames)
    var peak: Float = 0
    for i in 0..<frames {
        peak = max(peak, max(abs(left[i]), abs(right[i])))
    }
    return 20 * log10(max(peak, 1e-9))
}
