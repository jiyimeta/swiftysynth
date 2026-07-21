/// The controller identity carried by a decoded modulator source word (SF2 §8.2.1).
///
/// Only `.none`, `.velocity`, and `.keyNumber` are "note-on" — every other case (a continuous
/// MIDI controller, or a general-controller index this port does not special-case) requires
/// per-block re-evaluation and is out of scope for the note-on-only modulator engine this feature
/// adds (full-port spec §2/§9.5.1).
enum ModulatorController: Equatable {
    case none
    case velocity
    case keyNumber
    case cc(Int)
    case other(index: Int)
}

/// Source transform direction (SF2 §8.2.1 word bit 8): 0 = increasing with the source value,
/// 1 = decreasing.
enum Direction: Equatable {
    case minToMax
    case maxToMin
}

/// Source transform polarity (SF2 §8.2.1 word bit 9): 0 = the source ranges over `0...1`,
/// 1 = over `-1...1`.
enum Polarity: Equatable {
    case unipolar
    case bipolar
}

/// Source transform curve shape (SF2 §8.2.1 word bits 10...15, §8.2.4).
enum CurveType: Equatable {
    case linear
    case concave
    case convex
    case `switch`
}

/// One decoded modulator source word (`sourceOper` or `amountSourceOper`), SF2 §8.2.1.
///
/// Ported from the source-word decode described in `Modulator.cs` (MeltySynth, MIT License — see
/// NOTICE), reinterpreted per the SF2 spec bit layout: index bits 0...6, CC flag bit 7, direction
/// bit 8, polarity bit 9, curve-type bits 10...15.
struct ModulatorSource: Equatable {
    let controller: ModulatorController
    let isCC: Bool
    let direction: Direction
    let polarity: Polarity
    let curve: CurveType

    /// False when the raw 6-bit curve-type field (word bits 10...15) held a value greater than 3.
    /// SF2 §8.2.4 only defines four curves (linear/concave/convex/switch, values 0...3); this is
    /// one of `Modulator.isValid`'s skip rules (full-port spec §2). A "> 3" value always sets one
    /// of bits 12...15, so this is equivalent to (and replaces) checking those bits directly — see
    /// spec §2's note on the SF2.00-era "bits 11...15" erratum, which this port deliberately does
    /// NOT follow (it would wrongly reject convex/switch, values 2 and 3).
    ///
    /// `fileprivate`, not `private`: `Modulator.isValid` (a different type, same file) reads this
    /// on both `source` and `amountSource`; nothing outside `Modulator.swift` needs it.
    fileprivate let isValidCurve: Bool

    init(rawValue: UInt16) {
        let index = Int(rawValue & 0x7F)
        let ccFlag = (rawValue >> 7) & 0x1 == 1
        let curveTypeRaw = (rawValue >> 10) & 0x3F

        self.isCC = ccFlag
        self.controller = ccFlag ? .cc(index) : ModulatorSource.generalController(index: index)
        self.direction = (rawValue >> 8) & 0x1 == 1 ? .maxToMin : .minToMax
        self.polarity = (rawValue >> 9) & 0x1 == 1 ? .bipolar : .unipolar

        switch curveTypeRaw {
        case 0:
            self.curve = .linear
            self.isValidCurve = true
        case 1:
            self.curve = .concave
            self.isValidCurve = true
        case 2:
            self.curve = .convex
            self.isValidCurve = true
        case 3:
            self.curve = .switch
            self.isValidCurve = true
        default:
            self.curve = .linear
            self.isValidCurve = false
        }
    }

    /// General-controller palette (SF2 §8.2.1 table), used only when the CC flag is clear. Only
    /// the three note-on controllers get a named case; every other general-controller index (poly
    /// pressure, channel pressure, pitch wheel, pitch wheel sensitivity, link, …) is real-time and
    /// stored as `.other` for the modulator engine (later tasks) to skip.
    private static func generalController(index: Int) -> ModulatorController {
        switch index {
        case 0:
            return .none
        case 2:
            return .velocity
        case 3:
            return .keyNumber
        default:
            return .other(index: index)
        }
    }

