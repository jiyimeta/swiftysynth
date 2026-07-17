import Foundation
import Testing
@testable import SwiftySynth

/// One dumped message (schema from `oracle dump-midi`, Task 2).
struct MidiDumpMessage: Decodable {
    let type: String
    let channel: Int?
    let command: Int?
    let data1: Int?
    let data2: Int?
    let time: Double
}

/// The dump-midi top level.
struct MidiDump: Decodable {
    let loopType: String
    let midiSha256: String
    let rustysynthVersion: String
    let length: Double
    let messageCount: Int
    let messages: [MidiDumpMessage]
}

/// **G-midi (structural)** — hermetic: committed .mid + committed dumps.
struct MidiFileStructuralTests {
    static func songData() throws -> Data {
        let url = try #require(Fixtures.url("midi-gm-song", "mid"))
        return try Data(contentsOf: url)
    }

    static func dump(_ name: String) throws -> MidiDump {
        let url = try #require(Fixtures.url(name, "json"))
        return try JSONDecoder().decode(MidiDump.self, from: Data(contentsOf: url))
    }

    /// Compares a Swift parse against a dump EXACTLY: count, per-message
    /// type/channel/command/data1/data2, and bit-exact f64 times.
    private func assertMatchesDump(_ midi: MidiFile, _ dump: MidiDump, songSha: String) {
        #expect(dump.midiSha256 == songSha, "the dump was generated from different .mid bytes")
        #expect(midi.messages.count == dump.messageCount)
        #expect(midi.messages.count == dump.messages.count)
        for (i, expected) in dump.messages.enumerated() {
            let msg = midi.messages[i]
            switch expected.type {
            case "normal":
                #expect(msg.type == .normal, "index \(i): expected normal, got \(msg.type)")
                #expect(Int(msg.channel) == expected.channel, "index \(i) channel")
                #expect(Int(msg.command) == expected.command, "index \(i) command")
                #expect(Int(msg.data1) == expected.data1, "index \(i) data1")
                #expect(Int(msg.data2) == expected.data2, "index \(i) data2")
            case "loopStart":
                #expect(msg.type == .loopStart, "index \(i)")
            case "loopEnd":
                #expect(msg.type == .loopEnd, "index \(i)")
            case "endOfTrack":
                #expect(msg.type == .endOfTrack, "index \(i)")
            default:
                Issue.record("index \(i): unknown dump type '\(expected.type)'")
            }
            // EXACT — bit-identical f64 merge arithmetic (plan Global
            // Constraints). Do not add a tolerance here: any inequality is
            // a real arithmetic divergence.
            #expect(midi.times[i] == expected.time,
                    "index \(i): time \(midi.times[i]) != oracle \(expected.time)")
        }
        #expect(midi.times.last == dump.length)
    }

    @Test func parseMatchesOracleDumpLoopTypeNone() throws {
        let data = try Self.songData()
        let midi = try MidiFile(data: data)
        try assertMatchesDump(midi, Self.dump("midi-gm-dump-none"), songSha: sha256Hex(data))
    }

    @Test func parseMatchesOracleDumpLoopTypeFinalFantasy() throws {
        let data = try Self.songData()
        let midi = try MidiFile(data: data, loopType: .finalFantasy)
        let dump = try Self.dump("midi-gm-dump-ff")
        assertMatchesDump(midi, dump, songSha: sha256Hex(data))
        // The FF markers land at the hand-known indices.
        #expect(midi.messages[17].type == .loopStart)
        #expect(midi.messages[33].type == .loopEnd)
    }

    /// The hand-derived expectation — independent of the oracle. Rows are
    /// (type, channel, command, data1, data2, tick), transcribed from
    /// make_midi's event tables (Tools/oracle/src/main.rs, Task 2; ties at
    /// equal ticks keep track order 0,1,2,3). channel/command/data are -1
    /// on non-normal rows (not applicable). Ticks → seconds via the
    /// closed-form tempo map: 120 bpm to tick 1920, 150 bpm after.
    static let expectedRows: [(type: MidiFile.MessageType, channel: Int, command: Int, data1: Int, data2: Int, tick: Int)] = [
        (.normal, 0, 0xC0, 0, 0, 0),        //  0 ch0 program 0
        (.normal, 0, 0x90, 60, 100, 0),     //  1 piano chord
        (.normal, 0, 0x90, 64, 96, 0),      //  2
        (.normal, 1, 0xC0, 48, 0, 0),       //  3 ch1 program 48
        (.normal, 1, 0xB0, 7, 100, 0),      //  4 volume
        (.normal, 1, 0xB0, 10, 30, 0),      //  5 pan
        (.normal, 1, 0xB0, 101, 0, 0),      //  6 RPN coarse
        (.normal, 1, 0xB0, 100, 0, 0),      //  7 RPN fine
        (.normal, 1, 0xB0, 6, 4, 0),        //  8 data entry (bend range 4)
        (.normal, 9, 0x90, 36, 127, 0),     //  9 kick
        (.normal, 9, 0x90, 36, 0, 240),     // 10
        (.normal, 1, 0x90, 55, 90, 480),    // 11 strings on (held past loop end)
        (.normal, 9, 0x90, 42, 100, 480),   // 12 hi-hat
        (.normal, 9, 0x90, 42, 0, 720),     // 13
        (.normal, 0, 0x90, 60, 0, 900),     // 14 vel-0 offs via running status
        (.normal, 0, 0x90, 64, 0, 900),     // 15
        (.normal, 0, 0x90, 67, 96, 960),    // 16
        (.normal, 9, 0xB0, 116, 0, 960),    // 17 CC116 → LoopStart under FF
        (.normal, 9, 0x90, 38, 110, 960),   // 18 snare
        (.normal, 9, 0x90, 38, 0, 1200),    // 19
        (.normal, 1, 0xE0, 0, 80, 1440),    // 20 bend up
        (.normal, 0, 0x90, 67, 0, 1880),    // 21
        (.normal, 0, 0x90, 72, 100, 1920),  // 22 on the tempo change
        (.normal, 9, 0x90, 36, 127, 1920),  // 23
        (.normal, 9, 0x90, 36, 0, 2160),    // 24
        (.normal, 1, 0xE0, 0, 64, 2400),    // 25 bend center
        (.normal, 0, 0x90, 72, 0, 2880),    // 26
        (.normal, 9, 0x90, 38, 110, 2880),  // 27
        (.normal, 9, 0x90, 38, 0, 3120),    // 28
        (.normal, 0, 0x90, 65, 90, 3360),   // 29
        (.normal, 0, 0x90, 65, 0, 4320),    // 30
        (.endOfTrack, -1, -1, -1, -1, 4320),// 31 track 1 EOT
        (.endOfTrack, -1, -1, -1, -1, 4800),// 32 track 0 EOT
        (.normal, 9, 0xB0, 117, 0, 4800),   // 33 CC117 → LoopEnd under FF
        (.endOfTrack, -1, -1, -1, -1, 4800),// 34 track 3 EOT
        (.normal, 1, 0x80, 55, 0, 5040),    // 35 strings off — AFTER the loop end
        (.endOfTrack, -1, -1, -1, -1, 5040),// 36 track 2 EOT
    ]

    /// Closed-form tempo map (independent recomputation, not the merge loop).
    private static func closedFormSeconds(tick: Int) -> Double {
        if tick <= 1920 {
            return Double(tick) / 960.0
        }
        return 2.0 + Double(tick - 1920) / 1200.0
    }

    @Test func parseMatchesHandDerivedTable() throws {
        let midi = try MidiFile(data: Self.songData())
        #expect(midi.messages.count == Self.expectedRows.count)
        for (i, row) in Self.expectedRows.enumerated() {
            let msg = midi.messages[i]
            #expect(msg.type == row.type, "index \(i)")
            if row.type == .normal {
                #expect(Int(msg.channel) == row.channel, "index \(i) channel")
                #expect(Int(msg.command) == row.command, "index \(i) command")
                #expect(Int(msg.data1) == row.data1, "index \(i) data1")
                #expect(Int(msg.data2) == row.data2, "index \(i) data2")
            }
            let expected = Self.closedFormSeconds(tick: row.tick)
            #expect(abs(midi.times[i] - expected) < 1e-9,
                    "index \(i): time \(midi.times[i]) vs closed-form \(expected)")
        }
        #expect(abs(midi.length.seconds - 4.6) < 1e-9)
    }
}
