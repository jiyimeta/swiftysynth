import Foundation
@testable import SwiftySynth

/// Synthetic in-memory SF2 fixture for the modulator BEHAVIORAL GUARD (design spec
/// `docs/superpowers/specs/2026-07-22-sf2-note-on-modulators-design.md` §Testing item 7 — task 10 of
/// the SF2 note-on-modulators plan).
///
/// Complements `SyntheticSF2` (`SyntheticSoundFontTests.swift`): that builder is deliberately
/// single-preset/single-instrument/single-zone, with `pmod`/`imod` chunks that carry only a
/// terminal (all-zero, unreferenced) record — exactly what Tasks 1-9's unit tests needed. This
/// feature's behavioral guard instead needs TWO presets, REAL `pmod`/`imod` modulator records that a
/// zone actually references, and velocity-split PRESET zones — a structurally different font, so
/// this is a sibling builder rather than an extension of `SyntheticSF2.minimal`'s fixed single-zone
/// shape.
enum SyntheticFont {
    /// Builds (and loads) a font with two GM-style programs sharing ONE 128-sample sine-loop PCM
    /// sample, reproducing the velocity-crossfade pattern that collapsed MuseScore_General's
    /// Acoustic Grand Piano (design spec's Problem section):
    ///
    /// - **program 0 ("Bass"), bank 0** — one full-range preset zone, `initialAttenuation` generator
    ///   = 0, no preset modulators; its instrument has no modulators of its own either. So its ONLY
    ///   velocity-driven attenuation is SF2 default modulator #1 (`DefaultModulators.noteOn`),
    ///   applied unmodified. This mirrors the real MuseScore_General "Fingered Bass" — 0 dB
    ///   `initialAttenuation`, no modulators — the font's flat reference preset (design spec's
    ///   Problem section table).
    ///
    /// - **program 1 ("Piano"), bank 0** — its instrument carries a GLOBAL zone with ONE modulator:
    ///   velocity -> initialAttenuation, amount 0 — the IDENTICAL 4-field shape as SF2 default #1
    ///   (source 0x0502 / dest 48 / amountSource none / transform linear), so
    ///   `ModulatorResolver.resolveInstrument` SUPERSEDES the default with it, canceling the
    ///   instrument's own velocity-driven attenuation entirely (the real MuseScore_General piano's
    ///   own technique, per the design spec's Problem section: "imod: velocity(concave,max→min) ->
    ///   initialAttenuation, amount=0 ... superseding the defaults to zero"). On top of that, the
    ///   PRESET has TWO velocity-split zones (generator 44, `velocityRange`: 0-79 and 80-127), each
    ///   carrying its own `pmod` velocity->initialAttenuation modulator (amount 700, concave,
    ///   maxToMin — the real font's crossfade shape) plus its own static preset `initialAttenuation`
    ///   generator: zone A (the quieter low-velocity "layer") = 60 cB, zone B (the louder
    ///   high-velocity "layer") = 0 cB.
    ///
    ///   With modulators OFF, "Piano" has no modulators to apply at all (this port only ever applies
    ///   modulators when `enableModulators` is on) and renders through the unmodified hardcoded
    ///   velocity curve like every other font — losing every one of these deliberately-authored
    ///   per-zone dynamics. That loss (mechanism, not exact numbers) is the collapse this feature
    ///   fixes; `ModulatorBehavioralTests` exercises the ON path only, proving parity + monotonicity
    ///   there.
    ///
    /// - **program 2 ("DarkFilter"), bank 0** — the destination-11 regression guard (design spec §6's
    ///   full note-on destination set): one full-range preset zone with no preset-level generators or
    ///   modulators of its own, pointing at a THIRD instrument whose single local zone carries a
    ///   deliberately dark base filter (`initialFilterCutoffFrequency` generator = 1500, the SF2 §8.1.3
    ///   floor, ~19 Hz — far below the shared sample's ~344.5 Hz played-back fundamental at key 60) PLUS
    ///   TWO note-on modulators: (1) velocity -> initialAttenuation, amount 0 — the SAME canceling
    ///   shape Piano's global zone uses, REQUIRED here so SF2 default #1 (already in scope even before
    ///   this feature's full destination set) cannot make the note louder at higher velocity on its
    ///   own — without it this test would pass whether or not destination 11 is wired at all, pinning
    ///   nothing; (2) velocity(minToMax, linear) -> `modulationEnvelopeToFilterCutoffFrequency`
    ///   (destination 11), amount 5000, the exact real-font mechanism the design spec's Problem section
    ///   describes: a font-declared `modEnvToFilterFc` modulator that OPENS a dark base filter as
    ///   velocity increases, riding on `Voice.process`'s existing `dynamicCutoff` rendering (which reads
    ///   the modulated `modEnvToCutoff` generator this feature now feeds — no DSP change needed, only
    ///   `Voice.start` feeding the modulator sum into that depth generator). With modulators ON, higher
    ///   velocity -> a larger modulation-envelope-driven cutoff excursion -> a brighter/louder note; with
    ///   modulators OFF (or before this feature's dest-11 wiring), the base filter stays fixed at ~19 Hz
    ///   regardless of velocity AND attenuation is velocity-invariant (modulator 1), so the note stays
    ///   uniformly near-silent — flat, not monotonic. Q is left at its default (raw 0 -> 0 dB, unity
    ///   resonance) so the filter's magnitude response at the fixed test frequency is monotonic in
    ///   cutoff with no resonance-peak crossover to complicate the assertion.
    static func crossfadeFont() throws -> SoundFont {
        try SoundFont(data: crossfadeFontData())
    }

