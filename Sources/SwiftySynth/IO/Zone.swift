/// Raw `pbag`/`ibag` sub-chunk record: generator/modulator start index plus
/// the derived counts (the difference to the next record's start index).
///
/// Ported from `ZoneInfo.cs` (MeltySynth, MIT License — see NOTICE). C#
/// models this as a mutable class (indices set at parse time, counts filled
/// in by a second pass over consecutive records); the Swift port is an
/// immutable `struct` — the two-pass computation happens inside `create`
/// before each `ZoneInfo` is constructed.
struct ZoneInfo {
    let generatorIndex: Int
    let modulatorIndex: Int
    let generatorCount: Int
    let modulatorCount: Int

    /// Reads a `pbag`/`ibag` sub-chunk. Each record is 4 bytes (u16
    /// generatorIndex + u16 modulatorIndex). The count for each record is
    /// the difference to the *next* record's index; the terminal (last)
    /// record therefore has no next record and its counts are left at 0.
    static func create(reader: BinaryReader, size: Int) throws -> [ZoneInfo] {
        // A negative `size` that is still a multiple of 4 (e.g. a corrupt
        // pbag/ibag chunk length) would make `count` negative and Swift's
        // `0..<count` build an inverted range and trap. Reject it up front
        // to preserve the "never trap the host app" invariant, matching the
        // sibling readers (`Generator.readFromChunk`,
        // `SampleHeader.readFromChunk`, `InstrumentInfo.create`,
        // `PresetInfo.create`). Unlike those, `ZoneInfo` keeps every record
        // (including the terminal), so there is no `- 1` in the count and a
        // zero-length chunk (empty zone list) is left for the caller
        // (`Zone.create`) to reject, not this guard.
        guard size >= 0, size % 4 == 0 else {
            throw SwiftySynthError.invalidSoundFont("The zone list is invalid.")
        }

        let count = size / 4

        var indices: [(generatorIndex: Int, modulatorIndex: Int)] = []
        // Reserve clamped to what the remaining bytes could hold: the claimed
        // chunk size is untrusted, and the read loop below is already EOF-safe,
        // so the clamp can only shrink a doomed reserve — it never changes what
        // parses.
        indices.reserveCapacity(min(count, reader.bytesRemaining / 4))
        for _ in 0..<count {
            let generatorIndex = Int(try reader.readUInt16())
            let modulatorIndex = Int(try reader.readUInt16())
            indices.append((generatorIndex, modulatorIndex))
        }

        var infos: [ZoneInfo] = []
        infos.reserveCapacity(count)
        for i in 0..<count {
            let generatorCount: Int
            let modulatorCount: Int
            if i < count - 1 {
                generatorCount = indices[i + 1].generatorIndex - indices[i].generatorIndex
                modulatorCount = indices[i + 1].modulatorIndex - indices[i].modulatorIndex
            } else {
                generatorCount = 0
                modulatorCount = 0
            }
            infos.append(
                ZoneInfo(
                    generatorIndex: indices[i].generatorIndex,
                    modulatorIndex: indices[i].modulatorIndex,
                    generatorCount: generatorCount,
                    modulatorCount: modulatorCount
                )
            )
        }

        return infos
    }
}

/// A SoundFont zone: the slice of `generators` (and, for the optional
/// note-on-modulator feature, `modulators`) that applies within one
/// preset/instrument bag entry.
///
/// Ported from `Zone.cs` (MeltySynth, MIT License — see NOTICE). C# models
/// this as a `struct` wrapping an `ArraySegment<Generator>`; the Swift port
/// is a `final class` per this package's canon and holds a plain `[Generator]`
/// slice-copy instead of a segment view.
final class Zone {
    let generators: [Generator]

    /// This zone's modulator slice (`pmod`/`imod`), cut from the parsed
    /// modulator array using `ZoneInfo.modulatorIndex`/`modulatorCount`
    /// (full-port spec §2). Empty for callers that don't pass modulators
    /// (`Zone(generators:)`, `Zone.empty`, and any `Zone.create` call that
    /// omits `modulators:`).
    let modulators: [Modulator]

    /// The empty zone, used as the base setting when an instrument/preset has
    /// no global zone. Mirrors `Zone.Empty` in `Zone.cs`, which is itself a
    /// computed property returning a fresh instance on every access (not a
    /// singleton) — a computed property here (rather than a stored `static
    /// let`) also sidesteps Swift 6 strict-concurrency's "shared mutable
    /// global state" check for this non-`Sendable` class.
    static var empty: Zone { Zone(generators: []) }

    init(generators: [Generator], modulators: [Modulator] = []) {
        self.generators = generators
        self.modulators = modulators
    }

    private init(info: ZoneInfo, generators: [Generator], modulators: [Modulator]) throws {
        let start = info.generatorIndex
        let count = info.generatorCount
        // The bag indices come straight from raw pbag/ibag data and are not
        // otherwise validated against the actual generator array; corrupt or
        // non-monotonic data can produce a negative offset/count or a slice
        // running past the end. C#'s `ArraySegment<Generator>(generators,
        // offset, count)` throws on those; validate here so the Swift slice
        // subscript never traps.
        guard start >= 0, count >= 0, start + count <= generators.count else {
            throw SwiftySynthError.invalidSoundFont("The zone contains an invalid generator range.")
        }
        self.generators = Array(generators[start..<(start + count)])

        let mStart = info.modulatorIndex
        let mCount = info.modulatorCount
        // Unlike the generator-range guard above, this is deliberately
        // non-throwing (full-port spec §2, deviation from SF2 §7.3/§7.7): a
        // font with a corrupt wModNdx loads fine today because nothing
        // consumes those indices, and this feature must not turn that into a
        // load failure. An out-of-range slice just yields no modulators for
        // this zone instead of rejecting the whole font.
        if mStart >= 0, mCount >= 0, mStart + mCount <= modulators.count {
            self.modulators = Array(modulators[mStart..<(mStart + mCount)])
        } else {
            self.modulators = []
        }
    }

    /// Slices `generators` (and, if present, `modulators`) into zones
    /// according to `infos`. The last info record is always the terminator
    /// and produces no zone.
    static func create(infos: [ZoneInfo], generators: [Generator], modulators: [Modulator] = []) throws -> [Zone] {
        guard infos.count > 1 else {
            throw SwiftySynthError.invalidSoundFont("No valid zone was found.")
        }

        var zones: [Zone] = []
        zones.reserveCapacity(infos.count - 1)
        for i in 0..<(infos.count - 1) {
            zones.append(try Zone(info: infos[i], generators: generators, modulators: modulators))
        }

        return zones
    }
}
