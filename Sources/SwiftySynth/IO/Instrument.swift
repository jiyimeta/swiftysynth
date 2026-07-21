/// Raw `inst` sub-chunk record: name plus the ibag start index, with the
/// end index derived from the next record's start index.
///
/// Ported from `InstrumentInfo.cs` (MeltySynth, MIT License — see NOTICE).
/// C# models this as a mutable class (`zoneEndIndex` is back-filled by a
/// second pass over consecutive records); the Swift port is an immutable
/// `struct` — the two-pass computation happens inside `create` before each
/// `InstrumentInfo` is constructed, mirroring the `ZoneInfo` port (Task 8).
struct InstrumentInfo {
    let name: String
    let zoneStartIndex: Int
    let zoneEndIndex: Int

    /// Reads an `inst` sub-chunk. Each record is 22 bytes (20-byte
    /// fixed-length name + u16 zoneStartIndex). The last record is the `EOI`
    /// terminator; it is still returned here (matching `InstrumentInfo.cs`,
    /// which never drops it) — the caller (`Instrument.create`) is
    /// responsible for excluding it from the produced instruments.
    static func create(reader: BinaryReader, size: Int) throws -> [InstrumentInfo] {
        // C#'s `size / 22` on a negative size (still a multiple of 22) would
        // yield a negative count and throw (catchably) on `new
        // InstrumentInfo[count]`; Swift's `0..<count` would instead build an
        // inverted range and trap. Reject a negative size up front to
        // preserve the "never trap the host app" invariant.
        guard size >= 0, size % 22 == 0 else {
            throw SwiftySynthError.invalidSoundFont("The instrument list is invalid.")
        }

        let count = size / 22

        var names: [String] = []
        var zoneStartIndices: [Int] = []
        // Reserve clamped to what the remaining bytes could hold: the claimed
        // chunk size is untrusted, and the read loop below is already EOF-safe,
        // so the clamp can only shrink a doomed reserve — it never changes what
        // parses.
        let reserveCount = min(count, reader.bytesRemaining / 22)
        names.reserveCapacity(reserveCount)
        zoneStartIndices.reserveCapacity(reserveCount)
        for _ in 0..<count {
            names.append(try reader.readFixedLengthString(20))
            zoneStartIndices.append(Int(try reader.readUInt16()))
        }

        var infos: [InstrumentInfo] = []
        infos.reserveCapacity(count)
        for i in 0..<count {
            // The terminal record has no "next" record to derive an end
            // index from; it is left at 0, matching C#'s unset (default)
            // `zoneEndIndex` field. It is never read, since
            // `Instrument.create` drops the terminal record.
            let zoneEndIndex = i < count - 1 ? zoneStartIndices[i + 1] - 1 : 0
            infos.append(
                InstrumentInfo(
                    name: names[i],
                    zoneStartIndex: zoneStartIndices[i],
                    zoneEndIndex: zoneEndIndex
                )
            )
        }

        return infos
    }
}

/// Represents an instrument in the SoundFont.
///
/// Ported from `Instrument.cs` (MeltySynth, MIT License — see NOTICE). C#
/// also keeps a private parameterless constructor backing a static
/// `Instrument.Default` singleton (name `"Default"`, no regions); that
/// singleton is not part of this task's interface and has no caller yet, so
/// it is omitted here (mirrors Task 9 omitting `SampleHeader.Default` for
/// the same reason).
public final class Instrument {
    public let name: String
    public let regions: [InstrumentRegion]

