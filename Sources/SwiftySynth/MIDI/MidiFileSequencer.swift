import Foundation

/// Plays a `MidiFile` through a `Synthesizer`, dispatching due messages at
/// the synthesizer's internal block boundaries.
///
/// Ported from `MidiFileSequencer.cs` (MeltySynth, MIT License — see
/// NOTICE). FAITHFUL (full-port spec §3, §5e): the block walk, the
/// `time <= currentTime` due-message drain, and the loop rewind decide
/// which events land on which sample — transliterated. The clock is f64
/// seconds with rustysynth's operation order (plan Global Constraints);
/// `Duration` appears only at the `position` boundary.
///
/// NOT thread-safe (as the reference documents): playback control
/// (`play`/`stop`/`speed`/`onSend`) and `render` must be serialized by the
/// caller. Real-time contract (spec §8): after `play()`, `render` and
/// everything it calls allocate nothing; set `onSend` once, before
/// rendering starts, and parse `MidiFile` off the render thread.
public final class MidiFileSequencer {
    /// The synthesizer this sequencer drives.
    public let synthesizer: Synthesizer

    private var speedValue = 1.0

    private var midiFile: MidiFile?
    private var loop = false

    private var blockWrote = 0

    private var currentTime = 0.0
    private var msgIndex = 0
    private var loopIndex = 0

    /// When set, called INSTEAD of `synthesizer.processMidiMessage` for
    /// every normal message: `(synthesizer, channel, command, data1,
    /// data2)`. Mirrors C#'s `OnSendMessage` hook semantics (the hook
    /// replaces dispatch; forward explicitly if you want both).
    public var onSend: ((Synthesizer, Int, Int, Int, Int) -> Void)?

    public init(synthesizer: Synthesizer) {
        self.synthesizer = synthesizer
    }

    /// Starts playing the MIDI file from the beginning. Mirrors
    /// `MidiFileSequencer.Play`: the block carry is primed so the first
    /// `render` call processes events at time zero, and the synthesizer is
    /// reset.
    public func play(_ midiFile: MidiFile, loop: Bool) {
        self.midiFile = midiFile
        self.loop = loop

        blockWrote = synthesizer.blockSize

        currentTime = 0
        msgIndex = 0
        loopIndex = 0

        synthesizer.reset()
    }

    /// Stops playing and resets the synthesizer.
    public func stop() {
        midiFile = nil
        synthesizer.reset()
    }

    /// Renders `left.count` (== `right.count`) frames, dispatching due MIDI
    /// messages at every internal block boundary. Mirrors
    /// `MidiFileSequencer.Render`: correct for any caller chunk size — the
    /// `blockWrote` carry keeps event placement independent of chunking.
    public func render(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        precondition(left.count == right.count)

        var wrote = 0
        while wrote < left.count {
            if blockWrote == synthesizer.blockSize {
                processEvents()
                blockWrote = 0
                currentTime += speedValue * Double(synthesizer.blockSize) / Double(synthesizer.sampleRate)
            }

            let srcRem = synthesizer.blockSize - blockWrote
            let dstRem = left.count - wrote
            let rem = min(srcRem, dstRem)

            synthesizer.render(
                left: UnsafeMutableBufferPointer(rebasing: left[wrote..<(wrote + rem)]),
                right: UnsafeMutableBufferPointer(rebasing: right[wrote..<(wrote + rem)]))

            blockWrote += rem
            wrote += rem
        }
    }

    /// Mirrors `MidiFileSequencer.ProcessEvents` exactly — including the
    /// shared `msgIndex += 1` that makes a loop rewind resume at
    /// `loopIndex + 1`, and the end-of-list rewind (no `+ 1`) below the
    /// while loop. Both rewind sites carry an added `loopIndex <
    /// times.count` guard with no C# equivalent: `Times[loopIndex]` on an
    /// empty array throws a catchable exception in C#, but Swift's Array
    /// subscript hard-traps — never-trap applies.
    private func processEvents() {
        guard let midiFile else { return }

        while msgIndex < midiFile.messages.count {
            let time = midiFile.times[msgIndex]
            let msg = midiFile.messages[msgIndex]
            if time <= currentTime {
                if msg.type == .normal {
                    if let onSend {
                        onSend(synthesizer, Int(msg.channel), Int(msg.command), Int(msg.data1), Int(msg.data2))
                    } else {
                        synthesizer.processMidiMessage(
                            channel: Int(msg.channel), command: Int(msg.command),
                            data1: Int(msg.data1), data2: Int(msg.data2))
                    }
                } else if loop {
                    if msg.type == .loopStart {
                        loopIndex = msgIndex
                    } else if msg.type == .loopEnd, loopIndex < midiFile.times.count {
                        // `loopIndex < times.count` is defense-in-depth: the
                        // parser now rejects `trackCount == 0` (the only way
                        // an empty `times` could reach here), but this keeps
                        // the rewind from Array-subscript-trapping on any
                        // other empty-`times` MidiFile — never-trap.
                        currentTime = midiFile.times[loopIndex]
                        msgIndex = loopIndex
                        synthesizer.noteOffAll(immediate: false)
                    }
                }
                msgIndex += 1
            } else {
                break
            }
        }

        if msgIndex == midiFile.messages.count && loop && loopIndex < midiFile.times.count {
            // Same defense-in-depth guard as above, for the end-of-list
            // rewind.
            currentTime = midiFile.times[loopIndex]
            msgIndex = loopIndex
            synthesizer.noteOffAll(immediate: false)
        }
    }

    /// The current playback position. `.zero` if `currentTime` is
    /// non-finite (defense in depth at the `Duration` boundary — mirrors
    /// the guard on `MidiFile.length`; `currentTime` is seeded from
    /// `midiFile.times`, so a non-finite value here would trace back to a
    /// non-finite time that should already have been rejected at parse).
    public var position: Duration {
        currentTime.isFinite ? .seconds(currentTime) : .zero
    }

    /// Whether playback has consumed every message (C# `EndOfSequence`):
    /// `true` before `play` and after `stop`; index-based, so release tails
    /// may still be sounding; never `true` while looping.
    public var isAtEnd: Bool {
        guard let midiFile else { return true }
        return msgIndex == midiFile.messages.count
    }

    /// The playback speed (tempo multiplier, default 1). Must be positive —
    /// this is API misuse, not file data, so it preconditions like C#'s
    /// ArgumentOutOfRangeException.
    public var speed: Double {
        get { speedValue }
        set {
            precondition(newValue > 0, "The playback speed must be a positive value.")
            speedValue = newValue
        }
    }
}
