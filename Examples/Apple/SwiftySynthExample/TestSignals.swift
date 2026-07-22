import Foundation
import SwiftySynth

/// In-memory test MIDIs for the audible A/B of the SF2 note-on modulator fix.
///
/// The piano signal is the one that exposes the bug: on MuseScore_General,
/// `Acoustic Grand Piano` (program 0) is voiced through note-on modulators. With
/// modulators OFF it renders ~25 dB below its intended level (near-silent — the
/// reported Folino regression); with them ON it comes up to a natural balance
/// against the bass. The `pianoVsBass` signal plays the two back-to-back so the
/// balance can be judged directly by ear.
enum TestSignals {
    enum Kind: String, CaseIterable, Identifiable {
        case pianoPhrase = "Piano phrase (prog 0)"
        case bassPhrase = "Bass phrase (prog 33)"
        case pianoVsBass = "Piano ⇄ bass (prog 0 → 33)"
        var id: String { rawValue }
    }

    /// 480 ticks per quarter; at the default 120 bpm a quarter is 0.5 s.
    private static let tpq = 480
    private static let velocity: UInt8 = 96

    static func midi(for kind: Kind) throws -> MidiFile {
        try MidiFile(data: data(for: kind))
    }

    static func data(for kind: Kind) -> Data {
        switch kind {
        case .pianoPhrase:
            return smf(progression(program: 0, chords: majorProgression))
        case .bassPhrase:
            return smf(progression(program: 33, chords: bassRoots))
        case .pianoVsBass:
            return smf(alternating())
        }
    }

    // MARK: Phrases

    /// I–IV–V–I block-chord voicings; sustained so loudness is easy to judge.
    private static let majorProgression = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]
    /// The same roots two octaves down, one note each (bass is monophonic).
    private static let bassRoots = [[36], [41], [43], [36]]

    private static func progression(program: UInt8, chords: [[Int]]) -> [Event] {
        var events: [Event] = []
        for chord in chords {
            events += segment(lead: tpq / 4, program: program, keys: chord, hold: 2 * tpq)
        }
        return events
    }

    /// Piano chord then bass note, same root, four times — a direct level A/B.
    private static func alternating() -> [Event] {
        var events: [Event] = []
        for _ in 0 ..< 4 {
            events += segment(lead: tpq / 4, program: 0, keys: [60, 64, 67], hold: 2 * tpq)
            events += segment(lead: tpq / 4, program: 33, keys: [36], hold: 2 * tpq)
        }
        return events
    }

    // MARK: SMF assembly

    private struct Event { let delta: Int; let bytes: [UInt8] }

    /// One musical gesture as a self-contained run of delta events: a program
    /// change (carrying `lead` ticks of rest before it), simultaneous note-ons,
    /// then note-offs after `hold` ticks. Concatenating segments needs no
    /// absolute-time sorting because every note in a segment starts and ends
    /// together.
    private static func segment(lead: Int, program: UInt8, keys: [Int], hold: Int) -> [Event] {
        var events: [Event] = [Event(delta: lead, bytes: [0xC0, program])]
        for key in keys {
            events.append(Event(delta: 0, bytes: [0x90, UInt8(key), velocity]))
        }
        for (i, key) in keys.enumerated() {
            events.append(Event(delta: i == 0 ? hold : 0, bytes: [0x80, UInt8(key), 0]))
        }
        return events
    }

    private static func smf(_ events: [Event]) -> Data {
        var track: [UInt8] = []
        for event in events {
            track += vlq(event.delta)
            track += event.bytes
        }
        track += vlq(0) + [0xFF, 0x2F, 0x00] // end of track

        var data: [UInt8] = []
        data += Array("MThd".utf8)
        data += be32(6)
        data += be16(0) // format 0
        data += be16(1) // one track
        data += be16(tpq)
        data += Array("MTrk".utf8)
        data += be32(track.count)
        data += track
        return Data(data)
    }

    private static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return bytes
    }

    private static func be16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
