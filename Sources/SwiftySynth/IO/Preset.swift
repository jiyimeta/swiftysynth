/// Raw `phdr` sub-chunk record: name, patch/bank numbers, library/genre/
/// morphology, plus the pbag start index, with the end index derived from
/// the next record's start index.
///
/// Ported from `PresetInfo.cs` (MeltySynth, MIT License — see NOTICE). C#
/// models this as a mutable class (`zoneEndIndex` is back-filled by a second
/// pass over consecutive records); the Swift port is an immutable `struct` —
/// the two-pass computation happens inside `create` before each `PresetInfo`
/// is constructed, mirroring the `InstrumentInfo` port (Task 10).
struct PresetInfo {
    let name: String
    let patchNumber: Int
    let bankNumber: Int
    let library: Int
    let genre: Int
    let morphology: Int
    let zoneStartIndex: Int
    let zoneEndIndex: Int

    /// Reads a `phdr` sub-chunk. Each record is 38 bytes (20-byte
    /// fixed-length name + u16 patchNumber + u16 bankNumber + u16
    /// zoneStartIndex + i32 library + i32 genre + i32 morphology). The last
    /// record is the `EOP` terminator; it is still returned here (matching
    /// `PresetInfo.cs`, which never drops it) — the caller (`Preset.create`)
    /// is responsible for excluding it from the produced presets.
    static func create(reader: BinaryReader, size: Int) throws -> [PresetInfo] {
        // C#'s `size / 38` on a negative size (still a multiple of 38) would
        // yield a negative count and throw (catchably) on `new
        // PresetInfo[count]`; Swift's `0..<count` would instead build an
        // inverted range and trap. Reject a negative size up front to
        // preserve the "never trap the host app" invariant.
        guard size >= 0, size % 38 == 0 else {
            throw SwiftySynthError.invalidSoundFont("The preset list is invalid.")
        }

        let count = size / 38

        var names: [String] = []
        var patchNumbers: [Int] = []
        var bankNumbers: [Int] = []
        var zoneStartIndices: [Int] = []
        var libraries: [Int] = []
        var genres: [Int] = []
        var morphologies: [Int] = []
        names.reserveCapacity(count)
        patchNumbers.reserveCapacity(count)
        bankNumbers.reserveCapacity(count)
        zoneStartIndices.reserveCapacity(count)
        libraries.reserveCapacity(count)
        genres.reserveCapacity(count)
        morphologies.reserveCapacity(count)
        for _ in 0..<count {
            names.append(try reader.readFixedLengthString(20))
            patchNumbers.append(Int(try reader.readUInt16()))
            bankNumbers.append(Int(try reader.readUInt16()))
            zoneStartIndices.append(Int(try reader.readUInt16()))
            libraries.append(Int(try reader.readInt32()))
            genres.append(Int(try reader.readInt32()))
            morphologies.append(Int(try reader.readInt32()))
        }

        var infos: [PresetInfo] = []
        infos.reserveCapacity(count)
        for i in 0..<count {
            // The terminal record has no "next" record to derive an end
            // index from; it is left at 0, matching C#'s unset (default)
            // `zoneEndIndex` field. It is never read, since `Preset.create`
            // drops the terminal record.
            let zoneEndIndex = i < count - 1 ? zoneStartIndices[i + 1] - 1 : 0
            infos.append(
                PresetInfo(
                    name: names[i],
                    patchNumber: patchNumbers[i],
                    bankNumber: bankNumbers[i],
                    library: libraries[i],
                    genre: genres[i],
                    morphology: morphologies[i],
                    zoneStartIndex: zoneStartIndices[i],
                    zoneEndIndex: zoneEndIndex
                )
            )
        }

        return infos
    }
}

/// Represents a preset in the SoundFont.
///
/// Ported from `Preset.cs` (MeltySynth, MIT License — see NOTICE). C# also
/// keeps a private parameterless constructor backing a static
/// `Preset.Default` singleton (name `"Default"`, no regions); that singleton
/// is not part of this task's interface and has no caller yet, so it is
/// omitted here (mirrors Task 10 omitting `Instrument.Default` for the same
/// reason).
public final class Preset {
    public let name: String
    public let patchNumber: Int
    public let bankNumber: Int
    public let library: Int
    public let genre: Int
    public let morphology: Int
    public let regions: [PresetRegion]

