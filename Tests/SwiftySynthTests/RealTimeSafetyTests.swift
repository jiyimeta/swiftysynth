import Darwin
import Foundation
import Testing
@testable import SwiftySynth

#if os(macOS)
import AVFoundation

/// A raw MIDI event scheduled at an absolute frame — dispatched INSIDE the
/// render block through the faithful `processMidiMessage` path, exactly as
/// the P3 sequencer will drive the synthesizer.
struct RTMidiEvent {
    let frame: Int64
    let channel: Int
    let command: Int
    let data1: Int
    let data2: Int
}

/// Single-owner state handed to the audio render thread. `@unchecked Sendable` is sound
/// here because after `engine.start()` only the render thread touches the mutable fields,
/// and the test thread reads them only after `engine.stop()` (happens-before via stop).
final class RenderHarness: @unchecked Sendable {
    let synthesizer: Synthesizer
    let events: [RTMidiEvent]
    var eventIndex = 0
    var framesRendered: Int64 = 0

    init(synthesizer: Synthesizer, events: [RTMidiEvent]) {
        self.synthesizer = synthesizer
        self.events = events
    }
}

enum RenderBlockFactory {
    /// MUST stay `nonisolated static`. A render block formed inside a @MainActor context
    /// inherits MainActor isolation and traps EXC_BREAKPOINT on the audio thread under the
    /// Swift concurrency runtime — and OFFLINE rendering does not reproduce the trap,
    /// which is why this test uses a live AVAudioSourceNode (spec §8).
    nonisolated static func makeSourceNode(harness: RenderHarness) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard abl.count >= 2,
                  let rawLeft = abl[0].mData,
                  let rawRight = abl[1].mData else {
                return kAudioUnitErr_InvalidParameter
            }
            let left = UnsafeMutableBufferPointer(
                start: rawLeft.assumingMemoryBound(to: Float.self), count: frames)
            let right = UnsafeMutableBufferPointer(
                start: rawRight.assumingMemoryBound(to: Float.self), count: frames)

            // Events are driven INSIDE the render block by comparing a running
            // frame counter against preplanned event frames (spike model),
            // now through the raw multichannel dispatch.
            while harness.eventIndex < harness.events.count,
                  harness.events[harness.eventIndex].frame <= harness.framesRendered {
                let event = harness.events[harness.eventIndex]
                harness.synthesizer.processMidiMessage(
                    channel: event.channel, command: event.command,
                    data1: event.data1, data2: event.data2)
                harness.eventIndex += 1
            }

            harness.synthesizer.render(left: left, right: right)
            harness.framesRendered += Int64(frames)
            return noErr
        }
    }
}

/// Single-owner sequencer state handed to the audio render thread — the
/// same @unchecked Sendable justification as RenderHarness: after
/// engine.start() only the render thread touches the mutable fields, and
/// the test thread reads them only after engine.stop().
final class SequencerRenderHarness: @unchecked Sendable {
    let sequencer: MidiFileSequencer
    var framesRendered: Int64 = 0

    init(sequencer: MidiFileSequencer) {
        self.sequencer = sequencer
    }
}

extension RenderBlockFactory {
    /// Same `nonisolated static` rule as makeSourceNode: a render block
    /// formed in a @MainActor context traps EXC_BREAKPOINT on the audio
    /// thread. The sequencer is fully primed (MidiFile parsed, play()
    /// called) BEFORE the engine starts — the callback only renders.
    nonisolated static func makeSequencerSourceNode(harness: SequencerRenderHarness) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard abl.count >= 2,
                  let rawLeft = abl[0].mData,
                  let rawRight = abl[1].mData else {
                return kAudioUnitErr_InvalidParameter
            }
            let left = UnsafeMutableBufferPointer(
                start: rawLeft.assumingMemoryBound(to: Float.self), count: frames)
            let right = UnsafeMutableBufferPointer(
                start: rawRight.assumingMemoryBound(to: Float.self), count: frames)

            harness.sequencer.render(left: left, right: right)
            harness.framesRendered += Int64(frames)
            return noErr
        }
    }
}
#endif