    /// Reader-driven initializer: resolves `info`'s zone range against the
    /// full `zones` array (shared across all instruments), then builds
    /// regions from that slice. Mirrors the private
    /// `Instrument(InstrumentInfo, Zone[], SampleHeader[])` constructor.
    init(info: InstrumentInfo, zones: [Zone], samples: [SampleHeader]) throws {
        self.name = info.name

        let zoneCount = info.zoneEndIndex - info.zoneStartIndex + 1
        guard zoneCount > 0 else {
            throw SwiftySynthError.invalidSoundFont("The instrument '\(info.name)' has no zone.")
        }

        // `zones.AsSpan(zoneStartIndex, zoneCount)` throws (catchably) in C#
        // when the range is out of bounds; validate here so the Swift slice
        // subscript below never traps on corrupt bag-index data.
        guard info.zoneStartIndex >= 0, info.zoneStartIndex + zoneCount <= zones.count else {
            throw SwiftySynthError.invalidSoundFont("The instrument '\(info.name)' has an invalid zone range.")
        }

        let zoneSlice = Array(zones[info.zoneStartIndex..<(info.zoneStartIndex + zoneCount)])
        self.regions = try Instrument.buildRegions(zones: zoneSlice, samples: samples)
    }

    /// Direct-construction initializer for tests (no C# analogue; C# only
    /// has the reader-based private constructor plus the `Default`
    /// singleton). Takes the instrument's zones directly instead of
    /// resolving them from a shared array via an `InstrumentInfo`.
    init(name: String, zones: [Zone], samples: [SampleHeader]) throws {
        self.name = name
        self.regions = try Instrument.buildRegions(zones: zones, samples: samples)
    }

    /// Builds all instruments from the `inst` records. Mirrors
    /// `Instrument.Create`, including dropping the last (terminator) record.
    static func create(infos: [InstrumentInfo], zones: [Zone], samples: [SampleHeader]) throws -> [Instrument] {
        guard infos.count > 1 else {
            throw SwiftySynthError.invalidSoundFont("No valid instrument was found.")
        }

        // The last one is the terminator.
        var instruments: [Instrument] = []
        instruments.reserveCapacity(infos.count - 1)
        for i in 0..<(infos.count - 1) {
            instruments.append(try Instrument(info: infos[i], zones: zones, samples: samples))
        }

        return instruments
    }

    /// Decides which zone (if any) is the global zone and builds one
    /// `InstrumentRegion` per local zone accordingly. Mirrors
    /// `InstrumentRegion.Create`'s global-zone detection, which in the C#
    /// source lives on `InstrumentRegion` itself; it is relocated onto
    /// `Instrument` here because this task's `InstrumentRegion` interface
    /// exposes only the per-region `init(global:local:samples:)`, not a
    /// zone-array-consuming factory.
    private static func buildRegions(zones: [Zone], samples: [SampleHeader]) throws -> [InstrumentRegion] {
        // C#'s `zones[0]` on an empty span throws (catchably) an
        // IndexOutOfRangeException; guard explicitly so this never traps.
        guard !zones.isEmpty else {
            throw SwiftySynthError.invalidSoundFont("The instrument has no zone.")
        }

        // `last?.type` is already `GeneratorType?`; an unknown (`nil`) type
        // makes `!= .sampleID` `true`, marking the zone global — matching
        // C#'s unchecked-raw-value comparison against `SampleID`, which is
        // likewise `true` for any raw value that isn't the sampleID case.
        let firstIsGlobal = zones[0].generators.isEmpty || zones[0].generators.last?.type != .sampleID

        if firstIsGlobal {
            // The global zone is regarded as the base setting of subsequent
            // zones. Note the single-zone edge case: if there is exactly one
            // zone and it is the global one, there are zero local zones and
            // the region list is empty — matching C#'s
            // `new InstrumentRegion[zoneSpan.Length - 1]` with length 0.
            let globalZone = zones[0]
            var regions: [InstrumentRegion] = []
            regions.reserveCapacity(zones.count - 1)
            for i in 1..<zones.count {
                let modulators = ModulatorResolver.resolveInstrument(
                    global: globalZone.modulators, local: zones[i].modulators
                )
                regions.append(
                    try InstrumentRegion(
                        global: globalZone.generators, local: zones[i].generators, samples: samples,
                        modulators: modulators
                    )
                )
            }
            return regions
        } else {
            // No global zone.
            var regions: [InstrumentRegion] = []
            regions.reserveCapacity(zones.count)
            for zone in zones {
                let modulators = ModulatorResolver.resolveInstrument(global: [], local: zone.modulators)
                regions.append(
                    try InstrumentRegion(
                        global: Zone.empty.generators, local: zone.generators, samples: samples,
                        modulators: modulators
                    )
                )
            }
            return regions
        }
    }
}