    /// Reader-driven initializer: resolves `info`'s zone range against the
    /// full `zones` array (shared across all presets), then builds regions
    /// from that slice. Mirrors the private
    /// `Preset(PresetInfo, Zone[], Instrument[])` constructor.
    init(info: PresetInfo, zones: [Zone], instruments: [Instrument]) throws {
        self.name = info.name
        self.patchNumber = info.patchNumber
        self.bankNumber = info.bankNumber
        self.library = info.library
        self.genre = info.genre
        self.morphology = info.morphology

        let zoneCount = info.zoneEndIndex - info.zoneStartIndex + 1
        guard zoneCount > 0 else {
            throw SwiftySynthError.invalidSoundFont("The preset '\(info.name)' has no zone.")
        }

        // `zones.AsSpan(zoneStartIndex, zoneCount)` throws (catchably) in C#
        // when the range is out of bounds; validate here so the Swift slice
        // subscript below never traps on corrupt bag-index data.
        guard info.zoneStartIndex >= 0, info.zoneStartIndex + zoneCount <= zones.count else {
            throw SwiftySynthError.invalidSoundFont("The preset '\(info.name)' has an invalid zone range.")
        }

        let zoneSlice = Array(zones[info.zoneStartIndex..<(info.zoneStartIndex + zoneCount)])
        self.regions = try Preset.buildRegions(zones: zoneSlice, instruments: instruments)
    }

    /// Direct-construction initializer for tests (no C# analogue; C# only
    /// has the reader-based private constructor plus the `Default`
    /// singleton). Takes the preset's zones directly instead of resolving
    /// them from a shared array via a `PresetInfo`. `library`/`genre`/
    /// `morphology` have no test-facing inputs in this task's interface, so
    /// they default to 0 (the same value an unset `phdr` field would carry).
    init(name: String, patchNumber: Int, bankNumber: Int, zones: [Zone], instruments: [Instrument]) throws {
        self.name = name
        self.patchNumber = patchNumber
        self.bankNumber = bankNumber
        self.library = 0
        self.genre = 0
        self.morphology = 0
        self.regions = try Preset.buildRegions(zones: zones, instruments: instruments)
    }

    /// Builds all presets from the `phdr` records. Mirrors `Preset.Create`,
    /// including dropping the last (terminator) record.
    static func create(infos: [PresetInfo], zones: [Zone], instruments: [Instrument]) throws -> [Preset] {
        guard infos.count > 1 else {
            throw SwiftySynthError.invalidSoundFont("No valid preset was found.")
        }

        // The last one is the terminator.
        var presets: [Preset] = []
        presets.reserveCapacity(infos.count - 1)
        for i in 0..<(infos.count - 1) {
            presets.append(try Preset(info: infos[i], zones: zones, instruments: instruments))
        }

        return presets
    }

    /// Decides which zone (if any) is the global zone and builds one
    /// `PresetRegion` per local zone accordingly. Mirrors
    /// `PresetRegion.Create`'s global-zone detection, which in the C# source
    /// lives on `PresetRegion` itself; it is relocated onto `Preset` here
    /// because this task's `PresetRegion` interface exposes only the
    /// per-region `init(global:local:instruments:)`, not a
    /// zone-array-consuming factory. Unlike `InstrumentRegion`'s terminator
    /// (`.sampleID`), a preset zone's terminator generator is `.instrument`.
    private static func buildRegions(zones: [Zone], instruments: [Instrument]) throws -> [PresetRegion] {
        // C#'s `zones[0]` on an empty span throws (catchably) an
        // IndexOutOfRangeException; guard explicitly so this never traps.
        guard !zones.isEmpty else {
            throw SwiftySynthError.invalidSoundFont("The preset has no zone.")
        }

        let firstIsGlobal = zones[0].generators.isEmpty || zones[0].generators.last?.type != .instrument

        if firstIsGlobal {
            // The global zone is regarded as the base setting of subsequent
            // zones. Note the single-zone edge case: if there is exactly one
            // zone and it is the global one, there are zero local zones and
            // the region list is empty — matching C#'s
            // `new PresetRegion[zoneSpan.Length - 1]` with length 0.
            let global = zones[0].generators
            var regions: [PresetRegion] = []
            regions.reserveCapacity(zones.count - 1)
            for i in 1..<zones.count {
                regions.append(
                    try PresetRegion(global: global, local: zones[i].generators, instruments: instruments)
                )
            }
            return regions
        } else {
            // No global zone.
            var regions: [PresetRegion] = []
            regions.reserveCapacity(zones.count)
            for zone in zones {
                regions.append(
                    try PresetRegion(global: Zone.empty.generators, local: zone.generators, instruments: instruments)
                )
            }
            return regions
        }
    }
}

