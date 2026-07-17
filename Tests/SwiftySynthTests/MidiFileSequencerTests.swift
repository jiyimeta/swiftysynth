import Foundation
import Testing
@testable import SwiftySynth

/// Renders `range` of the sequencer's output into the matching slice of
/// `left`/`right` — the sequencer counterpart of `renderInto` (Tasks 7/8
/// reuse this).
func seqRenderInto(_ sequencer: MidiFileSequencer, _ left: inout [Float], _ right: inout [Float], _ range: Range<Int>) {
    left.withUnsafeMutableBufferPointer { lp in
        right.withUnsafeMutableBufferPointer { rp in
            sequencer.render(
                left: UnsafeMutableBufferPointer(rebasing: lp[range]),
                right: UnsafeMutableBufferPointer(rebasing: rp[range]))
        }
    }
}

/// Captures onSend dispatches with the caller-maintained frame position.
private final class DispatchRecorder {
    var currentFrame = 0
    var dispatches: [(frame: Int, channel: Int, command: Int, data1: Int, data2: Int)] = []
}

/// Hermetic sequencer-behavior tests over the synthetic font (loop-enabled
/// sample so voices sustain) and synthetic SMF bytes. Frame math, all with
/// blockSize 64 @ 44.1 kHz (q = 64/44100 s) and resolution 480 at the
/// default 120 bpm (tick 480 = 0.5 s):
///   an event at time T dispatches at the first block start whose clock is
///   ≥ T, i.e. block n = ceil(T/q) … frame 64·n.
///   T=0.5 → n=345 (344·q=0.49924 < 0.5 ≤ 345·q=0.50068) → frame 22080
///   T=1.0 → n=690 → frame 44160
///   T=0.5 at speed 2 → n=173 → frame 11072
struct MidiFileSequencerTests {
    private static func makeSynthesizer() throws -> Synthesizer {
        let font = try SoundFont(data: SyntheticSF2.minimal(instrumentGenerators: [(54, 1), (53, 0)]))
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 16, enableReverbAndChorus: false)
        return try Synthesizer(soundFont: font, settings: settings)
    }

    /// noteOns at t = 0, 0.5, 1.0 s; EOT at 1.0 s.
    private static func threeNoteSong() throws -> MidiFile {
        try MidiFile(data: SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
            (0, [0x90, 60, 100]),
            (480, [0x90, 62, 100]),
            (480, [0x90, 64, 100]),
            (0, SyntheticSMF.endOfTrack),
        ]]))
    }

    /// FF loop: LoopStart at t=0 (before the note), LoopEnd + EOT at t=1.0.
    private static func loopedSong() throws -> MidiFile {
        try MidiFile(
            data: SyntheticSMF.file(format: 0, resolution: 480, tracks: [[
                (0, [0xB0, 116, 0]),
                (0, [0x90, 60, 100]),
                (960, [0xB0, 117, 0]),
                (0, SyntheticSMF.endOfTrack),
            ]]),
            loopType: .finalFantasy)
    }

    @Test func isAtEndLifecycle() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        #expect(sequencer.isAtEnd, "true before play (C# EndOfSequence contract)")

        sequencer.play(try Self.threeNoteSong(), loop: false)
        #expect(!sequencer.isAtEnd)

        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for _ in 0..<700 {
            seqRenderInto(sequencer, &left, &right, 0..<64)
        }
        #expect(sequencer.isAtEnd, "all messages (incl. the EOT) drained by 700 blocks")

        sequencer.stop()
        #expect(sequencer.isAtEnd)
        #expect(sequencer.synthesizer.activeVoiceCount == 0, "stop() resets the synthesizer")
    }

    @Test func dispatchLandsOnExactBlockBoundaries() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        let recorder = DispatchRecorder()
        sequencer.onSend = { _, channel, command, data1, data2 in
            recorder.dispatches.append((recorder.currentFrame, channel, command, data1, data2))
        }
        sequencer.play(try Self.threeNoteSong(), loop: false)

        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for block in 0..<700 {
            recorder.currentFrame = block * 64
            seqRenderInto(sequencer, &left, &right, 0..<64)
        }

        #expect(recorder.dispatches.map(\.frame) == [0, 22_080, 44_160])
        #expect(recorder.dispatches.map(\.data1) == [60, 62, 64])
        // The hook REPLACES synthesizer dispatch (C# semantics): nothing
        // reached the synth, so no voices ever started.
        #expect(sequencer.synthesizer.activeVoiceCount == 0)
    }

    @Test func hookNilDispatchesToSynthesizer() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        sequencer.play(try Self.threeNoteSong(), loop: false)
        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        seqRenderInto(sequencer, &left, &right, 0..<64)
        #expect(sequencer.synthesizer.activeVoiceCount == 1, "the t=0 noteOn reached the synthesizer")
    }

    @Test func speedScalesTheClock() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        let recorder = DispatchRecorder()
        sequencer.onSend = { _, _, _, data1, _ in
            recorder.dispatches.append((recorder.currentFrame, 0, 0, data1, 0))
        }
        sequencer.speed = 2.0
        sequencer.play(try Self.threeNoteSong(), loop: false)

        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for block in 0..<400 {
            recorder.currentFrame = block * 64
            seqRenderInto(sequencer, &left, &right, 0..<64)
        }
        #expect(recorder.dispatches.map(\.frame) == [0, 11_072, 22_080])
    }

    @Test func loopRewindsAndRedispatches() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        let recorder = DispatchRecorder()
        sequencer.onSend = { _, _, command, data1, _ in
            recorder.dispatches.append((recorder.currentFrame, 0, command, data1, 0))
        }
        sequencer.play(try Self.loopedSong(), loop: true)

        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for block in 0..<1_420 {
            recorder.currentFrame = block * 64
            seqRenderInto(sequencer, &left, &right, 0..<64)
        }

        // The rewind at block 690 resumes at loopIndex + 1 — the noteOn —
        // with the clock reset to the LoopStart time (0.0), so the note
        // re-dispatches every 690 blocks, in the same render call that hit
        // the LoopEnd.
        #expect(recorder.dispatches.map(\.frame) == [0, 44_160, 88_320])
        #expect(!sequencer.isAtEnd, "never at end while looping")
        // 1420 blocks - the second rewind at block 1380 → clock ≈ 40·q.
        #expect(sequencer.position.seconds < 1.0, "position rewound to the loop region")
    }

    @Test func positionTracksTheBlockClock() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        sequencer.play(try Self.threeNoteSong(), loop: false)
        #expect(sequencer.position == .zero)

        var left = [Float](repeating: 0, count: 640)
        var right = [Float](repeating: 0, count: 640)
        seqRenderInto(sequencer, &left, &right, 0..<640)
        // 10 blocks of 64 → 10·q; tolerance because Duration round-trips
        // through attoseconds and the clock accumulates ten adds.
        #expect(abs(sequencer.position.seconds - 10.0 * 64.0 / 44_100.0) < 1e-12)
    }

    @Test func replayResetsTheClockAndIndices() throws {
        let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
        let recorder = DispatchRecorder()
        sequencer.onSend = { _, _, _, data1, _ in
            recorder.dispatches.append((recorder.currentFrame, 0, 0, data1, 0))
        }
        let song = try Self.threeNoteSong()
        sequencer.play(song, loop: false)
        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        for block in 0..<400 {
            recorder.currentFrame = block * 64
            seqRenderInto(sequencer, &left, &right, 0..<64)
        }
        let firstRun = recorder.dispatches.count

        sequencer.play(song, loop: false)   // restart mid-way through nothing new
        recorder.currentFrame = -1          // sentinel: the next dispatch is the restarted t=0 note
        seqRenderInto(sequencer, &left, &right, 0..<64)
        #expect(recorder.dispatches.count == firstRun + 1)
        #expect(recorder.dispatches.last!.frame == -1)
        #expect(recorder.dispatches.last!.data1 == 60)
        #expect(sequencer.position.seconds < 0.01)
    }

    /// Odd caller chunk sizes cannot move events: the sequencer owns the
    /// internal block walk (blockWrote carry). 997-frame chunks vs 64-frame
    /// chunks produce identical dispatch frames.
    @Test func callerChunkingDoesNotMoveEvents() throws {
        func dispatchFrames(chunk: Int) throws -> [Int] {
            let sequencer = MidiFileSequencer(synthesizer: try Self.makeSynthesizer())
            let recorder = DispatchRecorder()
            sequencer.onSend = { _, _, _, _, _ in
                recorder.dispatches.append((recorder.currentFrame, 0, 0, 0, 0))
            }
            sequencer.play(try Self.threeNoteSong(), loop: false)
            let total = 46_080   // 720 blocks
            var left = [Float](repeating: 0, count: total)
            var right = [Float](repeating: 0, count: total)
            var position = 0
            while position < total {
                let n = min(chunk, total - position)
                recorder.currentFrame = position
                seqRenderInto(sequencer, &left, &right, position..<(position + n))
                position += n
            }
            return recorder.dispatches.map(\.frame)
        }
        // With 997-frame chunks the recorded frame is the chunk START —
        // the block boundary the event actually fired on lies inside the
        // chunk — so compare against the hand-derived boundaries rounded
        // DOWN to the chunk grid the event falls in.
        let fine = try dispatchFrames(chunk: 64)
        #expect(fine == [0, 22_080, 44_160])
        let coarse = try dispatchFrames(chunk: 997)
        #expect(coarse == [0, 22_080 / 997 * 997, 44_160 / 997 * 997])
    }
}
