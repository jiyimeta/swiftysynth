import Foundation
import Testing
@testable import SwiftySynth

/// Load-compatibility & record-validity regression suite (design spec
/// `docs/superpowers/specs/2026-07-22-sf2-note-on-modulators-design.md` §2, §Testing item 6 — task
/// 11 of the SF2 note-on-modulators plan).
///
/// Proves the loader's deliberate deviations from the SF2 spec's letter — all in service of the
/// feature's hard requirement, "no font that loads today may fail to load": a missing or
/// terminal-only `pmod`/`imod` sub-chunk loads with an empty modulator list, no throw; semantically
/// invalid records (illegal CC-flagged index, linked source/destination, a destination that isn't a
/// Value Generator) are skipped per-record, never rejecting the whole file; a convex(2)- or
/// switch(3)-typed source record is ACCEPTED and survives resolution (guards the §2 "skip on curve
/// type value > 3 — bits 12...15, not the stale SF2.00-era 11...15 erratum" fix, since bit 11 alone
/// is set by both curve types 2 and 3); a corrupt `wModNdx` bag range yields an empty modulator list
/// for that one zone, never a throw; a chunk whose byte length isn't a whole multiple of 10 throws.
///
/// Built on `SyntheticSF2.minimal` (`SyntheticSoundFontTests.swift`) rather than a new builder: its
/// single-preset/single-instrument/single-zone shape is already exactly what a "structurally valid
/// except for the one property under test" fixture needs, and it already supports an arbitrary
/// instrument-generator list. This suite extends it with four purely-additive, default-preserving
/// toggles (`includeInstrumentModulatorChunk`, `instrumentModulatorRecords`,
/// `instrumentModulatorBagCount`, `instrumentModulatorChunkGarbageBytes`) — each mutates ONE aspect
/// of the `imod` chunk or the instrument zone's bag entry; every other existing caller of
/// `SyntheticSF2.minimal` is unaffected since all four default to today's exact byte shape.
/// (`Support/SyntheticFont.swift`'s sibling builder is a structurally different two-preset,
/// velocity-split-zone font built for the Task 10 behavioral guard — not a fit for these
/// single-property regression toggles.)
///
/// Survival/skip is asserted by reading `InstrumentRegion.modulators` — the already-resolved
/// note-on modulator list `ModulatorResolver.resolveInstrument` computes once at load time (the same
/// observable point `ZoneModulatorSliceTests`/`RegionPairModulatorTests` use). That resolution is
/// unconditional; only *application* in `Voice.start` is gated by `enableModulators`, so these
/// assertions hold regardless of that setting.
struct ModulatorLoadCompatTests {
    /// One 10-byte imod/pmod record: srcOper, destOper (generator), amount, amtSrcOper, transform.
    /// Same layout as `ModulatorDecodeTests.record`/`ModulatorChunkParseTests.record`, returning
    /// `[UInt8]` for `SyntheticSF2.minimal`'s `instrumentModulatorRecords:` parameter.
    private func modRecord(src: UInt16, dest: UInt16, amount: Int16, amtSrc: UInt16 = 0, transform: UInt16 = 0)
        -> [UInt8]
    {
        var w = ByteWriter()
        w.u16(src)
        w.u16(dest)
        w.i16(amount)
        w.u16(amtSrc)
        w.u16(transform)
        return [UInt8](w.data)
    }

    // MARK: - 1. No modulator records (terminal-only, or the sub-chunk absent) -> loads

