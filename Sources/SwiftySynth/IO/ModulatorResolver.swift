/// Cross-level and within-zone identity comparisons used by `ModulatorResolver` (SF2 §9.5.1, design
/// spec §5). The two identities are deliberately distinct and must not be conflated: `isIdentical4`
/// (source, destination, amount-source, AND transform) is used for *cross-level* supersession —
/// e.g. a global-instrument-zone modulator superseding a default, or a local zone superseding a
/// global one; `isIdentical3` (source, destination, amount-source — transform excluded) is used for
/// *within-one-zone* duplicate detection (a zone's own `pmod`/`imod` records naming the same
/// source/destination/amount-source twice, regardless of transform, SF2 §7.4/§7.8).
extension Modulator {
    /// True when `source`, `destination`, and `amountSource` all match. The "3-field" within-zone
    /// duplicate identity (design spec §5 point 5).
    func isIdentical3(to other: Modulator) -> Bool {
        source == other.source && destination == other.destination && amountSource == other.amountSource
    }

    /// True when `source`, `destination`, `amountSource`, and `transform` all match. The "4-field"
    /// cross-level supersession identity (design spec §5, SF2 §9.5.1 p.54).
    func isIdentical4(to other: Modulator) -> Bool {
        isIdentical3(to: other) && transform == other.transform
    }
}

/// Combines/resolves SF2 modulator records into the effective per-region note-on modulator set, per
/// the SF2 §9.5.1 four-layer chain (default → global instrument zone → local instrument zone →
/// global preset zone → local preset zone) restricted to note-on sources (design spec §5).
///
/// No direct C# counterpart — MeltySynth discards every modulator record (`Modulator.discardData`);
/// this is new plumbing for the optional note-on-modulator feature. Resolution happens once at
/// SoundFont load (`Instrument.buildRegions`/`Preset.buildRegions`), not per-note, so the render path
/// stays allocation-free (design spec §5, final paragraph).
enum ModulatorResolver {
    /// Note-on-filters and within-zone-dedups one zone's raw modulator list (design spec §5 points 5
    /// and 6): keeps only records that are both `isValid` (record-level semantic validity) and
    /// `isNoteOn` (source AND amount-source both note-on-only controllers); among any remaining
    /// 3-field-identical duplicates, the first occurrence is dropped and the last wins (SF2
    /// §7.4/§7.8, PDF pp.23/27). Order-preserving otherwise.
    static func dedupWithinZone(_ modulators: [Modulator]) -> [Modulator] {
        let noteOnValid = modulators.filter { $0.isNoteOn && $0.isValid }

        var result: [Modulator] = []
        result.reserveCapacity(noteOnValid.count)
        for modulator in noteOnValid {
            if let index = result.firstIndex(where: { $0.isIdentical3(to: modulator) }) {
                result[index] = modulator
            } else {
                result.append(modulator)
            }
        }
        return result
    }

    /// Resolves the effective note-on modulator set for one instrument region (design spec §5 points
    /// 1-3): starts from `DefaultModulators.noteOn`, applies the (deduped) global-instrument-zone
    /// modulators — each either superseding an already-present 4-field-identical entry or appending —
    /// then likewise applies the (deduped) local-instrument-zone modulators, which may supersede a
    /// default OR a global-zone entry. `global`/`local` are one zone's raw `Zone.modulators` slice
    /// each (not yet deduped); pass `[]` for `global` when the instrument has no global zone.
    static func resolveInstrument(global: [Modulator], local: [Modulator]) -> [Modulator] {
        var resolved = DefaultModulators.noteOn
        supersedeOrAppend(&resolved, with: dedupWithinZone(global))
        supersedeOrAppend(&resolved, with: dedupWithinZone(local))
        return resolved
    }

    /// Resolves the note-on modulator set contributed by one preset's zone pair (global preset zone +
    /// one local preset zone), independent of any instrument-level result: dedups each zone
    /// separately, then a local-preset modulator 4-field-identical to a global-preset one supersedes
    /// it, else adds (design spec §5 point 4, first half — mirrors the instrument-side global/local
    /// rule one level up). This is the list `Preset.buildRegions` stores on `PresetRegion.modulators`;
    /// the additive combination with the instrument side happens as a plain concatenation in
    /// `RegionPair.resolvedModulators` (Task 8) — NOT via `addPreset` below, which would re-dedup this
    /// already-resolved list by the (transform-blind) 3-field identity and could drop a legitimate
    /// entry.
    static func resolvePreset(global: [Modulator], local: [Modulator]) -> [Modulator] {
        var resolved = dedupWithinZone(global)
        supersedeOrAppend(&resolved, with: dedupWithinZone(local))
        return resolved
    }

    /// Combines an already-resolved instrument-level modulator set (`resolveInstrument`) with the
    /// preset-level modulators, additively: the preset's (deduped, global/local-supersession-
    /// resolved, via `resolvePreset`) set is appended to `instrumentLevel` wholesale — preset
    /// modulators never supersede an instrument or default entry, even when 4-field-identical to one
    /// (design spec §5 point 4, second half; SF2 §9.5.1). The returned list may therefore contain two
    /// entries with the same destination (e.g. an instrument-level vel->attenuation amount 0 and a
    /// preset-level vel->attenuation amount 700) — summing contributions per destination at apply
    /// time is a later task's concern (`Voice.start`).
    static func addPreset(instrumentLevel: [Modulator], presetGlobal: [Modulator], presetLocal: [Modulator])
        -> [Modulator]
    {
        instrumentLevel + resolvePreset(global: presetGlobal, local: presetLocal)
    }

    /// Applies `incoming` (assumed already within-zone-deduped, so pairwise non-4-field-identical) to
    /// `accumulator` one entry at a time: each entry either replaces the first 4-field-identical entry
    /// already present in `accumulator` (supersession — the whole modulator record is replaced) or is
    /// appended (design spec §5's identity-based supersession, both instrument- and preset-level).
    private static func supersedeOrAppend(_ accumulator: inout [Modulator], with incoming: [Modulator]) {
        for modulator in incoming {
            if let index = accumulator.firstIndex(where: { $0.isIdentical4(to: modulator) }) {
                accumulator[index] = modulator
            } else {
                accumulator.append(modulator)
            }
        }
    }
}