    // MARK: - Render + peak measurement

    /// Renders one note — program change on channel 0 (bank 0 explicit via CC0/CC32, though the
    /// channel already defaults to bank 0), then a single `noteOn` — through `font` and returns the
    /// peak absolute sample level in dBFS across both channels. Dry (`enableReverbAndChorus: false`)
    /// so the number isolates the voice's own gain (velocity curve + modulator sum + attenuation),
    /// the same dry-peak convention the example `LoudnessProbe` uses for the same reason.
    static func presetPeak(
        _ font: SoundFont, program: Int, key: Int, velocity: Int, enableModulators: Bool,
        sampleRate: Int = 44_100, seconds: Double = 0.05
    ) throws -> Float {
        let settings = try SynthesizerSettings(
            sampleRate: sampleRate, enableReverbAndChorus: false, enableModulators: enableModulators)
        let synth = try Synthesizer(soundFont: font, settings: settings)

        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0, data2: 0) // bank select MSB 0
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 32, data2: 0) // bank select LSB 0
        synth.processMidiMessage(channel: 0, command: 0xC0, data1: program, data2: 0)
        synth.noteOn(key: key, velocity: velocity, on: 0)

        let total = Int(Double(sampleRate) * seconds)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        renderInto(synth, &left, &right, 0..<total)

        var peak: Float = 0
        for i in 0..<total {
            peak = max(peak, max(abs(left[i]), abs(right[i])))
        }
        return 20 * log10(max(peak, 1e-9))
    }

    // MARK: - Byte assembly

    /// A `pmod`/`imod` velocity -> initialAttenuation record (concave, maxToMin, unipolar; amount-
    /// source none; transform linear) — the SF2 default #1 shape (source word `0x0502`, destination
    /// generator 48) at a caller-chosen `amount`. Reused for the piano instrument's canceling
    /// modulator (amount 0, superseding the default) and both preset zones' crossfade modulators
    /// (amount 700, additive on top of whatever the instrument level contributes).
    private static func velocityToAttenuationModulatorBytes(amount: Int16) -> [UInt8] {
        var w = ByteWriter()
        w.u16(0x0502) // srcOper: index 2 (velocity), CC clear, direction maxToMin, curve concave
        w.u16(48) // destOper: initialAttenuation
        w.i16(amount)
        w.u16(0) // amtSrcOper: none
        w.u16(0) // transformOper: linear
        return [UInt8](w.data)
    }

    /// A `pmod`/`imod` velocity -> `modulationEnvelopeToFilterCutoffFrequency` (destination 11) record
    /// (linear, minToMax, unipolar; amount-source none; transform linear) — the "DarkFilter" program's
    /// dest-11 regression fixture (see `crossfadeFont`'s doc comment): higher velocity produces a larger
    /// positive contribution to the modulation-envelope-to-cutoff DEPTH generator, opening the
    /// instrument's dark base filter wider as velocity increases.
    private static func velocityToModEnvFilterCutoffModulatorBytes(amount: Int16) -> [UInt8] {
        var w = ByteWriter()
        w.u16(0x0002) // srcOper: index 2 (velocity), CC clear, direction minToMax, curve linear
        w.u16(11) // destOper: modulationEnvelopeToFilterCutoffFrequency
        w.i16(amount)
        w.u16(0) // amtSrcOper: none
        w.u16(0) // transformOper: linear
        return [UInt8](w.data)
    }

    /// Packs a `keyRange`/`velocityRange`-style generator value: low byte = range start, high byte =
    /// range end (mirrors `PresetRegion.velocityRangeStart`/`velocityRangeEnd`'s decode).
    private static func range(_ start: UInt8, _ end: UInt8) -> UInt16 {
        UInt16(start) | (UInt16(end) << 8)
    }

    private static func crossfadeFontData() -> Data {
        // sdta ---------------------------------------------------------------------------------
        // One 128-sample sine cycle (a seamless loop point — value(0) == value(128) up to
        // rounding) plus 4 padding samples so `SoundFont.checkSamples`'s `waveData.count - 4`
        // safety margin covers `endLoop == 128` exactly (see `SyntheticSF2`'s own doc comment on
        // this same margin in SyntheticSoundFontTests.swift).
        var smpl = ByteWriter()
        for i in 0..<132 {
            let value = 16_000 * sin(2 * Double.pi * Double(i) / 128)
            smpl.i16(Int16(value.rounded()))
        }
        var sdta = ByteWriter()
        sdta.fourCC("sdta")
        sdta.chunk("smpl", smpl)

        // INFO ---------------------------------------------------------------------------------
        var ifil = ByteWriter()
        ifil.u16(2)
        ifil.u16(1)
        var inam = ByteWriter()
        inam.fixedString("Crossfade Font", length: 20)
        var info = ByteWriter()
        info.fourCC("INFO")
        info.chunk("ifil", ifil)
        info.chunk("INAM", inam)

        // pdta: phdr (presets: Bass patch 0, Piano patch 1, EOP terminator) ---------------------
        var phdr = ByteWriter()
        func presetRecord(_ name: String, patch: UInt16, bank: UInt16, zoneStart: UInt16) {
            phdr.fixedString(name, length: 20)
            phdr.u16(patch)
            phdr.u16(bank)
            phdr.u16(zoneStart)
            phdr.u32(0)
            phdr.u32(0)
            phdr.u32(0)
        }
        presetRecord("Bass", patch: 0, bank: 0, zoneStart: 0)
        presetRecord("Piano", patch: 1, bank: 0, zoneStart: 1)
        presetRecord("DarkFilter", patch: 2, bank: 0, zoneStart: 3)
        presetRecord("EOP", patch: 0, bank: 0, zoneStart: 4) // terminator: total preset-zone count

        // pdta: pbag/pmod/pgen — preset zones: zone0 (Bass), zone1 (Piano vel 0-79),
        // zone2 (Piano vel 80-127), zone3 (DarkFilter) -------------------------------------------
        var pgen = ByteWriter()
        func gen(_ writer: inout ByteWriter, _ type: UInt16, _ value: UInt16) {
            writer.u16(type)
            writer.u16(value)
        }
        gen(&pgen, 48, 0) // zone0 (Bass): initialAttenuation = 0                    [index 0]
        gen(&pgen, 41, 0) // zone0 (Bass): instrument = 0                           [index 1]
        gen(&pgen, 44, range(0, 79)) // zone1 (Piano A): velocityRange 0-79         [index 2]
        gen(&pgen, 48, 60) // zone1 (Piano A): initialAttenuation = 60 cB           [index 3]
        gen(&pgen, 41, 1) // zone1 (Piano A): instrument = 1                        [index 4]
        gen(&pgen, 44, range(80, 127)) // zone2 (Piano B): velocityRange 80-127     [index 5]
        gen(&pgen, 41, 1) // zone2 (Piano B): instrument = 1                        [index 6]
        gen(&pgen, 41, 2) // zone3 (DarkFilter): instrument = 2                     [index 7]
        gen(&pgen, 0, 0) // terminal generator record (dropped by Generator.readFromChunk)

        var pmod = ByteWriter()
        // zone1's (Piano A) sole modulator — no terminal padding record needed: `Modulator.readAll`
        // (unlike `Generator.readFromChunk`) does not drop a trailing record, and each zone's slice
        // is bounds-derived from the pbag/ibag index math below, not from a wire convention.
        pmod.bytes(velocityToAttenuationModulatorBytes(amount: 700)) // [index 0]
        // zone2's (Piano B) sole modulator.
        pmod.bytes(velocityToAttenuationModulatorBytes(amount: 700)) // [index 1]

        var pbag = ByteWriter()
        func bag(_ writer: inout ByteWriter, _ generatorIndex: UInt16, _ modulatorIndex: UInt16) {
            writer.u16(generatorIndex)
            writer.u16(modulatorIndex)
        }
        bag(&pbag, 0, 0) // zone0 (Bass): generators [0,2), modulators [0,0)
        bag(&pbag, 2, 0) // zone1 (Piano A): generators [2,5), modulators [0,1)
        bag(&pbag, 5, 1) // zone2 (Piano B): generators [5,7), modulators [1,2)
        bag(&pbag, 7, 2) // zone3 (DarkFilter): generators [7,8), modulators [2,2)
        bag(&pbag, 8, 2) // terminator: total generator/modulator counts

        // pdta: inst/ibag/imod/igen — instruments: Bass (one local zone), Piano (one GLOBAL zone
        // carrying the canceling modulator + one local zone with the sample), DarkFilter (one local
        // zone with the dark base filter + its dest-11 modulator) ---------------------------------
        var inst = ByteWriter()
        func instRecord(_ name: String, zoneStart: UInt16) {
            inst.fixedString(name, length: 20)
            inst.u16(zoneStart)
        }
        instRecord("Bass", zoneStart: 0)
        instRecord("Piano", zoneStart: 1)
        instRecord("DarkFilter", zoneStart: 3)
        instRecord("EOI", zoneStart: 4) // terminator: total instrument-zone count

        // Each instrument zone's generators end with sampleID (53) LAST — required for zoneB0 (it
        // is zones[0] of Bass's own slice, so `Instrument.buildRegions`'s global-zone detection
        // reads exactly its LAST generator's type; anything but sampleID there would misclassify
        // Bass's only zone as global and leave it with zero regions). `sampleModes` (54) = 1
        // (continuous loop) comes first so the voice loops the 128-sample body indefinitely
        // instead of dying after one ~2.9 ms pass (`Oscillator.fillBlockNoLoop`'s default).
        var igen = ByteWriter()
        gen(&igen, 54, 1) // zoneB0 (Bass local zone): sampleModes = continuous     [index 0]
        gen(&igen, 53, 0) // zoneB0 (Bass local zone): sampleID = 0                 [index 1]
        gen(&igen, 54, 1) // zoneP-local (Piano local zone): sampleModes = continuous [index 2]
        gen(&igen, 53, 0) // zoneP-local (Piano local zone): sampleID = 0           [index 3]
        gen(&igen, 8, 1500) // zoneD0 (DarkFilter local zone): initialFilterCutoffFrequency = 1500
        //                     (SF2 §8.1.3 floor, ~19 Hz — the deliberately dark base filter) [index 4]
        gen(&igen, 54, 1) // zoneD0 (DarkFilter local zone): sampleModes = continuous [index 5]
        gen(&igen, 53, 0) // zoneD0 (DarkFilter local zone): sampleID = 0           [index 6]
        gen(&igen, 0, 0) // terminal generator record

        var imod = ByteWriter()
        // zoneP-global's sole modulator: velocity -> initialAttenuation, amount 0 — the SAME
        // 4-field shape as SF2 default #1, so `ModulatorResolver.resolveInstrument` SUPERSEDES the
        // default with this (canceling the instrument's own velocity-driven attenuation entirely —
        // the real MuseScore_General piano's technique, design spec's Problem section).
        imod.bytes(velocityToAttenuationModulatorBytes(amount: 0)) // [index 0]
        // zoneD0's (DarkFilter) two modulators. The canceling velocity->initialAttenuation (amount 0,
        // same shape as above) is REQUIRED, not incidental: without it, SF2 default #1 is still in
        // scope (it was applied even before this feature's full destination set) and its own
        // velocity-driven attenuation would make the note louder at higher velocity regardless of
        // whether destination 11 is wired at all — a false-positive pass that pins nothing. Canceling
        // it isolates the ONLY velocity-dependent effect left to the dest-11 modEnvToFilterFc path
        // this test exists to guard.
        imod.bytes(velocityToAttenuationModulatorBytes(amount: 0)) // [index 1]
        // velocity -> modEnvToFilterFc, amount 5000 — see `crossfadeFont`'s doc comment
        // (destination-11 regression guard).
        imod.bytes(velocityToModEnvFilterCutoffModulatorBytes(amount: 5000)) // [index 2]

        var ibag = ByteWriter()
        bag(&ibag, 0, 0) // zoneB0 (Bass): generators [0,2), modulators [0,0)
        bag(&ibag, 2, 0) // zoneP-global (Piano): generators [2,2), modulators [0,1)
        bag(&ibag, 2, 1) // zoneP-local (Piano): generators [2,4), modulators [1,1)
        bag(&ibag, 4, 1) // zoneD0 (DarkFilter local): generators [4,7), modulators [1,3)
        bag(&ibag, 7, 3) // terminator: total generator/modulator counts

        // shdr — one shared PCM sample, continuously looped over its whole 128-sample body --------
        var shdr = ByteWriter()
        shdr.fixedString("Sine", length: 20)
        shdr.u32(0) // start
        shdr.u32(128) // end
        shdr.u32(0) // startLoop
        shdr.u32(128) // endLoop
        shdr.u32(44_100) // sampleRate
        shdr.u8(60) // originalPitch
        shdr.i8(0) // pitchCorrection
        shdr.u16(0) // sampleLink
        shdr.u16(1) // sampleType (mono)
        shdr.fixedString("EOS", length: 20) // terminator (46 bytes total)
        shdr.bytes([UInt8](repeating: 0, count: 26))

        var pdta = ByteWriter()
        pdta.fourCC("pdta")
        pdta.chunk("phdr", phdr)
        pdta.chunk("pbag", pbag)
        pdta.chunk("pmod", pmod)
        pdta.chunk("pgen", pgen)
        pdta.chunk("inst", inst)
        pdta.chunk("ibag", ibag)
        pdta.chunk("imod", imod)
        pdta.chunk("igen", igen)
        pdta.chunk("shdr", shdr)

        // RIFF -----------------------------------------------------------------------------------
        var riffBody = ByteWriter()
        riffBody.fourCC("sfbk")
        riffBody.list(info)
        riffBody.list(sdta)
        riffBody.list(pdta)
        var out = ByteWriter()
        out.fourCC("RIFF")
        out.u32(UInt32(riffBody.data.count))
        out.append(riffBody)
        return out.data
    }
}