    /// True for the three note-on-only general controllers (§8.2.1) with the CC flag clear —
    /// `Modulator.isNoteOn` requires this of both the source and the amount-source.
    var isNoteOn: Bool {
        guard !isCC else { return false }
        switch controller {
        case .none, .velocity, .keyNumber:
            return true
        case .cc, .other:
            return false
        }
    }

    /// True when this source is the SF2 "Link" general controller (CC flag clear, index 127 —
    /// §8.2.1's general-controller table). A linked source's value comes from another modulator's
    /// output, not an actual MIDI signal; full-port spec §2/§7.4/§9.5.4 requires a modulator using
    /// Link as either its source or its amount-source to be rejected outright. This is distinct
    /// from the `destOper` bit-15 "linked destination" flag (`Modulator.isLinkedDestination`) —
    /// §8.2.1 lists 127 as a real (if unusual) general-controller enumerator, so it is NOT already
    /// caught by "unlisted values are reserved/ignored", and the CC-flag-clear guard here keeps a
    /// genuine MIDI CC 127 (already illegal via the CC-index rule) from being conflated with it.
    var isLink: Bool {
        !isCC && controller == .other(index: 127)
    }
}

/// The modulator transform operator (SF2 §8.3): `0` leaves the computed value as-is, `2` takes its
/// absolute value. No other enumerator is defined.
enum ModulatorTransformOp: Equatable {
    case linear
    case absoluteValue
}

extension GeneratorType {
    /// True when this generator is a modulator-eligible "Value Generator" (SF2 §8.1.1: "Modulator
    /// Destinations are exclusively the list of Value Generators"). Excludes, per full-port spec §6:
    /// the range generators (keyRange, velocityRange); the index generators (instrument, sampleID);
    /// the sample-address offset generators (start/end/loop, coarse and fine); the substitution
    /// generators (keyNumber, velocity); the sample generators (sampleModes, exclusiveClass,
    /// overridingRootKey); and the unused/reserved slots.
    var isModulatorDestination: Bool {
        switch self {
        case .startAddressOffset, .endAddressOffset, .startLoopAddressOffset, .endLoopAddressOffset,
            .startAddressCoarseOffset, .endAddressCoarseOffset, .startLoopAddressCoarseOffset,
            .endLoopAddressCoarseOffset:
            // Sample-address offset generators.
            return false
        case .instrument, .sampleID:
            // Index generators.
            return false
        case .keyRange, .velocityRange:
            // Range generators.
            return false
        case .keyNumber, .velocity:
            // Substitution generators.
            return false
        case .sampleModes, .exclusiveClass, .overridingRootKey:
            // Sample generators.
            return false
        case .unused1, .unused2, .unused3, .unused4, .unused5, .unusedEnd, .reserved1, .reserved2,
            .reserved3:
            // Unused/reserved slots.
            return false
        default:
            return true
        }
    }
}

/// A single decoded SF2 modulator record (`pmod`/`imod`), 10 bytes on the wire: `sourceOper`,
/// `destOper`, `amount` (signed), `amountSourceOper`, `transformOper` (SF2 §8.2/§8.3/§9.5.4).
///
/// Ported from `Modulator.cs` (MeltySynth, MIT License — see NOTICE). MeltySynth itself never
/// decodes past the raw bytes (it discards every modulator record); this decode is new plumbing
/// for the optional note-on-modulator feature (full-port spec §2) and has no C# counterpart to
/// mirror beyond the wire layout.
struct Modulator {
    let source: ModulatorSource
    let destination: GeneratorType?
    let amount: Int
    let amountSource: ModulatorSource
    let transform: ModulatorTransformOp

    /// False when `transformOper` was neither 0 (linear) nor 2 (absolute value) — an unknown
    /// transform enumerator (SF2 §8.3), one of `isValid`'s skip rules (spec §2). `private`: only
    /// `Modulator`'s own `read`/`isValid` need it.
    private let isValidTransform: Bool