/// Represents an instrument region.
///
/// An instrument region contains all the parameters necessary to synthesize
/// a note.
///
/// Ported from `InstrumentRegion.cs` (MeltySynth, MIT License — see NOTICE).
/// C# also keeps a private parameterless constructor backing a static
/// `InstrumentRegion.Default` singleton, used elsewhere in the C# codebase
/// (e.g. as a voice's fallback region) but not part of this task's
/// interface; it is omitted here for the same reason `Instrument.Default`
/// is (no caller yet in this port). Its SF2-spec default `gs` values are
/// still ported in full, as `defaultGs` below, since every region is built
/// from them.
public final class InstrumentRegion {
    /// The sample corresponding to the region.
    public let sample: SampleHeader

    /// Raw generator values (widened to `Int16` from the `UInt16` wire
    /// value at `SetParameter` time), indexed by `GeneratorType.rawValue`.
    private let gs: [Int16]

    /// The effective note-on modulator set resolved for this region (design spec §5,
    /// `ModulatorResolver.resolveInstrument`): SF2 defaults, overridden/extended by the owning
    /// instrument's global- then local-zone modulators. Empty for any caller that doesn't pass
    /// `modulators:` (mirrors `Zone.modulators`'s own empty-by-default shape). No C# counterpart —
    /// new plumbing for the optional note-on-modulator feature.
    var modulators: [Modulator] = []

    /// SF2-spec default generator values, applied before any zone
    /// generators. Mirrors the field initializers in `InstrumentRegion`'s
    /// private parameterless constructor exactly; every generator not
    /// listed here defaults to 0.
    private static let defaultGs: [Int16] = {
        var gs = [Int16](repeating: 0, count: GeneratorType.count)
        gs[Int(GeneratorType.initialFilterCutoffFrequency.rawValue)] = 13500
        gs[Int(GeneratorType.delayModulationLfo.rawValue)] = -12000
        gs[Int(GeneratorType.delayVibratoLfo.rawValue)] = -12000
        gs[Int(GeneratorType.delayModulationEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.attackModulationEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.holdModulationEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.decayModulationEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.releaseModulationEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.delayVolumeEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.attackVolumeEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.holdVolumeEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.decayVolumeEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.releaseVolumeEnvelope.rawValue)] = -12000
        gs[Int(GeneratorType.keyRange.rawValue)] = 0x7F00
        gs[Int(GeneratorType.velocityRange.rawValue)] = 0x7F00
        gs[Int(GeneratorType.keyNumber.rawValue)] = -1
        gs[Int(GeneratorType.velocity.rawValue)] = -1
        gs[Int(GeneratorType.scaleTuning.rawValue)] = 100
        gs[Int(GeneratorType.overridingRootKey.rawValue)] = -1
        return gs
    }()

    /// Builds a region from a global zone's generators (the base setting,
    /// possibly empty) and a local zone's generators (applied on top,
    /// overriding the global ones), then resolves the sample. Mirrors the
    /// private `InstrumentRegion(Instrument, Zone, Zone, SampleHeader[])`
    /// constructor, including its generator-application order: SF2 defaults
    /// → global zone → local zone.
    ///
    /// `modulators:` is the already-resolved effective note-on modulator set for this region
    /// (`ModulatorResolver.resolveInstrument`, computed by `Instrument.buildRegions` from the owning
    /// global/local zones' own modulator slices) — unlike generators, it is not combined inside this
    /// initializer, since modulator combining is identity-based supersession (§5), not a per-slot
    /// overwrite. Defaults to `[]` for callers that don't pass it (e.g. tests exercising only
    /// generators).
    ///
    /// Note: C#'s constructor threads the owning `Instrument` through only
    /// to name-qualify the invalid-sample-ID error message; this task's
    /// pinned interface has no such parameter, so the message here is
    /// generic instead (the thrown error type/condition is unchanged).
    init(global: [Generator], local: [Generator], samples: [SampleHeader], modulators: [Modulator] = []) throws {
        var gs = InstrumentRegion.defaultGs

        for generator in global {
            InstrumentRegion.setParameter(generator, into: &gs)
        }
        for generator in local {
            InstrumentRegion.setParameter(generator, into: &gs)
        }

        let id = Int(gs[Int(GeneratorType.sampleID.rawValue)])
        guard id >= 0, id < samples.count else {
            throw SwiftySynthError.invalidSoundFont("The instrument region contains an invalid sample ID '\(id)'.")
        }

        self.gs = gs
        self.sample = samples[id]
        self.modulators = modulators
    }

