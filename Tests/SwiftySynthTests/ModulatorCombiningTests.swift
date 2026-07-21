import Testing
@testable import SwiftySynth

private func gen(_ type: GeneratorType, _ value: Int16) -> Generator {
    Generator(type: type, value: UInt16(bitPattern: value))
}

private func makeHeader() -> SampleHeader {
    SampleHeader(
        name: "S", start: 0, end: 1000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: 0, link: 0, sampleType: 1)
}

/// `ModulatorResolver` — the SF2 §9.5.1 combining chain that resolves default + instrument + preset
/// modulators into a per-region effective note-on modulator set (design spec §5). Two identities are
/// in play and must not be conflated: 4-field (source, destination, amount-source, transform) for
/// cross-level supersession (default → global-instrument → local-instrument, and global-preset →
/// local-preset); 3-field (transform excluded) for within-one-zone duplicate detection.
struct ModulatorCombiningTests {
    /// A velocity->initialAttenuation modulator (concave, maxToMin, unmodulated amount-source),
    /// matching SF2 default #1's 4-field shape so it can supersede it.
    private func velAtten(_ amount: Int16) -> Modulator {
        makeVelocityToAttenuationModulator(amount: amount)
    }

    // MARK: - resolveInstrument

    /// A global-instrument-zone modulator identical (4-field) to default #1, with amount 0, must
    /// supersede (replace, not add to) the default — this is exactly the shape MuseScore_General's
    /// piano instrument uses to cancel default velocity attenuation (design spec, Problem section).
    @Test func globalInstrumentModulatorSupersedesDefaultToZero() {
        let resolved = ModulatorResolver.resolveInstrument(global: [velAtten(0)], local: [])
        let velMods = resolved.filter { $0.destination == .initialAttenuation && $0.source.controller == .velocity }
        #expect(velMods.count == 1, "must replace default #1, not add alongside it")
        #expect(velMods.first?.amount == 0)
    }

    /// A local-instrument-zone modulator identical (4-field) to a global-instrument-zone entry must
    /// supersede that global entry (design spec §5 point 3) — the global cancel-to-0 is itself
    /// overridden by a local zone that restores a nonzero amount.
    @Test func localInstrumentModulatorSupersedesGlobalEntry() {
        let resolved = ModulatorResolver.resolveInstrument(global: [velAtten(0)], local: [velAtten(300)])
        let velMods = resolved.filter { $0.destination == .initialAttenuation && $0.source.controller == .velocity }
        #expect(velMods.count == 1, "local supersedes the global-resolved entry, not adds")
        #expect(velMods.first?.amount == 300)
    }

    /// A CC-sourced modulator fails the note-on filter (`isNoteOn` requires both source and
    /// amount-source note-on) and must not appear in the resolved set at all.
    @Test func ccSourcedModulatorIsSkipped() {
        let cc = makeModulator(src: 0x0081, dest: 48, amount: 500) // CC(1) source, initialAttenuation
        let resolved = ModulatorResolver.resolveInstrument(global: [], local: [cc])
        #expect(!resolved.contains { $0.amount == 500 })
        // Only the untouched default remains.
        #expect(resolved.count == 1)
    }

    /// Within one zone, two 3-field-identical records (same source/destination/amount-source): the
    /// first is ignored, the later (last) record wins (SF2 §7.4/§7.8).
    @Test func withinZoneDuplicateLaterWins() {
        let resolved = ModulatorResolver.resolveInstrument(global: [], local: [velAtten(600), velAtten(900)])
        let amounts = resolved.filter { $0.destination == .initialAttenuation }.map(\.amount)
        #expect(amounts == [900], "later record in the same zone wins")
    }

    /// Same duplicate rule, but in the GLOBAL zone rather than local — the dedup must apply to each
    /// zone independently before cross-level supersession runs.
    @Test func withinGlobalZoneDuplicateLaterWins() {
        let resolved = ModulatorResolver.resolveInstrument(global: [velAtten(200), velAtten(700)], local: [])
        let amounts = resolved.filter { $0.destination == .initialAttenuation }.map(\.amount)
        #expect(amounts == [700])
    }

