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
#endif

@Suite(.serialized)
struct RealTimeSafetyTests {
    #if os(macOS)
    /// **G3′-dry (no-trap)** — ≥5 s of live multichannel rendering on a real
    /// AVAudioSourceNode render thread, every event dispatched through
    /// processMidiMessage inside the callback; surviving to the assertions == zero traps.
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
    func noTrapOnRenderThread() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: false)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        let harness = RenderHarness(
            synthesizer: synth,
            events: [
                RTMidiEvent(frame: 0, channel: 0, command: 0xC0, data1: 0, data2: 0),
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 60, data2: 100),
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 64, data2: 96),
                RTMidiEvent(frame: 0, channel: 0, command: 0x90, data1: 67, data2: 92),
                RTMidiEvent(frame: 22_050, channel: 9, command: 0x90, data1: 36, data2: 127),
                RTMidiEvent(frame: 44_100, channel: 1, command: 0x90, data1: 55, data2: 90),
                RTMidiEvent(frame: 66_150, channel: 1, command: 0xE0, data1: 0, data2: 96),
                RTMidiEvent(frame: 88_200, channel: 0, command: 0x80, data1: 60, data2: 0),
                RTMidiEvent(frame: 88_200, channel: 0, command: 0xB0, data1: 0x07, data2: 80),
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
    #endif

    /// **G3′-dry (zero-alloc)** — after warm-up, a measured window of rendering
    /// (full-pool steal bursts + raw MIDI dispatch + note-offs) allocates
    /// nothing in the render path.
    ///
    /// RELIABILITY DESIGN (see the design consult recorded in the plan). The
    /// spike's single-window `<= 0` assertion is not robust once the suite runs
    /// 100+ tests in parallel: `malloc_zone_statistics(malloc_default_zone())`
    /// reads the PROCESS-GLOBAL zone, and Swift Testing runs suites
    /// concurrently, so an unrelated suite's heap work lands inside the snapshot
    /// window as a SPORADIC, BOUNDED positive delta (single-digit blocks, ~25%
    /// of windows). `.serialized` cannot help — it orders only within a suite,
    /// not against other suites. The robust criterion exploits that signal and
    /// noise have opposite shapes:
    ///   - A GENUINE render-path allocation recurs on EVERY render → a positive,
    ///     REPRODUCIBLE floor (~200 blocks per 200-render window) in EVERY window.
    ///   - Cross-suite contamination pollutes a random SUBSET of windows.
    /// The synth itself never frees at the malloc level inside a window (voices
    /// are pooled; `VoiceCollection.process` swap-compacts, no dealloc), so a
    /// window's INTRINSIC delta is exactly 0 (alloc-free) or a positive floor
    /// (regression); any NEGATIVE delta is provably external. So: measure short
    /// windows, retrying; PASS as soon as one window is non-positive (a quiet or
    /// externally-freed window). A real per-render leak carries its positive floor
    /// into EVERY window, so it can never satisfy that — but note a large external
    /// negative (e.g. an AVAudioEngine-teardown deferred-free from a sibling test)
    /// could in principle mask a SMALL intrinsic leak in a given window, so this
    /// parallel-run PASS is a reliability filter, not the proof. FAIL only when
    /// EVERY window netted a positive delta (the reproducible signature of a real
    /// leak, which cross-suite noise cannot forge across all windows). The
    /// authoritative zero-alloc proof is the exact 0/0 STRICT WITNESS, logged here
    /// and enforced in the isolated run
    /// (`swift test --filter RealTimeSafetyTests.zeroAllocationAfterWarmup`),
    /// where the process-global zone has no concurrent contamination (Task 12).
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
    func zeroAllocationAfterWarmup() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: false)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        // Thorough warm-up so no lazy first-touch allocation survives into the
        // measured windows: saturate the pool, force a full 64-steal burst, run
        // the dispatch paths, cycle voice spawn/free.
        for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) }
        for _ in 0..<200 { renderInto(synth, &left, &right, 0..<512) }
        for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 64 steals
        synth.processMidiMessage(channel: 0, command: 0xE0, data1: 0, data2: 80)
        for _ in 0..<200 { renderInto(synth, &left, &right, 0..<512) }

        // One short (~200-render) measured window: renders + a full-pool steal
        // burst + raw dispatch + note-offs, bracketed by a process-global
        // malloc-zone snapshot. NO print/log inside.
        func measureWindow() -> (blocks: Int, size: Int) {
            var before = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &before)
            for i in 0..<200 {
                if i == 0 { for key in 22..<86 { synth.noteOn(key: key, velocity: 100, on: 0) } }   // full-pool steal
                if i == 50 { synth.processMidiMessage(channel: 0, command: 0xE0, data1: 0, data2: 80) }
                if i == 100 { synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x07, data2: 90) }
                if i == 150 { for key in 22..<40 { synth.noteOff(key: key, on: 0) } }
                renderInto(synth, &left, &right, 0..<512)
            }
            var after = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &after)
            return (Int(after.blocks_in_use) - Int(before.blocks_in_use),
                    Int(after.size_in_use) - Int(before.size_in_use))
        }

        var windows = [(blocks: Int, size: Int)]()
        for _ in 0..<8 {
            let delta = measureWindow()
            windows.append(delta)
            if delta.blocks <= 0 && delta.size <= 0 {
                break   // a quiet/externally-freed window — render path added nothing
            }
            // Drain: let this window's note-off frees and any pending external
            // frees settle OUTSIDE the next measured span.
            for _ in 0..<50 { renderInto(synth, &left, &right, 0..<512) }
        }

        let cleanWindow = windows.first { $0.blocks <= 0 && $0.size <= 0 }
        let exactZeroWitness = windows.contains { $0.blocks == 0 && $0.size == 0 }
        print("G3-alloc windows=\(windows) exactZeroWitness=\(exactZeroWitness)")

        // Fails only when EVERY window allocated — cross-suite noise contaminates
        // a sporadic subset (never all windows), but a real render-path
        // allocation makes all of them strictly positive. Do NOT widen this to
        // tolerate an all-positive result; that would gut the detection.
        #expect(cleanWindow != nil, """
            every one of \(windows.count) measured windows netted a positive \
            malloc-zone delta — the reproducible signature of a render-path \
            allocation. windows=\(windows). Find the allocation (spec §8: the \
            render path must be alloc-free after warm-up); do not loosen the gate.
            """)

        // The default `swift test` run (parallel, multi-suite) uses the
        // noise-robust bounded-retry assertion above, since cross-suite malloc
        // activity can sporadically pollute a subset of windows. The
        // authoritative exact-0/0 proof is gated behind an env var so it only
        // runs isolated (no cross-suite contamination to explain away):
        //   SWIFTYSYNTH_RT_STRICT=1 swift test --filter RealTimeSafetyTests.zeroAllocationAfterWarmup
        if ProcessInfo.processInfo.environment["SWIFTYSYNTH_RT_STRICT"] != nil {
            #expect(exactZeroWitness, """
                STRICT mode: expected at least one measured window with an exact \
                0/0 malloc-zone delta (the authoritative zero-alloc proof), but \
                none of \(windows.count) windows were exactly zero. windows=\(windows).
                """)
        }
    }

    /// **G3′-dry (CPU)** — per-callback cost at 512-frame buffers (deadline
    /// 11.61 ms @ 44.1 kHz): p99 < 25% for 1 note; p99 < 50% for a saturated
    /// 256-voice pool (the canonical polyphony ceiling).
    /// Release builds only — debug-build timings measure the optimizer, not the design.
    @Test(
        .enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"),
        .enabled(if: TestEnv.isRelease, "CPU budget is measured in release builds (swift test -c release)")
    )
    func cpuBudget() throws {
        let deadlineNanos = 512.0 / 44_100.0 * 1e9   // ≈ 11_609_977 ns
        let font = try SoundFont(url: FixtureSF2.url)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)

        // --- 1 note, dry default-size pool ---------------------------------------------
        let settings1 = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 64, enableReverbAndChorus: false)
        let synth1 = try Synthesizer(soundFont: font, settings: settings1)
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
        // (GeneralUser GS Grand Piano = 1 panned-mono voice per noteOn, so 64
        // keys fill 64 slots per channel; channels 0..3 share the default
        // piano preset.)
        let settings256 = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: 256, enableReverbAndChorus: false)
        let synth256 = try Synthesizer(soundFont: font, settings: settings256)
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

        print("G3-cpu: deadline=\(deadlineNanos)ns  1-note p99=\(p99OneNote)ns (\(100 * p99OneNote / deadlineNanos)%)  256-voice p99=\(p99Saturated)ns (\(100 * p99Saturated / deadlineNanos)%)  voices=\(saturatedVoices)")

        #expect(p99OneNote < 0.25 * deadlineNanos,
                "1-note p99 \(p99OneNote) ns is ≥ 25% of the 11.6 ms deadline")
        #expect(p99Saturated < 0.50 * deadlineNanos,
                "256-voice p99 \(p99Saturated) ns is ≥ 50% of the 11.6 ms deadline")
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