/// Represents a preset region.
///
/// A preset region indicates how the parameters of the instrument should be
/// modified in the preset.
///
/// Ported from `PresetRegion.cs` (MeltySynth, MIT License — see NOTICE). C#
/// also keeps a private parameterless constructor backing a static
/// `PresetRegion.Default` singleton, used elsewhere in the C# codebase but
/// not part of this task's interface; it is omitted here for the same
/// reason `Preset.Default` is (no caller yet in this port). Unlike
/// `InstrumentRegion`'s SF2-spec absolute-value defaults, preset generators
/// are RELATIVE offsets applied on top of the instrument's own (already
/// resolved) parameters — so every `gs` slot defaults to 0 (the neutral
/// offset), except the key/velocity ranges which default to "no
/// restriction" exactly as they do for instruments.
public final class PresetRegion {
    /// The instrument corresponding to the region.
    public let instrument: Instrument

    /// Raw generator values (widened to `Int16` from the `UInt16` wire
    /// value at `SetParameter` time), indexed by `GeneratorType.rawValue`.
    private let gs: [Int16]

    /// Preset-generator default values: all zero (relative-offset neutral)
    /// except the full-range key/velocity defaults. Mirrors the field
    /// initializers in `PresetRegion`'s private parameterless constructor
    /// exactly.
    private static let defaultGs: [Int16] = {
        var gs = [Int16](repeating: 0, count: GeneratorType.count)
        gs[Int(GeneratorType.keyRange.rawValue)] = 0x7F00
        gs[Int(GeneratorType.velocityRange.rawValue)] = 0x7F00
        return gs
    }()

    /// Builds a region from a global zone's generators (the base setting,
    /// possibly empty) and a local zone's generators (applied on top,
    /// overriding the global ones), then resolves the instrument. Mirrors
    /// the private `PresetRegion(Preset, Zone, Zone, Instrument[])`
    /// constructor, including its generator-application order: (zero)
    /// defaults → global zone → local zone.
    ///
    /// Note: C#'s constructor threads the owning `Preset` through only to
    /// name-qualify the invalid-instrument-ID error message; this task's
    /// pinned interface has no such parameter, so the message here is
    /// generic instead (the thrown error type/condition is unchanged).
    init(global: [Generator], local: [Generator], instruments: [Instrument]) throws {
        var gs = PresetRegion.defaultGs

        for generator in global {
            PresetRegion.setParameter(generator, into: &gs)
        }
        for generator in local {
            PresetRegion.setParameter(generator, into: &gs)
        }

        let id = Int(gs[Int(GeneratorType.instrument.rawValue)])
        guard id >= 0, id < instruments.count else {
            throw SwiftySynthError.invalidSoundFont("The preset region contains an invalid instrument ID '\(id)'.")
        }

        self.gs = gs
        self.instrument = instruments[id]
    }