/// The measured-window stop condition for the zero-alloc RT witnesses.
///
/// Non-strict (the default parallel run): any non-positive window is a
/// sufficient clean witness — a genuine render-path allocation shows up as a
/// reproducible positive floor in EVERY window, so one non-positive window
/// disproves it.
///
/// Strict (the isolated `SWIFTYSYNTH_RT_STRICT=1` run): only an EXACT 0/0
/// window is the authoritative proof. A net-negative window (external frees
/// settling inside the measured span) is non-positive but NOT exact-zero, so
/// it must NOT stop the search — otherwise a single such first window ends
/// measurement with no exact-zero witness and the strict assertion flakes on
/// pure measurement noise (the render path having allocated nothing).
func rtZeroAllocWindowSatisfies(_ delta: (blocks: Int, size: Int), strict: Bool) -> Bool {
    if strict { return delta.blocks == 0 && delta.size == 0 }
    return delta.blocks <= 0 && delta.size <= 0
}

@Suite(.serialized)
struct RealTimeSafetyTests {
    #if os(macOS)
    /// **G3′/G3-fx (no-trap)** — ≥5 s of live multichannel rendering on a
    /// real AVAudioSourceNode render thread PER PARAMETER CASE (dry, then
    /// effects-on), every event dispatched through processMidiMessage inside
    /// the callback; surviving to the assertions == zero traps. The two
    /// cases differ ONLY in `enableReverbAndChorus` — the event list
    /// (including the send CCs, inert channel state when dry) is shared.
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
          arguments: [false, true])
    func noTrapOnRenderThread(effectsOn: Bool) throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: effectsOn)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        let harness = RenderHarness(
            synthesizer: synth,
            events: [
                RTMidiEvent(frame: 0, channel: 0, command: 0xC0, data1: 0, data2: 0),
                RTMidiEvent(frame: 0, channel: 0, command: 0xB0, data1: 0x5D, data2: 64),   // chorus send
                RTMidiEvent(frame: 0, channel: 1, command: 0xB0, data1: 0x5B, data2: 100),  // reverb send up
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 60, data2: 100),
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 64, data2: 96),
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 67, data2: 92),
                RTMidiEvent(frame: 22_050, channel: 9, command: 0x90, data1: 36, data2: 127),
                RTMidiEvent(frame: 44_100, channel: 1, command: 0x90, data1: 55, data2: 90),
                RTMidiEvent(frame: 66_150, channel: 1, command: 0xE0, data1: 0, data2: 96),
                RTMidiEvent(frame: 88_200, channel: 0, command: 0x80, data1: 60, data2: 0),
                RTMidiEvent(frame: 88_200, channel: 0, command: 0xB0, data1: 0x07, data2: 80),
                RTMidiEvent(frame: 110_250, channel: 0, command: 0xB0, data1: 0x5D, data2: 127), // chorus ramp mid-note
                RTMidiEvent(frame: 132_300, channel: 0, command: 0x80, data1: 64, data2: 0),
                RTMidiEvent(frame: 132_300, channel: 0, command: 0x80, data1: 67, data2: 0),
                RTMidiEvent(frame: 154_350, channel: 1, command: 0x80, data1: 55, data2: 0),
                RTMidiEvent(frame: 176_400, channel: 0, command: 0xB0, data1: 0x7B, data2: 0),
            ])
        let node = RenderBlockFactory.makeSourceNode(harness: harness)

        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        engine.mainMixerNode.outputVolume = 0.0   // keep the test silent; the node is still pulled
        try engine.start()
        Thread.sleep(forTimeInterval: 5.5)
        engine.stop()

        #expect(harness.framesRendered >= Int64(5 * 44_100),
                "render thread ran for \(harness.framesRendered) frames; expected ≥ 5 s worth")
        #expect(harness.eventIndex == harness.events.count,
                "all preplanned events must have fired on the render thread")
    }

    /// **G3-seq (no-trap)** — ≥5 s of live SEQUENCER-DRIVEN rendering on a
    /// real AVAudioSourceNode render thread: the committed GM song, effects
    /// ON, FinalFantasy loop markers, loop ON (the ≈3.4 s loop period puts
    /// at least one rewind + noteOffAll inside the window). MidiFile parse
    /// and play() happen HERE, off-thread, before the engine starts
    /// (spec §8); the callback only calls sequencer.render. Surviving to
    /// the assertions == zero traps.
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
    func sequencerNoTrapOnRenderThread() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: true)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        let midURL = try #require(Fixtures.url("midi-gm-song", "mid"))
        let midi = try MidiFile(url: midURL, loopType: .finalFantasy)   // off-thread parse
        let sequencer = MidiFileSequencer(synthesizer: synth)
        sequencer.play(midi, loop: true)
        let harness = SequencerRenderHarness(sequencer: sequencer)
        let node = RenderBlockFactory.makeSequencerSourceNode(harness: harness)

        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        engine.mainMixerNode.outputVolume = 0.0   // keep the test silent; the node is still pulled
        try engine.start()
        Thread.sleep(forTimeInterval: 5.5)
        engine.stop()

        #expect(harness.framesRendered >= Int64(5 * 44_100),
                "render thread ran for \(harness.framesRendered) frames; expected ≥ 5 s worth")
        #expect(!harness.sequencer.isAtEnd, "looping playback must still be live after 5 s")
    }
    #endif

    /// **G3′/G3-fx (zero-alloc)** — after warm-up, a measured window of
    /// rendering (full-pool steal bursts + raw MIDI dispatch + note-offs —
    /// with the effects bus active in the effectsOn case) allocates nothing
    /// in the render path.
    ///
    /// RELIABILITY DESIGN (unchanged from P1 — see that plan's Task 11):
    /// `malloc_zone_statistics` reads the PROCESS-GLOBAL zone and Swift
    /// Testing runs suites concurrently, so cross-suite heap work lands in a
    /// sporadic SUBSET of windows as bounded noise, while a genuine
    /// render-path allocation recurs in EVERY window as a reproducible
    /// positive floor. PASS as soon as one short window nets non-positive;
    /// FAIL only when every window is positive. The authoritative proof is
    /// the exact-0/0 STRICT WITNESS in the isolated run
    /// (`SWIFTYSYNTH_RT_STRICT=1 swift test --filter
    /// RealTimeSafetyTests.zeroAllocationAfterWarmup`, which runs BOTH
    /// parameter cases — dry and effects-on).
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
          arguments: [false, true])
    func zeroAllocationAfterWarmup(effectsOn: Bool) throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: effectsOn)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        // Thorough warm-up so no lazy first-touch allocation survives into
        // the measured windows: activate the chorus send (nonzero chorus
        // input when the bus exists; inert channel state when dry), saturate
        // the pool, force a full 64-steal burst, run the dispatch paths.
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5D, data2: 64)
        for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) }
        for _ in 0..<200 { renderInto(synth, &left, &right, 0..<512) }
        for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 64 steals
        synth.processMidiMessage(channel: 0, command: 0xE0, data1: 0, data2: 80)
        for _ in 0..<200 { renderInto(synth, &left, &right, 0..<512) }

        // One short (~200-render) measured window: renders + a full-pool
        // steal burst + raw dispatch (incl. a reverb-send ramp through the
        // effects half) + note-offs, bracketed by a process-global
        // malloc-zone snapshot. NO print/log inside.
        func measureWindow() -> (blocks: Int, size: Int) {
            var before = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &before)
            for i in 0..<200 {
                if i == 0 { for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) } }   // full-pool steal
                if i == 50 { synth.processMidiMessage(channel: 0, command: 0xE0, data1: 0, data2: 80) }
                if i == 100 { synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x07, data2: 90) }
                if i == 125 { synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5B, data2: 100) }  // reverb-send ramp
                if i == 150 { for key in 22..<40 { synth.noteOff(key: key, on: 0) } }
                renderInto(synth, &left, &right, 0..<512)
            }
            var after = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &after)
            return (Int(after.blocks_in_use) - Int(before.blocks_in_use),
                    Int(after.size_in_use) - Int(before.size_in_use))
        }

        // In STRICT mode the authoritative witness is an EXACT 0/0 window, so
        // the search must not stop on a merely non-positive (e.g. net-freed)
        // window — otherwise a single externally-freed first window ends
        // measurement with no exact-zero witness and the strict assertion
        // flakes. In the default (non-strict) run, any non-positive window is
        // a sufficient clean witness and stops the search as before.
        let strict = ProcessInfo.processInfo.environment["SWIFTYSYNTH_RT_STRICT"] != nil
        var windows = [(blocks: Int, size: Int)]()
        for _ in 0..<8 {
            let delta = measureWindow()
            windows.append(delta)
            if rtZeroAllocWindowSatisfies(delta, strict: strict) {
                break   // strict: an exact 0/0 witness; non-strict: any non-positive window
            }
            // Drain: let this window's note-off frees and any pending external
            // frees settle OUTSIDE the next measured span.
            for _ in 0..<50 { renderInto(synth, &left, &right, 0..<512) }
        }

        let cleanWindow = windows.first { $0.blocks <= 0 && $0.size <= 0 }
        let exactZeroWitness = windows.contains { $0.blocks == 0 && $0.size == 0 }
        print("G3-alloc[effectsOn=\(effectsOn)] windows=\(windows) exactZeroWitness=\(exactZeroWitness)")

        // Fails only when EVERY window allocated — cross-suite noise contaminates
        // a sporadic subset (never all windows), but a real render-path
        // allocation makes all of them strictly positive. Do NOT widen this to
        // tolerate an all-positive result; that would gut the detection.
        #expect(cleanWindow != nil, """
            every one of \(windows.count) measured windows netted a positive \
            malloc-zone delta — the reproducible signature of a render-path \
            allocation (effectsOn=\(effectsOn)). windows=\(windows). Find the \
            allocation (spec §8: the render path — effects bus included — must \
            be alloc-free after warm-up); do not loosen the gate.
            """)

        // The default `swift test` run (parallel, multi-suite) uses the
        // noise-robust bounded-retry assertion above. The authoritative
        // exact-0/0 proof is gated behind an env var so it only runs isolated:
        //   SWIFTYSYNTH_RT_STRICT=1 swift test --filter RealTimeSafetyTests.zeroAllocationAfterWarmup
        if strict {
            #expect(exactZeroWitness, """
                STRICT mode: expected at least one measured window with an exact \
                0/0 malloc-zone delta (the authoritative zero-alloc proof,
                effectsOn=\(effectsOn)), but none of \(windows.count) windows \
                were exactly zero. windows=\(windows).
                """)
        }
    }

    /// **G3-seq (zero-alloc)** — after warm-up, sequencer-driven rendering
    /// of the committed GM song (effects ON, loop ON) allocates nothing:
    /// each ~3.48 s measured window exceeds the ≈3.4 s loop period, so
    /// every window contains at least one loop rewind (noteOffAll +
    /// re-dispatch) alongside processEvents → processMidiMessage traffic.
    /// Parameterized over the onSend hook: nil (direct dispatch) and a
    /// SET-ONCE forwarding closure (spec §8 — invoking a stored closure
    /// allocates nothing; the closure captures nothing per call).
    /// Same bounded-retry design as zeroAllocationAfterWarmup (P1 Task 11);
    /// the authoritative exact-0/0 proof is the isolated strict run:
    ///   SWIFTYSYNTH_RT_STRICT=1 swift test --filter RealTimeSafetyTests.sequencerZeroAllocationAfterWarmup
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
          arguments: [false, true])
    func sequencerZeroAllocationAfterWarmup(useOnSendHook: Bool) throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: true)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        let midURL = try #require(Fixtures.url("midi-gm-song", "mid"))
        let midi = try MidiFile(url: midURL, loopType: .finalFantasy)
        let sequencer = MidiFileSequencer(synthesizer: synth)
        if useOnSendHook {
            // Set ONCE, forwards everything, captures no per-call state.
            sequencer.onSend = { synthesizer, channel, command, data1, data2 in
                synthesizer.processMidiMessage(
                    channel: channel, command: command, data1: data1, data2: data2)
            }
        }
        sequencer.play(midi, loop: true)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        // Warm-up: ≥ 2 full loop passes (900 × 512 ≈ 10.4 s of song time)
        // so the first-touch of every dispatch path — incl. two rewinds —
        // is behind us.
        for _ in 0..<900 { seqRenderInto(sequencer, &left, &right, 0..<512) }

        // One ~300-render measured window (≈3.48 s > the 3.4 s loop
        // period → contains a rewind), bracketed by process-global
        // malloc-zone snapshots. NO print/log inside.
        func measureWindow() -> (blocks: Int, size: Int) {
            var before = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &before)
            for _ in 0..<300 {
                seqRenderInto(sequencer, &left, &right, 0..<512)
            }
            var after = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &after)
            return (Int(after.blocks_in_use) - Int(before.blocks_in_use),
                    Int(after.size_in_use) - Int(before.size_in_use))
        }

        // Strict mode needs an EXACT 0/0 witness; a net-freed window is
        // non-positive but not exact-zero, so it must not stop the strict
        // search (see rtZeroAllocWindowSatisfies) — the fix for the strict
        // sequencer-witness flake. Non-strict stops on any non-positive window.
        let strict = ProcessInfo.processInfo.environment["SWIFTYSYNTH_RT_STRICT"] != nil
        var windows = [(blocks: Int, size: Int)]()
        for _ in 0..<8 {
            let delta = measureWindow()
            windows.append(delta)
            if rtZeroAllocWindowSatisfies(delta, strict: strict) {
                break   // strict: an exact 0/0 witness; non-strict: any non-positive window
            }
            // Drain outside the next measured span.
            for _ in 0..<50 { seqRenderInto(sequencer, &left, &right, 0..<512) }
        }

        let cleanWindow = windows.first { $0.blocks <= 0 && $0.size <= 0 }
        let exactZeroWitness = windows.contains { $0.blocks == 0 && $0.size == 0 }
        print("G3-seq-alloc[onSend=\(useOnSendHook)] windows=\(windows) exactZeroWitness=\(exactZeroWitness)")

        #expect(cleanWindow != nil, """
            every one of \(windows.count) measured windows netted a positive \
            malloc-zone delta — the reproducible signature of a render-path \
            allocation in the sequencer path (onSend=\(useOnSendHook)). \
            windows=\(windows). Find the allocation (spec §8: processEvents, \
            the hook invocation, and the rewind noteOffAll must be \
            alloc-free); do not loosen the gate.
            """)

        if ProcessInfo.processInfo.environment["SWIFTYSYNTH_RT_STRICT"] != nil {
            #expect(exactZeroWitness, """
                STRICT mode: expected at least one measured window with an \
                exact 0/0 malloc-zone delta (the authoritative zero-alloc \
                proof, onSend=\(useOnSendHook)), but none of \
                \(windows.count) windows were exactly zero. windows=\(windows).
                """)
        }
    }

    /// Regression for the strict zero-alloc witness flake. A net-freed first
    /// window (`(-4, -8224)`, observed in an isolated strict run) is
    /// non-positive, so the non-strict search treats it as a clean witness —
    /// but it is NOT an exact-0/0 window, so the strict search must keep
    /// going. Before the fix the loop used the non-strict `<= 0` break
    /// unconditionally, so a net-freed first window ended the strict search
    /// with no exact-zero witness and the strict assertion failed on pure
    /// measurement noise (the render path having allocated nothing).
    @Test func strictZeroAllocWitnessKeepsSearchingPastANetFreedWindow() {
        // Net-freed window: a clean witness only in non-strict mode.
        #expect(rtZeroAllocWindowSatisfies((blocks: -4, size: -8224), strict: false))
        #expect(!rtZeroAllocWindowSatisfies((blocks: -4, size: -8224), strict: true))
        // Exact zero: the authoritative witness, valid in both modes.
        #expect(rtZeroAllocWindowSatisfies((blocks: 0, size: 0), strict: true))
        #expect(rtZeroAllocWindowSatisfies((blocks: 0, size: 0), strict: false))
        // A positive window is never a witness in either mode.
        #expect(!rtZeroAllocWindowSatisfies((blocks: 1, size: 16), strict: false))
        #expect(!rtZeroAllocWindowSatisfies((blocks: 1, size: 16), strict: true))
    }

    /// The 1- and 5-minute load averages and this host's active core count, or
    /// `nil` if `getloadavg` could not read a sample — in which case the
    /// load guard below does not block `cpuBudget`; an unreadable load
    /// average must not itself cause a skip.
    private static func hostLoadSample() -> (load1: Double, load5: Double, cores: Int)? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return (loads[0], loads[1], ProcessInfo.processInfo.activeProcessorCount)
    }

    /// `cpuBudget`'s host-load guard — the test measures WALL-CLOCK p99,
    /// which is only meaningful on a quiescent host: under shared-host
    /// contention (observed 1-min load average → 151, plus sustained 5-/15-min
    /// averages of ~25-28 on a shared box with 10 cores) the measured p99
    /// balloons for reasons entirely unrelated to the render path, producing a
    /// false failure. Trip whenever EITHER the 1- or 5-minute load average
    /// exceeds the active core count — the host is over-subscribed on a
    /// sustained basis, not merely a momentary 1-minute dip (the 1-minute
    /// average alone is too twitchy: it briefly dips below threshold while the
    /// machine is still contended, which let a false 74%/56% p99 slip through).
    /// Never used to loosen the 25%/50% thresholds themselves.
    private static func isHostTooLoadedForCPUBudget() -> Bool {
        guard let sample = hostLoadSample() else { return false }
        return max(sample.load1, sample.load5) > Double(sample.cores)
    }

    private static func hostLoadGuardSkipReason() -> Comment {
        let sample = hostLoadSample()
        let load1 = sample?.load1 ?? 0
        let load5 = sample?.load5 ?? 0
        let cores = sample?.cores ?? ProcessInfo.processInfo.activeProcessorCount
        return "host load average (1-min \(load1), 5-min \(load5)) exceeds \(cores) cores — wall-clock CPU budget is unmeasurable under sustained contention (not a code failure)"
    }

    /// **G3′/G3-fx (CPU)** — per-callback cost at 512-frame buffers
    /// (deadline 11.61 ms @ 44.1 kHz): p99 < 25% for 1 note; p99 < 50% for
    /// a saturated 256-voice pool. Same bars dry and effects-on (spec §7
    /// G3′ budgets the FULL scope — the effects bus must fit inside the P1
    /// envelope). Release builds only. Also SKIPPED (not failed) when the
    /// host is too loaded to produce a meaningful wall-clock measurement —
    /// see `isHostTooLoadedForCPUBudget`.
    @Test(
        .enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
        .enabled(if: TestEnv.isRelease, "CPU budget is measured in release builds (swift test -c release)"),
        .disabled(if: isHostTooLoadedForCPUBudget(), hostLoadGuardSkipReason()),
        arguments: [false, true]
    )
    func cpuBudget(effectsOn: Bool) throws {
        let deadlineNanos = 512.0 / 44_100.0 * 1e9   // ≈ 11_609_977 ns
        let font = try SoundFont(url: FixtureSF2.url)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        // --- 1 note, default-size pool --------------------------------------------------
        let settings1 = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: effectsOn)
        let synth1 = try Synthesizer(soundFont: font, settings: settings1)
        if effectsOn {
            synth1.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5D, data2: 64)  // chorus live
        }
        synth1.noteOn(key: 60, velocity: 100, on: 0)
        for _ in 0..<100 { renderInto(synth1, &left, &right, 0..<512) }   // warm-up
        var oneNoteSamples = [UInt64]()
        oneNoteSamples.reserveCapacity(1_000)
        for i in 0..<1_000 {
            if i % 100 == 0 { synth1.noteOn(key: 60, velocity: 100, on: 0) }   // keep voices live
            let t0 = mach_absolute_time()
            renderInto(synth1, &left, &right, 0..<512)
            oneNoteSamples.append(MachTime.toNanos(mach_absolute_time() - t0))
        }
        let p99OneNote = Double(percentile(0.99, of: oneNoteSamples))

        // --- saturated 256-voice pool: 64 distinct keys × 4 melodic channels ------------
        let settings256 = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 256, enableReverbAndChorus: effectsOn)
        let synth256 = try Synthesizer(soundFont: font, settings: settings256)
        if effectsOn {
            for channel in 0..<4 {
                synth256.processMidiMessage(channel: channel, command: 0xB0, data1: 0x5D, data2: 64)
            }
        }
        for channel in 0..<4 {
            for key in 22..<86 { synth256.noteOn(key: key, velocity: 100, on: channel) }
        }
        let saturatedVoices = synth256.activeVoiceCount
        #expect(saturatedVoices >= 192, "expected a saturated pool (≈256 voices), got \(saturatedVoices)")
        for _ in 0..<100 { renderInto(synth256, &left, &right, 0..<512) }  // warm-up
        var saturatedSamples = [UInt64]()
        saturatedSamples.reserveCapacity(1_000)
        for i in 0..<1_000 {
            if i % 200 == 0 {
                for channel in 0..<4 {
                    for key in 22..<86 { synth256.noteOn(key: key, velocity: 100, on: channel) }  // refill pool
                }
            }
            let t0 = mach_absolute_time()
            renderInto(synth256, &left, &right, 0..<512)
            saturatedSamples.append(MachTime.toNanos(mach_absolute_time() - t0))
        }
        let p99Saturated = Double(percentile(0.99, of: saturatedSamples))

        print("G3-cpu[effectsOn=\(effectsOn)]: deadline=\(deadlineNanos)ns  1-note p99=\(p99OneNote)ns (\(100 * p99OneNote / deadlineNanos)%)  256-voice p99=\(p99Saturated)ns (\(100 * p99Saturated / deadlineNanos)%)  voices=\(saturatedVoices)")

        #expect(p99OneNote < 0.25 * deadlineNanos,
                "1-note p99 \(p99OneNote) ns is ≥ 25% of the 11.6 ms deadline (effectsOn=\(effectsOn))")
        #expect(p99Saturated < 0.50 * deadlineNanos,
                "256-voice p99 \(p99Saturated) ns is ≥ 50% of the 11.6 ms deadline (effectsOn=\(effectsOn))")
    }

    /// **G3-seq (CPU)** — per-callback cost of the SEQUENCER-DRIVEN path at
    /// 512-frame buffers (deadline 11.61 ms @ 44.1 kHz): the committed GM
    /// song is a light, 1-note-class load (a handful of simultaneous
    /// voices), so it is held to the 25% bar. processEvents scanning +
    /// dispatch ride on top of the synth cost measured by cpuBudget.
    /// Release builds; host-load-guarded like cpuBudget.
    @Test(
        .enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
        .enabled(if: TestEnv.isRelease, "CPU budget is measured in release builds (swift test -c release)"),
        .disabled(if: isHostTooLoadedForCPUBudget(), hostLoadGuardSkipReason())
    )
    func sequencerCpuBudget() throws {
        let deadlineNanos = 512.0 / 44_100.0 * 1e9   // ≈ 11_609_977 ns
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: true)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        let midURL = try #require(Fixtures.url("midi-gm-song", "mid"))
        let midi = try MidiFile(url: midURL, loopType: .finalFantasy)
        let sequencer = MidiFileSequencer(synthesizer: synth)
        sequencer.play(midi, loop: true)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        for _ in 0..<100 { seqRenderInto(sequencer, &left, &right, 0..<512) }   // warm-up

        var samples = [UInt64]()
        samples.reserveCapacity(1_000)
        for _ in 0..<1_000 {
            let t0 = mach_absolute_time()
            seqRenderInto(sequencer, &left, &right, 0..<512)
            samples.append(MachTime.toNanos(mach_absolute_time() - t0))
        }
        let p99 = Double(percentile(0.99, of: samples))

        print("G3-seq-cpu: deadline=\(deadlineNanos)ns  p99=\(p99)ns (\(100 * p99 / deadlineNanos)%)")

        #expect(p99 < 0.25 * deadlineNanos,
                "sequencer-driven p99 \(p99) ns is ≥ 25% of the 11.6 ms deadline")
    }
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func toNanos(_ delta: UInt64) -> UInt64 {
        delta * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

func percentile(_ p: Double, of samples: [UInt64]) -> UInt64 {
    precondition(!samples.isEmpty)
    let sorted = samples.sorted()
    let rank = Int((p * Double(sorted.count - 1)).rounded())
    return sorted[rank]
}