    /// Mirrors `SetParameter`: unknown generator types are ignored. C#
    /// achieves this via its unchecked enum cast (an out-of-range raw value
    /// still reaches the bounds check below and fails it, since it maps to
    /// no `GeneratorType` case and so no `gs` slot); the Swift port's
    /// `generator.type == nil` guard is the LIVE equivalent of that same
    /// bounds check — `Generator.init(reader:)` already turned the
    /// out-of-range raw value into `nil` (see `Generator.swift`), so
    /// guarding here drops it the same way C#'s bounds check would. Every
    /// defined `GeneratorType` case still falls within `0..<gs.count`
    /// (`GeneratorType.count == 61 == gs.count`), so once `type` is
    /// non-nil the bounds check below can never actually reject anything
    /// reachable through this port; it is kept for parity with the source.
    private static func setParameter(_ generator: Generator, into gs: inout [Int16]) {
        guard let type = generator.type else { return }
        let index = Int(type.rawValue)
        if index >= 0 && index < gs.count {
            gs[index] = Int16(bitPattern: generator.value)
        }
    }

    /// Checks if the region covers the given key and velocity.
    public func contains(key: Int, velocity: Int) -> Bool {
        let containsKey = keyRangeStart <= key && key <= keyRangeEnd
        let containsVelocity = velocityRangeStart <= velocity && velocity <= velocityRangeEnd
        return containsKey && containsVelocity
    }

    /// Internal raw `gs` access, indexed by generator type. Needed by
    /// `RegionPair` (preset region ⊕ instrument region relative offsets).
    subscript(_ type: GeneratorType) -> Int16 {
        gs[Int(type.rawValue)]
    }

    public var sampleStart: Int { Int(sample.start) + startAddressOffset }
    public var sampleEnd: Int { Int(sample.end) + endAddressOffset }
    public var sampleStartLoop: Int { Int(sample.startLoop) + startLoopAddressOffset }
    public var sampleEndLoop: Int { Int(sample.endLoop) + endLoopAddressOffset }

    public var startAddressOffset: Int {
        32_768 * Int(self[.startAddressCoarseOffset]) + Int(self[.startAddressOffset])
    }
    public var endAddressOffset: Int {
        32_768 * Int(self[.endAddressCoarseOffset]) + Int(self[.endAddressOffset])
    }
    public var startLoopAddressOffset: Int {
        32_768 * Int(self[.startLoopAddressCoarseOffset]) + Int(self[.startLoopAddressOffset])
    }
    public var endLoopAddressOffset: Int {
        32_768 * Int(self[.endLoopAddressCoarseOffset]) + Int(self[.endLoopAddressOffset])
    }

    public var modulationLfoToPitch: Int { Int(self[.modulationLfoToPitch]) }
    public var vibratoLfoToPitch: Int { Int(self[.vibratoLfoToPitch]) }
    public var modulationEnvelopeToPitch: Int { Int(self[.modulationEnvelopeToPitch]) }
    public var initialFilterCutoffFrequency: Float {
        SoundFontMath.centsToHertz(Float(self[.initialFilterCutoffFrequency]))
    }
    public var initialFilterQ: Float { 0.1 * Float(self[.initialFilterQ]) }
    public var modulationLfoToFilterCutoffFrequency: Int { Int(self[.modulationLfoToFilterCutoffFrequency]) }
    public var modulationEnvelopeToFilterCutoffFrequency: Int { Int(self[.modulationEnvelopeToFilterCutoffFrequency]) }