    /// Mirrors `SetParameter`: unknown generator types are ignored. Every
    /// defined `GeneratorType` case already falls within `0..<gs.count`
    /// (`GeneratorType.count == 61 == gs.count`), so the bounds check below
    /// can never actually reject anything reachable through this port; it
    /// is kept for parity with the source.
    private static func setParameter(_ generator: Generator, into gs: inout [Int16]) {
        let index = Int(generator.type.rawValue)
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

    public var modulationLfoToPitch: Int { Int(self[.modulationLfoToPitch]) }
    public var vibratoLfoToPitch: Int { Int(self[.vibratoLfoToPitch]) }
    public var modulationEnvelopeToPitch: Int { Int(self[.modulationEnvelopeToPitch]) }

    // Cents-valued relative offsets are converted with `centsToMultiplyingFactor`
    // (producing a multiplying *factor*, not an absolute Hz/second value) —
    // this is `PresetRegion.cs`'s formula for every one of these properties,
    // including the envelope/LFO delay-time generators (which on the
    // InstrumentRegion side use `timecentsToSeconds` for an absolute
    // duration). `centsToMultiplyingFactor` and `timecentsToSeconds` share
    // the identical `pow(2, x / 1200)` formula in `SoundFontMath`, so this
    // is a naming/semantics choice, not a numeric one — copied verbatim from
    // the reference source per this task's porting-fidelity requirement.
    public var initialFilterCutoffFrequency: Float {
        SoundFontMath.centsToMultiplyingFactor(Float(self[.initialFilterCutoffFrequency]))
    }
    public var initialFilterQ: Float { 0.1 * Float(self[.initialFilterQ]) }
    public var modulationLfoToFilterCutoffFrequency: Int { Int(self[.modulationLfoToFilterCutoffFrequency]) }
    public var modulationEnvelopeToFilterCutoffFrequency: Int { Int(self[.modulationEnvelopeToFilterCutoffFrequency]) }

    public var modulationLfoToVolume: Float { 0.1 * Float(self[.modulationLfoToVolume]) }

    public var chorusEffectsSend: Float { 0.1 * Float(self[.chorusEffectsSend]) }
    public var reverbEffectsSend: Float { 0.1 * Float(self[.reverbEffectsSend]) }
    public var pan: Float { 0.1 * Float(self[.pan]) }

    public var delayModulationLfo: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.delayModulationLfo])) }
    public var frequencyModulationLfo: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.frequencyModulationLfo])) }
    public var delayVibratoLfo: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.delayVibratoLfo])) }
    public var frequencyVibratoLfo: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.frequencyVibratoLfo])) }
    public var delayModulationEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.delayModulationEnvelope])) }
    public var attackModulationEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.attackModulationEnvelope])) }
    public var holdModulationEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.holdModulationEnvelope])) }
    public var decayModulationEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.decayModulationEnvelope])) }
    public var sustainModulationEnvelope: Float { 0.1 * Float(self[.sustainModulationEnvelope]) }
    public var releaseModulationEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.releaseModulationEnvelope])) }
    public var keyNumberToModulationEnvelopeHold: Int { Int(self[.keyNumberToModulationEnvelopeHold]) }
    public var keyNumberToModulationEnvelopeDecay: Int { Int(self[.keyNumberToModulationEnvelopeDecay]) }
    public var delayVolumeEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.delayVolumeEnvelope])) }
    public var attackVolumeEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.attackVolumeEnvelope])) }
    public var holdVolumeEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.holdVolumeEnvelope])) }
    public var decayVolumeEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.decayVolumeEnvelope])) }
    public var sustainVolumeEnvelope: Float { 0.1 * Float(self[.sustainVolumeEnvelope]) }
    public var releaseVolumeEnvelope: Float { SoundFontMath.centsToMultiplyingFactor(Float(self[.releaseVolumeEnvelope])) }
    public var keyNumberToVolumeEnvelopeHold: Int { Int(self[.keyNumberToVolumeEnvelopeHold]) }
    public var keyNumberToVolumeEnvelopeDecay: Int { Int(self[.keyNumberToVolumeEnvelopeDecay]) }

    public var keyRangeStart: Int { Int(self[.keyRange]) & 0xFF }
    public var keyRangeEnd: Int { (Int(self[.keyRange]) >> 8) & 0xFF }
    public var velocityRangeStart: Int { Int(self[.velocityRange]) & 0xFF }
    public var velocityRangeEnd: Int { (Int(self[.velocityRange]) >> 8) & 0xFF }

    public var initialAttenuation: Float { 0.1 * Float(self[.initialAttenuation]) }

    public var coarseTune: Int { Int(self[.coarseTune]) }

    /// Raw offset with no sample `pitchCorrection` folded in — unlike
    /// `InstrumentRegion.fineTune`, the preset side has no sample to pull a
    /// correction from (a preset region is relative to the instrument, not
    /// to a single sample).
    public var fineTune: Int { Int(self[.fineTune]) }

    public var scaleTuning: Int { Int(self[.scaleTuning]) }
}