    /// A non-superseding instrument modulator (distinct 4-field identity from every default) simply
    /// adds to the resolved set alongside the untouched default.
    @Test func distinctInstrumentModulatorAddsAlongsideDefault() {
        // keyNumber -> pan (dest 17), not identical to default #1 (velocity -> initialAttenuation).
        let keyToPan = makeModulator(src: 0x0003, dest: 17, amount: 50)
        let resolved = ModulatorResolver.resolveInstrument(global: [], local: [keyToPan])
        #expect(resolved.count == 2)
        #expect(resolved.contains { $0.destination == .initialAttenuation && $0.source.controller == .velocity
            && $0.amount == 960 })
        #expect(resolved.contains { $0.destination == .pan && $0.amount == 50 })
    }

    // MARK: - addPreset

    /// Preset modulators are ADDITIVE on top of the instrument-level result — they never supersede
    /// an instrument/default entry, even when 4-field-identical (design spec §5 point 4). Net
    /// velocity->attenuation contribution across both entries sums to 700 (0 from the
    /// instrument-cancelled default + 700 from the preset).
    @Test func presetAddsOnTopOfCancelledInstrumentLevel() {
        let instrumentLevel = ModulatorResolver.resolveInstrument(global: [velAtten(0)], local: [])
        let effective = ModulatorResolver.addPreset(
            instrumentLevel: instrumentLevel, presetGlobal: [velAtten(700)], presetLocal: [])
        let velMods = effective.filter { $0.destination == .initialAttenuation && $0.source.controller == .velocity }
        #expect(velMods.count == 2, "preset adds a second entry rather than replacing the instrument one")
        #expect(velMods.reduce(0) { $0 + $1.amount } == 700)
    }

    /// Within the preset side, a local-preset-zone modulator 4-field-identical to a global-preset-zone
    /// one supersedes it (mirrors the instrument-side global/local rule) before the combined preset
    /// set is appended to the instrument level.
    @Test func localPresetModulatorSupersedesGlobalPresetModulator() {
        let effective = ModulatorResolver.addPreset(
            instrumentLevel: [], presetGlobal: [velAtten(600)], presetLocal: [velAtten(800)])
        let velMods = effective.filter { $0.destination == .initialAttenuation && $0.source.controller == .velocity }
        #expect(velMods.count == 1, "local preset supersedes global preset, not adds")
        #expect(velMods.first?.amount == 800)
    }

    // MARK: - buildRegions wiring (Instrument/Preset)

    /// An all-modulator global instrument zone (zero generators, modulators only — SF2 §7.7, the
    /// shape a font uses for a preset/instrument-wide cancel) must still be detected as global (by
    /// the existing `generators.isEmpty` rule) and its modulators applied to every local zone,
    /// exercised through the real `Instrument.buildRegions` path (not `ModulatorResolver` directly).
    @Test func allModulatorGlobalZoneAppliesThroughBuildRegions() throws {
        let globalZone = Zone(generators: [], modulators: [velAtten(0)])
        let localZone = Zone(generators: [gen(.sampleID, 0)])
        let instrument = try Instrument(name: "I", zones: [globalZone, localZone], samples: [makeHeader()])
        #expect(instrument.regions.count == 1)
        let velMods = instrument.regions[0].modulators.filter {
            $0.destination == .initialAttenuation && $0.source.controller == .velocity
        }
        #expect(velMods.count == 1)
        #expect(velMods.first?.amount == 0, "global all-modulator zone's cancel must reach the built region")
    }

    /// `Preset.buildRegions` threads each zone's modulators into `PresetRegion.modulators` the same
    /// way: global preset zone modulators apply to (and can be superseded by) each local zone's own.
    @Test func presetBuildRegionsThreadsModulatorsThroughZones() throws {
        let header = makeHeader()
        let instrument = try Instrument(name: "I", zones: [Zone(generators: [gen(.sampleID, 0)])], samples: [header])
        let globalZone = Zone(generators: [], modulators: [velAtten(600)])
        let localZone = Zone(generators: [gen(.instrument, 0)], modulators: [velAtten(800)])
        let preset = try Preset(
            name: "P", patchNumber: 0, bankNumber: 0, zones: [globalZone, localZone], instruments: [instrument])
        #expect(preset.regions.count == 1)
        let velMods = preset.regions[0].modulators.filter {
            $0.destination == .initialAttenuation && $0.source.controller == .velocity
        }
        #expect(velMods.count == 1, "local preset zone supersedes the global preset zone's entry")
        #expect(velMods.first?.amount == 800)
    }
}