    public var modulationLfoToVolume: Float { 0.1 * Float(self[.modulationLfoToVolume]) }

    public var chorusEffectsSend: Float { 0.1 * Float(self[.chorusEffectsSend]) }
    public var reverbEffectsSend: Float { 0.1 * Float(self[.reverbEffectsSend]) }
    public var pan: Float { 0.1 * Float(self[.pan]) }

    public var delayModulationLfo: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayModulationLfo])) }
    public var frequencyModulationLfo: Float { SoundFontMath.centsToHertz(Float(self[.frequencyModulationLfo])) }
    public var delayVibratoLfo: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayVibratoLfo])) }
    public var frequencyVibratoLfo: Float { SoundFontMath.centsToHertz(Float(self[.frequencyVibratoLfo])) }
    public var delayModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayModulationEnvelope])) }
    public var attackModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.attackModulationEnvelope])) }
    public var holdModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.holdModulationEnvelope])) }
    public var decayModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.decayModulationEnvelope])) }
    public var sustainModulationEnvelope: Float { 0.1 * Float(self[.sustainModulationEnvelope]) }
    public var releaseModulationEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.releaseModulationEnvelope])) }
    public var keyNumberToModulationEnvelopeHold: Int { Int(self[.keyNumberToModulationEnvelopeHold]) }
    public var keyNumberToModulationEnvelopeDecay: Int { Int(self[.keyNumberToModulationEnvelopeDecay]) }
    public var delayVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.delayVolumeEnvelope])) }
    public var attackVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.attackVolumeEnvelope])) }
    public var holdVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.holdVolumeEnvelope])) }
    public var decayVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.decayVolumeEnvelope])) }
    public var sustainVolumeEnvelope: Float { 0.1 * Float(self[.sustainVolumeEnvelope]) }
    public var releaseVolumeEnvelope: Float { SoundFontMath.timecentsToSeconds(Float(self[.releaseVolumeEnvelope])) }
    public var keyNumberToVolumeEnvelopeHold: Int { Int(self[.keyNumberToVolumeEnvelopeHold]) }
    public var keyNumberToVolumeEnvelopeDecay: Int { Int(self[.keyNumberToVolumeEnvelopeDecay]) }

    public var keyRangeStart: Int { Int(self[.keyRange]) & 0xFF }
    public var keyRangeEnd: Int { (Int(self[.keyRange]) >> 8) & 0xFF }
    public var velocityRangeStart: Int { Int(self[.velocityRange]) & 0xFF }
    public var velocityRangeEnd: Int { (Int(self[.velocityRange]) >> 8) & 0xFF }

    public var initialAttenuation: Float { 0.1 * Float(self[.initialAttenuation]) }

    public var coarseTune: Int { Int(self[.coarseTune]) }
    public var fineTune: Int { Int(self[.fineTune]) + Int(sample.pitchCorrection) }

    /// Mirrors `this[GeneratorType.SampleModes] != 2 ? (LoopMode)raw :
    /// LoopMode.NoLoop`. C#'s cast to `LoopMode` never fails (C# enums are
    /// unchecked integer wrappers), so an out-of-spec raw value other than
    /// the documented "2" would silently produce an enum instance matching
    /// none of the named cases. Swift's `LoopMode(rawValue:)` has no such
    /// instance to produce, so any raw value with no matching case —
    /// including but not limited to 2 — folds into `.noLoop`, which is the
    /// same fallback C#'s own `!= 2` branch already uses for the one
    /// documented case.
    public var sampleModes: LoopMode {
        let raw = self[.sampleModes]
        if raw != 2, let mode = LoopMode(rawValue: Int(raw)) {
            return mode
        }
        return .noLoop
    }

    public var scaleTuning: Int { Int(self[.scaleTuning]) }
    public var exclusiveClass: Int { Int(self[.exclusiveClass]) }
    public var rootKey: Int {
        let overriding = self[.overridingRootKey]
        return overriding != -1 ? Int(overriding) : Int(sample.originalPitch)
    }
}
