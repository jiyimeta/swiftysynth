import Foundation
import Testing
@testable import SwiftySynth

/// Builds synthetic SMF byte blobs for the MidiFile parser tests —
/// the MIDI analogue of SyntheticSF2. Events are (delta, bytes) pairs;
/// omitting the status byte in `bytes` produces running status.
enum SyntheticSMF {
    static func file(format: UInt16, resolution: UInt16, tracks: [[(delta: UInt32, bytes: [UInt8])]]) -> Data {
        var out = ByteWriter()
        out.fourCC("MThd")
        out.u32be(6)
        out.u16be(format)
        out.u16be(UInt16(tracks.count))
        out.u16be(resolution)
        for events in tracks {
            var body = ByteWriter()
            for event in events {
                body.vlq(event.delta)
                body.bytes(event.bytes)
            }
            out.fourCC("MTrk")
            out.u32be(UInt32(body.data.count))
            out.append(body)
        }
        return out.data
    }

    static let endOfTrack: [UInt8] = [0xFF, 0x2F, 0x00]
}

/// Hermetic parser-semantics tests over synthetic SMF bytes. The committed
/// reference song's oracle equivalence is MidiFileStructuralTests' job —
/// these pin the decode rules and the throw-not-trap invariant in isolation.
struct MidiFileTests {
    // MARK: Well-formed decode