    /// `SyntheticSF2.minimal()`'s unmodified default shape: an `imod` sub-chunk present, carrying a
    /// single all-zero terminal record that the instrument's one zone does not reference.
    @Test func fontWithTerminalOnlyModulatorChunkLoads() throws {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        #expect(
            font.instruments[0].regions[0].modulators.count == 1,
            "only the synthesized default #1 -- the unreferenced terminal record contributes nothing"
        )
    }

    /// The `imod` sub-chunk omitted from `pdta` entirely (design spec §2: unlike every other pdta
    /// sub-chunk, `pmod`/`imod` must NOT gain a mandatory-presence guard, or a font that omits them
    /// -- and loads today -- would start failing).
    @Test func fontWithAbsentModulatorSubChunkLoads() throws {
        let data = SyntheticSF2.minimal(includeInstrumentModulatorChunk: false)
        let font = try SoundFont(data: data)
        #expect(font.instruments[0].regions[0].modulators.count == 1, "same as the terminal-only case")
    }

    // MARK: - 2. convex(2) / switch(3) source records -> ACCEPTED and survive

    /// Guards the §2 fix directly: a literal reading of the stale SF2.00-era erratum ("if any of
    /// bits 11 through 15 are set, ignore") would wrongly drop both curve types, since bit 11 alone
    /// is set by BOTH curveTypeRaw 2 (convex) and 3 (switch) -- only checking bits 12...15
    /// (equivalently, curveTypeRaw > 3) keeps them. No other test in the suite would catch a
    /// regression back to the 11...15 reading, because that reading over-rejects rather than
    /// under-rejects -- the font would still load (records silently skipped), just silently wrong.
    @Test func convexAndSwitchSourceRecordsAcceptedAndSurvive() throws {
        // convex: curveTypeRaw 2 -> word bits 10-15 = 0b000010 -> (2 << 10) = 0x0800; | index 2
        // (velocity, CC clear, direction minToMax, polarity unipolar) = 0x0802.
        let convex = modRecord(src: 0x0802, dest: 48, amount: 111)
        // switch: curveTypeRaw 3 -> (3 << 10) = 0x0C00; | index 2 = 0x0C02.
        let sw = modRecord(src: 0x0C02, dest: 48, amount: 222)
        let data = SyntheticSF2.minimal(instrumentModulatorRecords: [convex, sw])

        let font = try SoundFont(data: data)
        let modulators = font.instruments[0].regions[0].modulators

        #expect(modulators.contains { $0.source.curve == .convex && $0.amount == 111 })
        #expect(modulators.contains { $0.source.curve == .switch && $0.amount == 222 })
        // Default #1 (concave) plus both font-declared records: neither convex nor switch is
        // 4-field-identical to the concave default, so both ADD rather than supersede it.
        #expect(modulators.count == 3)
    }

    // MARK: - 3. Semantically invalid records -> skipped per-record, font still loads

    @Test func invalidRecordsSkippedNotRejected() throws {
        // (a) illegal CC-flagged source index: CC flag (bit 7, 0x80) | index 0 (Bank Select MSB).
        let illegalCCIndex0 = modRecord(src: 0x0080, dest: 48, amount: 901)
        // illegal CC index 120 (All Sound Off): 0x80 | 0x78 = 0xF8.
        let illegalCCIndex120 = modRecord(src: 0x00F8, dest: 48, amount: 902)
        // (b) linked destination: destOper bit 15 set.
        let linkedDestination = modRecord(src: 0x0002, dest: 0x8000 | 48, amount: 903)
        // (c) Link source: CC clear, index 127 (the "Link" general controller, §8.2.1/§9.5.4).
        let linkedSource = modRecord(src: 0x007F, dest: 48, amount: 904)
        // Link as the amount-source instead of the source.
        let linkedAmountSource = modRecord(src: 0x0002, dest: 48, amount: 905, amtSrc: 0x007F)
        // (d) destination not a Value Generator: sampleID (53) is an index generator (§8.1.1).
        let nonValueGeneratorDestination = modRecord(src: 0x0002, dest: 53, amount: 906)
        // A well-formed marker record (distinct amount) proving the skip is per-record, not
        // all-or-nothing -- it must survive alongside the six invalid records being dropped.
        let marker = modRecord(src: 0x0002, dest: 48, amount: 999)

        let data = SyntheticSF2.minimal(instrumentModulatorRecords: [
            illegalCCIndex0, illegalCCIndex120, linkedDestination, linkedSource, linkedAmountSource,
            nonValueGeneratorDestination, marker,
        ])

        let font = try SoundFont(data: data)
        let modulators = font.instruments[0].regions[0].modulators
        let survivingAmounts = Set(modulators.map(\.amount))

        #expect(survivingAmounts.contains(999), "the well-formed marker record must survive")
        for invalidAmount in [901, 902, 903, 904, 905, 906] {
            #expect(
                !survivingAmounts.contains(invalidAmount),
                "invalid record (amount \(invalidAmount)) must be skipped, not merely rejected-as-a-file"
            )
        }
        // Default #1 + the marker only -- the six invalid records contribute nothing, and the font
        // loaded end-to-end despite carrying them.
        #expect(modulators.count == 2)
    }

    // MARK: - 4. Corrupt wModNdx bag range -> that zone's modulators empty, never throw

    /// Mirrors `ZoneModulatorSliceTests.testCorruptModRangeYieldsEmptyNotThrow`'s guard, but
    /// exercised at the whole-font `SoundFont(data:)` load path rather than directly against
    /// `Zone.create` -- proving the deviation is actually reachable end-to-end, not just unit-level.
    @Test func corruptWModNdxLoadsWithEmptyZoneModulators() throws {
        let marker = modRecord(src: 0x0002, dest: 48, amount: 555)
        // Only 1 modulator record present, but the zone's declared bag count claims 5 --
        // non-monotonic/out-of-range `wModNdx` (design spec §2's deliberate bag-range deviation).
        let data = SyntheticSF2.minimal(instrumentModulatorRecords: [marker], instrumentModulatorBagCount: 5)

        let font = try SoundFont(data: data)
        let modulators = font.instruments[0].regions[0].modulators

        #expect(
            !modulators.contains { $0.amount == 555 },
            "corrupt wModNdx must yield an empty zone modulator slice, not the marker"
        )
        #expect(modulators.count == 1, "only the synthesized default #1 survives -- the corrupt zone slice is empty")
    }

    // MARK: - 5. Chunk-size malformed -> throws

    /// Unlike every other toggle in this suite, a chunk byte length that is not a whole multiple of
    /// 10 is NOT one of the spec's load-compatibility deviations -- `Modulator.readAll` throws
    /// (unchanged from today), and this is the one property this suite asserts DOES fail to load.
    @Test func chunkSizeMalformedThrows() {
        let marker = modRecord(src: 0x0002, dest: 48, amount: 700)
        // 1 record (10 bytes) + 3 garbage bytes = 13 total -- not a whole multiple of 10.
        let data = SyntheticSF2.minimal(
            instrumentModulatorRecords: [marker], instrumentModulatorChunkGarbageBytes: 3
        )

        #expect(throws: SwiftySynthError.self) {
            _ = try SoundFont(data: data)
        }
    }
}