    /// True when `destOper` bit 15 (the "linked destination" flag, SF2 §9.5.4) was set. A linked
    /// modulator's low 15 bits index another modulator's amount-source rather than a generator, so
    /// `destination` is `nil` whenever this is true. `private`: only `Modulator`'s own
    /// `read`/`isValid` need it.
    private let isLinkedDestination: Bool

    /// Reads one 10-byte `pmod`/`imod` record.
    static func read(from reader: BinaryReader) throws -> Modulator {
        let sourceOper = try reader.readUInt16()
        let destOper = try reader.readUInt16()
        let amount = Int(try reader.readInt16())
        let amountSourceOper = try reader.readUInt16()
        let transformOper = try reader.readUInt16()

        let isLinkedDestination = destOper & 0x8000 != 0
        let destination = isLinkedDestination ? nil : GeneratorType(rawValue: destOper)

        let transform: ModulatorTransformOp
        let isValidTransform: Bool
        switch transformOper {
        case 0:
            transform = .linear
            isValidTransform = true
        case 2:
            transform = .absoluteValue
            isValidTransform = true
        default:
            transform = .linear
            isValidTransform = false
        }

        return Modulator(
            source: ModulatorSource(rawValue: sourceOper),
            destination: destination,
            amount: amount,
            amountSource: ModulatorSource(rawValue: amountSourceOper),
            transform: transform,
            isValidTransform: isValidTransform,
            isLinkedDestination: isLinkedDestination
        )
    }

    /// The illegal (0/6/32/38/98...101/120...127) and reserved (33...63) CC-flagged source
    /// indices (SF2 §8.2.1, full-port spec §2). Only meaningful for a CC-flagged source; a
    /// general-controller source (CC flag clear) never fails this check.
    private static let illegalCCIndices: Set<Int> = [0, 6, 32, 38, 98, 99, 100, 101, 120, 121, 122, 123,
        124, 125, 126, 127]

    private static func hasIllegalCCIndex(_ source: ModulatorSource) -> Bool {
        guard case let .cc(index) = source.controller else { return false }
        return illegalCCIndices.contains(index) || (33...63).contains(index)
    }

    /// False when any skip rule (full-port spec §2) fires: an illegal/reserved CC-flagged source
    /// index on either source; an unknown source curve type (value > 3) on either source; an
    /// unknown transform enumerator; a linked source, linked amount-source, or linked destination
    /// (SF2 §7.4/§8.2.1/§9.5.4 — a "Link" general controller, CC clear + index 127, on either
    /// source is rejected the same as a `destOper` bit-15 linked destination); or a destination
    /// that is not a modulator-eligible Value Generator (SF2 §8.1.1).
    var isValid: Bool {
        guard !isLinkedDestination, let destination, destination.isModulatorDestination else {
            return false
        }
        guard isValidTransform else { return false }
        guard source.isValidCurve, amountSource.isValidCurve else { return false }
        guard !source.isLink, !amountSource.isLink else { return false }
        guard !Modulator.hasIllegalCCIndex(source), !Modulator.hasIllegalCCIndex(amountSource) else {
            return false
        }
        return true
    }

    /// True when both the source and the amount-source are note-on-only controllers (§9.5.1) —
    /// the only modulators this feature's engine (later tasks) evaluates.
    var isNoteOn: Bool {
        source.isNoteOn && amountSource.isNoteOn
    }

    /// Mirrors `Modulator.DiscardData`: each modulator record is 10 bytes; a chunk size that is
    /// not a whole number of records is structurally invalid (thrown, never trapped), otherwise
    /// the chunk is skipped. Kept for `SoundFontParameters.swift`, which still discards every
    /// modulator record wholesale (Task 5 switches it over to `read`/`isValid`/`isNoteOn`).
    static func discardData(reader: BinaryReader, size: Int) throws {
        guard size % 10 == 0 else {
            throw SwiftySynthError.invalidSoundFont("The modulator list is invalid.")
        }
        try reader.skip(size)
    }
}