    @Test func formatZeroSingleTrackParses() throws {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0x90, 0x3C, 0x64]),
            (480, [0x80, 0x3C, 0x00]),
            (0, SyntheticSMF.endOfTrack),
        ]])
        let midi = try MidiFile(data: data)
        #expect(midi.messages.count == 3)
        #expect(midi.messages[0].type == .normal)
        #expect(midi.messages[0].command == 0x90)
        #expect(midi.messages[2].type == .endOfTrack)
        #expect(midi.times[0] == 0)
        // 480 ticks at the default 120 bpm, resolution 480 → 0.5 s
        // (tolerance: closed-form vs the accumulated f64 — exactness is
        // asserted only against the oracle dump, Task 5).
        #expect(abs(midi.times[1] - 0.5) < 1e-12)
        #expect(abs(midi.length.seconds - 0.5) < 1e-12)
    }

    @Test func runningStatusDecodesTwoAndOneByteCommands() throws {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0x90, 0x3C, 0x64]),
            (10, [0x40, 0x60]),        // running: noteOn 64 vel 96
            (10, [0x3C, 0x00]),        // running: vel-0 note-off, stored verbatim
            (0, [0xC0, 0x05]),         // program change (1 data byte)
            (10, [0x07]),              // running under 0xC0: program 7
            (0, SyntheticSMF.endOfTrack),
        ]])
        let midi = try MidiFile(data: data)
        #expect(midi.messages.count == 6)
        #expect(midi.messages[1] == .common(0x90, 0x40, 0x60, .none))
        // The parser does NOT rewrite vel-0 note-ons; the synthesizer's
        // noteOn handles velocity 0 as a note-off downstream.
        #expect(midi.messages[2] == .common(0x90, 0x3C, 0x00, .none))
        #expect(midi.messages[3] == .common(0xC0, 0x05))
        #expect(midi.messages[4] == .common(0xC0, 0x07))
    }

    @Test func sysExAndUnknownMetaAreDiscarded() throws {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7]),   // SysEx
            (0, [0xFF, 0x01, 0x03, 0x61, 0x62, 0x63]),          // text meta "abc"
            (0, [0xF7, 0x02, 0x00, 0x00]),                      // SysEx continuation
            (0, [0x90, 0x3C, 0x64]),
            (0, SyntheticSMF.endOfTrack),
        ]])
        let midi = try MidiFile(data: data)
        #expect(midi.messages.count == 2)   // the note + EOT only
        #expect(midi.messages[0].command == 0x90)
    }

    @Test func eventsAfterEndOfTrackAreIgnored() throws {
        // Track 0 declares 4 junk bytes after its EOT; track 1 must still
        // parse — the reader skips to the declared chunk end.
        var out = ByteWriter()
        out.fourCC("MThd"); out.u32be(6); out.u16be(1); out.u16be(2); out.u16be(480)
        var track0 = ByteWriter()
        track0.vlq(0); track0.bytes([0x90, 0x3C, 0x64])
        track0.vlq(0); track0.bytes(SyntheticSMF.endOfTrack)
        track0.bytes([0x00, 0xFF, 0x01, 0x00])                  // junk after EOT
        out.fourCC("MTrk"); out.u32be(UInt32(track0.data.count)); out.append(track0)
        var track1 = ByteWriter()
        track1.vlq(0); track1.bytes([0x91, 0x40, 0x50])
        track1.vlq(0); track1.bytes(SyntheticSMF.endOfTrack)
        out.fourCC("MTrk"); out.u32be(UInt32(track1.data.count)); out.append(track1)

        let midi = try MidiFile(data: out.data)
        #expect(midi.messages.count == 4)   // 2 notes + 2 EOTs
        #expect(midi.messages.contains(.common(0x91, 0x40, 0x50, .none)))
    }

    @Test func tempoMapAppliesAcrossTracks() throws {
        // Conductor: 120 bpm default, 240 bpm (250000 µs/qn) from tick 480.
        // Note track: events at ticks 480 and 960.
        //   t(480)  = 480/960 = 0.5 s
        //   t(960)  = 0.5 + 480 · 60/(480·240) = 0.5 + 0.25 = 0.75 s
        let data = SyntheticSMF.file(format: 1, resolution: 480, tracks: [
            [
                (480, [0xFF, 0x51, 0x03, 0x03, 0xD0, 0x90]),    // 250000 µs/qn
                (480, SyntheticSMF.endOfTrack),                 // EOT @ 960
            ],
            [
                (480, [0x90, 0x3C, 0x64]),
                (480, [0x80, 0x3C, 0x00]),
                (0, SyntheticSMF.endOfTrack),
            ],
        ])
        let midi = try MidiFile(data: data)
        // Merged: noteOn@480, EOT(track0)@960, noteOff@960, EOT(track1)@960
        // (the tempo message is consumed by the merge).
        #expect(midi.messages.count == 4)
        #expect(abs(midi.times[0] - 0.5) < 1e-12)
        #expect(abs(midi.times[2] - 0.75) < 1e-12)
    }

    // MARK: Loop extensions

    /// CC110/111/116/117 under each loop type — the MidiFile.cs mapping:
    /// rpgMaker: 111→start; incredibleMachine: 110→start, 111→end;
    /// finalFantasy: 116→start, 117→end; none: all stay normal CCs.
    @Test(arguments: [
        (MidiFileLoopType.none,
         [MidiFile.MessageType.normal, .normal, .normal, .normal]),
        (MidiFileLoopType.rpgMaker,
         [MidiFile.MessageType.normal, .loopStart, .normal, .normal]),
        (MidiFileLoopType.incredibleMachine,
         [MidiFile.MessageType.loopStart, .loopEnd, .normal, .normal]),
        (MidiFileLoopType.finalFantasy,
         [MidiFile.MessageType.normal, .normal, .loopStart, .loopEnd]),
    ])
    func loopExtensionRecognition(loopType: MidiFileLoopType, expected: [MidiFile.MessageType]) throws {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0xB0, 110, 0]),
            (0, [0xB0, 111, 0]),
            (0, [0xB0, 116, 0]),
            (0, [0xB0, 117, 0]),
            (0, SyntheticSMF.endOfTrack),
        ]])
        let midi = try MidiFile(data: data, loopType: loopType)
        #expect(midi.messages.count == 5)
        #expect(Array(midi.messages[0..<4].map(\.type)) == expected)
    }

    @Test func loopPointInsertsALoopStartIntoTrackZero() throws {
        let tracks: [[(delta: UInt32, bytes: [UInt8])]] = [[
            (0, [0x90, 0x3C, 0x64]),
            (480, [0x80, 0x3C, 0x00]),
            (1440, SyntheticSMF.endOfTrack),                    // EOT @ 1920
        ]]
        // Loop point inside the track: inserted before the first tick ≥ 960.
        let inside = try MidiFile(data: SyntheticSMF.file(format: 0, resolution: 480, tracks: tracks), loopPoint: 960)
        #expect(inside.messages.map(\.type) == [.normal, .normal, .loopStart, .endOfTrack])
        #expect(abs(inside.times[2] - 1.0) < 1e-12)
        // Loop point past the end: appended.
        let past = try MidiFile(data: SyntheticSMF.file(format: 0, resolution: 480, tracks: tracks), loopPoint: 4800)
        #expect(past.messages.map(\.type) == [.normal, .normal, .endOfTrack, .loopStart])
        #expect(abs(past.times[3] - 5.0) < 1e-12)
        // Negative: throws (C# ArgumentException → SwiftySynthError).
        #expect(throws: SwiftySynthError.self) {
            _ = try MidiFile(data: SyntheticSMF.file(format: 0, resolution: 480, tracks: tracks), loopPoint: -1)
        }
    }

    // MARK: Malformed input — throw, never trap

    @Test func nonMThdHeaderThrows() {
        var out = ByteWriter()
        out.fourCC("RIFF"); out.u32be(6)
        #expect(throws: SwiftySynthError.self) { _ = try MidiFile(data: out.data) }
    }

    @Test func wrongHeaderSizeThrows() {
        var out = ByteWriter()
        out.fourCC("MThd"); out.u32be(7); out.u16be(0); out.u16be(1); out.u16be(480)
        #expect(throws: SwiftySynthError.self) { _ = try MidiFile(data: out.data) }
    }

    /// SMF format 2 (multi-song) is OUT OF SCOPE (spec §2) — documented,
    /// not implemented: the loader rejects it with the C# message.
    @Test func formatTwoIsRejected() {
        let data = SyntheticSMF.file(format: 2, resolution: 480, tracks: [[
            (0, SyntheticSMF.endOfTrack),
        ]])
        do {
            _ = try MidiFile(data: data)
            Issue.record("format 2 must be rejected")
        } catch let error as SwiftySynthError {
            #expect(error.description == "The format 2 is not supported.")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func nonMTrkChunkThrows() {
        var out = ByteWriter()
        out.fourCC("MThd"); out.u32be(6); out.u16be(0); out.u16be(1); out.u16be(480)
        out.fourCC("Mtrk"); out.u32be(0)   // wrong case
        #expect(throws: SwiftySynthError.self) { _ = try MidiFile(data: out.data) }
    }

    @Test func truncatedTrackThrows() {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0x90, 0x3C]),   // note-on missing its velocity byte, no EOT
        ]])
        #expect(throws: SwiftySynthError.self) { _ = try MidiFile(data: data) }
    }

    @Test func tempoMetaWithWrongSizeThrows() {
        let data = SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0xFF, 0x51, 0x02, 0x07, 0xA1]),   // declared size 2, not 3
            (0, SyntheticSMF.endOfTrack),
        ]])
        do {
            _ = try MidiFile(data: data)
            Issue.record("a tempo meta with size != 3 must be rejected")
        } catch let error as SwiftySynthError {
            #expect(error.description == "Failed to read the tempo value.")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func emptyDataThrows() {
        #expect(throws: SwiftySynthError.self) { _ = try MidiFile(data: Data()) }
    }

    // MARK: Degenerate headers — never trap (Swift-specific f64→Duration/array boundary)

    /// A header-valid `MThd` (size 6, format 0/1) with division field
    /// `0x0000` passes every OTHER parse guard: `mergeTracks`'s
    /// `60.0 / (Double(resolution) * tempo) * deltaTick` becomes `Inf`/`NaN`
    /// for `resolution == 0`, filling `times` with non-finite values that
    /// later hard-trap `Duration.seconds(...)` in `MidiFile.length`. This
    /// must be rejected at parse instead. Discriminates: with the
    /// `resolution != 0` guard removed, this file parses successfully (no
    /// throw) and `midi.length` fatalErrors instead of failing the
    /// assertion — verified by temporarily removing the guard and observing
    /// the process crash.
    @Test func resolutionZeroThrows() {
        let data = SyntheticSMF.file(format: 0, resolution: 0, tracks: [[
            (0, [0x90, 0x3C, 0x64]),
            (480, [0x80, 0x3C, 0x00]),
            (0, SyntheticSMF.endOfTrack),
        ]])
        do {
            _ = try MidiFile(data: data)
            Issue.record("resolution == 0 must be rejected — it drives mergeTracks to divide by zero")
        } catch let error as SwiftySynthError {
            guard case .invalidMidiFile = error else {
                Issue.record("expected .invalidMidiFile, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// A NEGATIVE resolution (SMPTE time division: the division field's
    /// high bit set) must NOT be rejected — the port keeps SMPTE division
    /// as "parsed as a plain resolution, garbage-in-garbage-out, no trap"
    /// (unlike `resolution == 0`, a negative resolution yields a finite
    /// — negative — seconds-per-tick, so `Duration.seconds` never sees a
    /// non-finite value). `0x8050` as big-endian `Int16` is `-32688`.
    /// Discriminates against a too-broad fix (e.g. `resolution > 0`): that
    /// would throw here where the reference — and this file's contract —
    /// requires a successful, non-trapping parse.
    @Test func negativeResolutionSMPTEStillParsesWithoutTrapping() throws {
        let data = SyntheticSMF.file(format: 0, resolution: 0x8050, tracks: [[
            (0, [0x90, 0x3C, 0x64]),
            (480, [0x80, 0x3C, 0x00]),
            (0, SyntheticSMF.endOfTrack),
        ]])
        let midi = try MidiFile(data: data)
        #expect(midi.times.allSatisfy { $0.isFinite })
        let length = midi.length   // must not trap
        #expect(length.seconds.isFinite)
    }

    /// A well-formed `MThd` declaring `ntrks == 0` (format 0 or 1, any
    /// resolution) parses to an EMPTY `messages`/`times` — `mergeTracks`'s
    /// outer loop never has a track to pull from. Feeding that into
    /// `MidiFileSequencer.play(loop: true)` + `render` hits
    /// `msgIndex == messages.count && loop` (`0 == 0 && true`) on the very
    /// first call, rewinding to `times[loopIndex]` on an empty array —
    /// Swift's Array subscript hard-traps where C#'s indexer would throw a
    /// catchable exception. Rejecting `trackCount == 0` at parse (the
    /// faithful primary fix) closes the only reachable path to that empty
    /// state; `MidiFileSequencer`'s own `loopIndex < times.count` guards
    /// are defense-in-depth for any other route to an empty-`times` file.
    /// Discriminates: with the `trackCount > 0` guard removed, this parses
    /// successfully instead of throwing.
    @Test func trackCountZeroThrows() {
        var out = ByteWriter()
        out.fourCC("MThd"); out.u32be(6); out.u16be(0); out.u16be(0); out.u16be(480)
        do {
            _ = try MidiFile(data: out.data)
            Issue.record("trackCount == 0 must be rejected — it yields an empty MidiFile that later traps the sequencer's loop rewind")
        } catch let error as SwiftySynthError {
            guard case .invalidMidiFile = error else {
                Issue.record("expected .invalidMidiFile, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

extension Duration {
    /// Seconds as Double, for test tolerances only.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
